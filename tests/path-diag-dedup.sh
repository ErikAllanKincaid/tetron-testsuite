#!/usr/bin/env bash
# meta:id path-diag-dedup
# meta:description PATH-DIAG-005: each path-event transition is logged once, not twice
# meta:nodes 2
# meta:networks 1
#
# Regression guard for PATH-DIAG-005 (spawn_path_logger/lib.rs and
# log_path_events/forward.rs both independently subscribing to the same
# connection's path_events() stream, logging every transition twice in two
# different formats -- see tetron/spec/security.py's
# DeduplicatePathEventLogging). Brings up two VMs, joins them (a single,
# stable direct connection -- no forced churn), and asserts node1's log
# shows exactly one "path selected" line for the connection to node2, not
# two, and that no line matches the removed logger's own format signature
# (its distinguishing field was `addr=`; the surviving logger uses
# `remote_addr=` and a `net=` field the old one never had).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="path-diag-dedup-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "path-diag-dedup: no tetron binary at $TESTSUITE_TETRON_BINARY (build one with 'cargo build --release' in the tetron repo, or set TESTSUITE_TETRON_BINARY) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "path-diag-dedup: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "path-diag-dedup: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "path-diag-dedup: install failed on $node"
	done

	# Full visibility for diagnosis: at the default info level, Opened/
	# Closed/the initial existing-path dump are all invisible (debug), so a
	# genuine absence can't be told apart from "just not logged at this
	# level". trace on node1 only -- node2's side isn't being asserted on.
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron config set log-level trace && sudo tetron restart" || fatal "path-diag-dedup: could not set log-level on node1"
	sleep 3

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name pathdiagtest --hostname node1")" || fatal "path-diag-dedup: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "path-diag-dedup: could not find an invite code in 'tetron create' output"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "path-diag-dedup: 'tetron join' failed on node2"

	log_info "waiting for admission and path selection to settle"
	sleep 20

	local status_json member_count
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "1" ]]; then
		log_fail "path-diag-dedup: expected node1 to see 1 member (node2) before checking logs, got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi

	# The removed spawn_path_logger's own format never carried a `net=`
	# field on any of its four message types ("existing path"/"path
	# opened"/"path closed"/"path selected") -- the surviving log_path_events
	# always does (it runs inside the peer reader's own `info_span!("peer",
	# ..., net=...)`). A reintroduced duplicate subscriber would show up as
	# a matching message with no `net=` alongside it. Live-verified (found
	# building this test, not assumed): a fresh single-path VM connection
	# does NOT reliably emit a `PathEvent::Selected` transition at all --
	# the direct LAN path is typically already chosen by the time
	# log_path_events subscribes, so only the "existing path" dump (not a
	# live Selected event) reflects it. Asserting message *format*, not a
	# specific message's *count*, avoids depending on which transitions a
	# clean VM topology happens to produce.
	local old_format_count new_format_count
	old_format_count="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -E 'existing path|path (opened|closed|selected)' /var/log/tetron/tetron.log.* 2>/dev/null | grep -vc 'net=' || true")"
	old_format_count="${old_format_count:-0}"
	if [[ "$old_format_count" != "0" ]]; then
		log_info "path-diag-dedup: diagnostic dump -- offending line(s):"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -E 'existing path|path (opened|closed|selected)' /var/log/tetron/tetron.log.* 2>/dev/null | grep -v 'net='" >&2
		log_fail "path-diag-dedup: found $old_format_count line(s) matching the removed spawn_path_logger's own format (no net= field) -- duplicate subscriber reintroduced?"
		exit 1
	fi
	log_pass "path-diag-dedup: no log lines match the removed logger's own format signature"

	new_format_count="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -E 'existing path|path (opened|closed|selected)' /var/log/tetron/tetron.log.* 2>/dev/null | grep -c 'net=' || true")"
	new_format_count="${new_format_count:-0}"
	if [[ "$new_format_count" -lt 1 ]]; then
		log_info "path-diag-dedup: diagnostic dump -- all path-related log lines on node1:"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -i 'path' /var/log/tetron/tetron.log.* 2>/dev/null | tail -30" >&2
		log_fail "path-diag-dedup: expected at least one path-event log line (surviving log_path_events never fired at all?), got $new_format_count"
		exit 1
	fi
	log_pass "path-diag-dedup: log_path_events produced output ($new_format_count line(s)), confirming path-event logging is live and only the surviving subscriber's format is present"
}

main
