#!/usr/bin/env bash
# meta:id reconnect-storm
# meta:description RECONNECT-STORM-001/002/003: a peer that connects then drops almost immediately, repeatedly, must escalate the far side's reconnect backoff off the 1s floor instead of being redialed at ~1 Hz forever
# meta:nodes 2
# meta:networks 1
#
# Reproduces the fleet incident behind RECONNECT-STORM-00x
# (tetron/DO-NOT-COMMIT/PLAN_tetron_lazy-resilient-peer-connectivity_
# 2026-10-08.md section 9a): one node logged ~29k reconnects/day against a
# single peer that accepted each dial and then closed the connection ~40ms
# later (QUIC app code 0). The far side spawned a fresh reconnect task per
# disconnect that re-initialised its backoff to the 1s floor every cycle, so
# it never escalated -- a continuous ~1 Hz storm.
#
# The fix keys on connection *uptime*, not the close code: any connection
# that lives less than `reconnect-holddown.min-uptime` (default 5s) counts as
# a flap/failure and the per-peer streak persists across reconnect cycles, so
# the backoff escalates off the floor (2s, 4s, 8s, ... toward the cold tier).
#
# This test induces short-lived connections the simplest black-box way: node2
# restarts its daemon in a tight loop, so each connection node1 accepts from
# it dies a couple of seconds later. node1 (the stable side, coordinator) is
# the victim whose reconnect backoff must escalate. The assertion is
# differential and version-independent: before the fix node1 only ever logged
# `coordinator reconnecting in secs=1`; after it, the backoff climbs above the
# 1s floor. node2 is the flapping side; its own in-memory streak is lost on
# every restart, which is fine -- node1 is the node under test.
#
# The assertion is made deterministic (not timing-fragile) by raising node1's
# reconnect-holddown.min-uptime to 30s -- far above the restart cadence -- so
# every connection node1 holds during the flap dies well under the floor and is
# unambiguously a flap, no matter how fast or slow the VM daemon boots/dials.
# The only requirement is that node1 establishes and loses a handful of these
# short-lived connections, which the restart loop guarantees.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="reconnect-storm-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "reconnect-storm: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "reconnect-storm: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "reconnect-storm: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "reconnect-storm: install failed on $node"
	done

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name storm --hostname node1")" || fatal "reconnect-storm: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "reconnect-storm: could not find an invite code"

	# The coordinator redial's per-attempt "coordinator reconnecting in secs=N"
	# line is debug (steady-state retry, LOG-005 precedent). LOG-004 live-reloads
	# this with no restart.
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron config set log-level debug" || fatal "reconnect-storm: could not set log-level debug on node1"
	# Raise the hold-down floor to 30s (well above the restart cadence) so every
	# connection node1 holds during the flap dies far under it and is
	# unambiguously classified as a flap, regardless of VM dial-speed jitter --
	# this is what makes the assertion deterministic rather than timing-fragile.
	# Disable jitter so the escalated backoff values are exact and easy to assert.
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron config set reconnect-holddown.min-uptime 30 && sudo tetron config set reconnect-holddown.jitter-pct 0" || fatal "reconnect-storm: could not set reconnect-holddown knobs on node1"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "reconnect-storm: 'tetron join' failed on node2"

	log_info "waiting for admission to propagate"
	sleep 15

	local status_json member_count
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "1" ]]; then
		log_fail "reconnect-storm: expected node1 to see 1 member (node2) before the flap, got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "reconnect-storm: node1 sees node2 as a member before the flap"

	# Flap node2: each restart tears down the connection node1 holds a few
	# seconds after node2 re-establishes it, so node1 observes a run of
	# short-lived (< min-uptime) connections to the same peer. The loop runs
	# HERE in the test shell (one single-command vm_run per restart), not as a
	# compound remote command -- a remote `for ...; do ...; done` gets mangled
	# by the vagrant-ssh quoting layers (vm_run wraps the whole command in
	# nested double quotes).
	local flaps=15 i
	log_info "flapping node2 ($flaps daemon restarts, ~3s apart) to induce short-lived connections on node1"
	for ((i = 1; i <= flaps; i++)); do
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo systemctl restart tetron" || fatal "reconnect-storm: flap restart $i/$flaps failed on node2"
		sleep 3
	done

	log_info "letting node1's reconnect state settle (20s)"
	sleep 20

	# Differential assertion: before the fix node1's coordinator redial reset to
	# the 1s floor every cycle (only ever `secs=1`); after it, the persisted flap
	# streak escalates the backoff above 1s. Extract the max secs= node1 logged.
	local secs_values max_secs
	# The log line is `coordinator reconnecting in peer=<id> secs=N` -- there is a
	# peer= field between `in` and `secs=`, so match on `secs=` directly and pull
	# the number out of that token.
	secs_values="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -ohE 'coordinator reconnecting in .*secs=[0-9]+' /var/log/tetron/tetron.log.* 2>/dev/null | grep -oE 'secs=[0-9]+' | grep -oE '[0-9]+' || true")"
	max_secs=0
	local v
	for v in $secs_values; do
		[[ "$v" =~ ^[0-9]+$ ]] && ((v > max_secs)) && max_secs="$v"
	done

	if [[ "$max_secs" -le 1 ]]; then
		log_info "reconnect-storm: diagnostic dump -- node1 reconnect/connection lines:"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -iE 'reconnecting in|connection lost|reconnected to peer' /var/log/tetron/tetron.log.* 2>/dev/null | tail -n 80" >&2
		log_fail "reconnect-storm: node1's reconnect backoff never escalated above the 1s floor (max secs=$max_secs) -- the hold-down did not engage; this is the ~1 Hz storm behavior"
		exit 1
	fi
	log_pass "reconnect-storm: node1 escalated its reconnect backoff off the 1s floor during the flap (max secs=$max_secs) -- RECONNECT-STORM-001/002 engaged"
}

main
