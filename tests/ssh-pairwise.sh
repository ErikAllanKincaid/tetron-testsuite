#!/usr/bin/env bash
# meta:id ssh-pairwise
# meta:description SSH reachability between every node in the topology
# meta:nodes 3
# meta:networks 1
#
# Three VMs, one network, all mutually trusting one shared throwaway key
# (vm_setup_peer_ssh). For every ordered pair (i, j) with i != j, ssh from
# node_i to node_j's mesh IP and run `hostname`, asserting it returns
# node_j's own hostname -- confirming full mesh reachability, not just
# "the two nodes I happened to pick in the other tests can talk."

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp ssh-keygen

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="ssh-pairwise-$$"
BROUGHT_UP=0
NODES=(node1 node2 node3)
declare -A NODE_IP

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "ssh-pairwise: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 3 || fatal "ssh-pairwise: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in "${NODES[@]}"; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "ssh-pairwise: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install && sudo apt-get update -qq && sudo apt-get install -y -qq openssh-client" || fatal "ssh-pairwise: install failed on $node"
	done

	vm_setup_peer_ssh "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "${NODES[@]}" || fatal "ssh-pairwise: vm_setup_peer_ssh failed"

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name pairwisetest --hostname node1")" || fatal "ssh-pairwise: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "ssh-pairwise: could not find an invite code in 'tetron create' output: $create_out"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "ssh-pairwise: 'tetron join' failed on node2"

	# Invites are single-use (LIVE-001/BLOB-001) -- node2 already consumed
	# the one 'tetron create' auto-minted, so node3 needs its own, minted
	# separately via 'tetron invite <net> create'.
	local invite2_out invite2
	invite2_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron invite pairwisetest create --json")" || fatal "ssh-pairwise: 'tetron invite create' failed on node1"
	invite2="$(json_get '.invite_key // empty' "$invite2_out")"
	[[ -n "$invite2" ]] || fatal "ssh-pairwise: could not find an invite_key in 'tetron invite create' output: $invite2_out"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node3 "sudo tetron join $invite2 --hostname node3" || fatal "ssh-pairwise: 'tetron join' failed on node3"

	log_info "waiting for admission to propagate"
	sleep 10

	local status_json
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	NODE_IP[node1]="$(json_get '.networks[0].my_ip // empty' "$status_json")"
	NODE_IP[node2]="$(json_get '.networks[0].peers[] | select(.hostname=="node2") | .ip' "$status_json")"
	NODE_IP[node3]="$(json_get '.networks[0].peers[] | select(.hostname=="node3") | .ip' "$status_json")"

	for node in "${NODES[@]}"; do
		[[ -n "${NODE_IP[$node]}" ]] || fatal "ssh-pairwise: could not find $node's mesh IP in node1's status: $status_json"
		log_info "$node mesh IP: ${NODE_IP[$node]}"
	done

	local rc=0 i j got
	for i in "${NODES[@]}"; do
		for j in "${NODES[@]}"; do
			[[ "$i" == "$j" ]] && continue
			wait_for_peer_port "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$i" "${NODE_IP[$j]}" 22 30 \
				|| fatal "ssh-pairwise: $j's mesh IP:22 never became reachable from $i"
			got="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$i" "ssh $TESTSUITE_PEER_SSH_OPTS -i ~/.ssh/id_ed25519_shared vagrant@${NODE_IP[$j]} hostname")"
			if [[ "$got" == "$j" ]]; then
				log_pass "ssh-pairwise: $i -> $j ($got)"
			else
				log_fail "ssh-pairwise: $i -> $j expected hostname '$j', got '$got'"
				rc=1
			fi
		done
	done

	return $rc
}

main
