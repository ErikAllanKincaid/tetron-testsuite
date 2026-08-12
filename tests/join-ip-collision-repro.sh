#!/usr/bin/env bash
# meta:id join-ip-collision-repro
# meta:description MULTISEG-009: two identities that collide at the same index-0 IP both join successfully instead of the second failing outright
# meta:nodes 3
# meta:networks 1
#
# Direct reproduction of the concurrent-join IP-collision bug found live
# 2026-08-11 (two OOM-repro test runs joining testing-delete-me within
# about a minute of each other -- see tetron/DO-NOT-COMMIT/TODO_DETAILS.md
# #concurrent-join-ip-collision). Concurrency was only how it was
# discovered, not an inherent part of the bug: the join handshake
# discarded its own coordinator-resolved IP from the Welcome roster any
# time a fresh joiner's pre-dial guess collided with an existing member,
# concurrent or not. This test forces the exact collision deterministically
# instead of relying on timing -- node2 and node3 are seeded with a real
# SecretKey pair (found via src/addressing.rs's own find_colliding_pair
# birthday-search helper) that both derive the identical index-0 IP under
# the default subnet, then join sequentially. Pre-fix this reproduces "IP
# collision: <ip> is already assigned to <node2>" on node3's join;
# post-fix (MULTISEG-009) node3 is admitted at a bumped-index IP distinct
# from node2's.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp python3

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="join-ip-collision-repro-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
	[[ -n "${KEY_DIR:-}" && -d "$KEY_DIR" ]] && rm -rf "$KEY_DIR"
}
trap cleanup EXIT

# Raw 32-byte SecretKey material for two identities confirmed (via
# find_colliding_pair, 2026-08-12) to both derive 10.88.0.60 as their
# index-0 IP under default_subnet(). Deterministic: byte 0 = 0x03 / 0x0f,
# all other bytes zero, matching find_colliding_pair's own key-construction
# scheme (varies only the first 4 little-endian bytes of a loop counter).
COLLIDE_A_HEX="0300000000000000000000000000000000000000000000000000000000000000"
COLLIDE_B_HEX="0f00000000000000000000000000000000000000000000000000000000000000"

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "join-ip-collision-repro: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	KEY_DIR="$(mktemp -d)"
	python3 -c "
import binascii
open('$KEY_DIR/a', 'wb').write(binascii.unhexlify('$COLLIDE_A_HEX'))
open('$KEY_DIR/b', 'wb').write(binascii.unhexlify('$COLLIDE_B_HEX'))
"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 3 || fatal "join-ip-collision-repro: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2 node3; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "join-ip-collision-repro: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "join-ip-collision-repro: install failed on $node"
	done

	# Seed node2/node3 with the real colliding identity pair: stop the
	# freshly-installed daemon (which already generated a random key on
	# first start), overwrite secret_key with the pre-computed colliding
	# bytes, restart so it loads the forced identity instead.
	vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "$KEY_DIR/a" "/tmp/secret_key" || fatal "join-ip-collision-repro: key upload failed on node2"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo systemctl stop tetron && sudo cp /tmp/secret_key /etc/tetron/secret_key && sudo chown root:root /etc/tetron/secret_key && sudo chmod 600 /etc/tetron/secret_key && sudo systemctl start tetron" || fatal "join-ip-collision-repro: key seed failed on node2"

	vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node3 "$KEY_DIR/b" "/tmp/secret_key" || fatal "join-ip-collision-repro: key upload failed on node3"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node3 "sudo systemctl stop tetron && sudo cp /tmp/secret_key /etc/tetron/secret_key && sudo chown root:root /etc/tetron/secret_key && sudo chmod 600 /etc/tetron/secret_key && sudo systemctl start tetron" || fatal "join-ip-collision-repro: key seed failed on node3"

	sleep 3

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name collidetest --hostname node1")" || fatal "join-ip-collision-repro: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "join-ip-collision-repro: could not find an invite code in 'tetron create' output"

	# node2 joins first -- takes the collision-index-0 IP outright, nothing
	# to resolve yet.
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "join-ip-collision-repro: 'tetron join' failed on node2"
	log_info "waiting for node2's admission to propagate"
	sleep 8

	# The 'create' invite is single-use and node2 already redeemed it -- mint
	# a fresh one for node3, or its join fails on "invite rejected" before
	# ever reaching the collision-resolution code path at all.
	local invite2_out invite2
	invite2_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron invite collidetest create")" || fatal "join-ip-collision-repro: 'tetron invite create' failed on node1"
	invite2="$(echo "$invite2_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite2" ]] || fatal "join-ip-collision-repro: could not find an invite code in 'tetron invite create' output"

	# node3's own pre-dial guess is now identical to node2's already-assigned
	# IP. Pre-fix: this bails with "IP collision: ... already assigned to
	# <node2>". Post-fix (MULTISEG-009): node3 adopts its coordinator-
	# resolved, bumped-index IP from the Welcome roster and joins clean.
	local join_out join_rc
	join_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node3 "sudo tetron join $invite2 --hostname node3" 2>&1)"
	join_rc=$?
	echo "--- node3 join output (rc=$join_rc) ---" >&2
	echo "$join_out" >&2
	echo "--- end node3 join output ---" >&2
	if echo "$join_out" | grep -qi "IP collision"; then
		log_fail "join-ip-collision-repro: node3's join hit the collision bug -- MULTISEG-009 did not fix it (or this run predates the fix)"
		exit 1
	fi
	if [[ $join_rc -ne 0 ]]; then
		log_fail "join-ip-collision-repro: node3's join failed for a different reason (rc=$join_rc), see output above"
		exit 1
	fi
	log_pass "join-ip-collision-repro: node3's join succeeded (rc=0) and did not hit 'IP collision' despite a forced identity collision with node2"

	log_info "waiting for node3's admission to propagate"
	sleep 15

	log_info "node3's own view of the network, for diagnostics"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node3 "tetron status --json" >&2 || true

	local status_json member_count ip2 ip3
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "2" ]]; then
		log_fail "join-ip-collision-repro: expected node1 to see 2 members (node2, node3), got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi

	ip2="$(json_get '.networks[0].peers[] | select(.hostname=="node2") | .ip' "$status_json")"
	ip3="$(json_get '.networks[0].peers[] | select(.hostname=="node3") | .ip' "$status_json")"
	if [[ -z "$ip2" || -z "$ip3" || "$ip2" == "$ip3" ]]; then
		log_fail "join-ip-collision-repro: expected node2 and node3 to have distinct IPs, got ip2=$ip2 ip3=$ip3"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "join-ip-collision-repro: node1 sees both node2 ($ip2) and node3 ($ip3) as members with distinct IPs despite the forced identity collision"
}

main
