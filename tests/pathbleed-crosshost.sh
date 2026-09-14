#!/usr/bin/env bash
# meta:id pathbleed-crosshost
# meta:description Cross-host, two-network regression for PATH-BLEED-001/PATHBLEED-STATUS-003 -- a Direct-classified peer address must never be one of this daemon's own managed overlay addresses
# meta:nodes 2
# meta:networks 2
#
# Closes the gap regression.sh's own header has documented since
# 2026-07-26: "PATH-BLEED-001: NOT YET COVERED ... needs the cross-host,
# two-network topology from the original milestone3b manual investigation
# ... left as a follow-up once lib/topology.sh grows multi-host support."
# lib/topology.sh still only brings up one host per call -- this test
# orchestrates two separate topology_up calls (one per host) directly
# rather than growing that shared abstraction for a single caller.
#
# One VM per host (aorus, x10sra), both joined to TWO tetron networks
# together -- the exact shape PATH-BLEED-001's own live reproduction used
# (DO-NOT-COMMIT/RESULTS_PathBleed_DataLossTest.md in the tetron repo):
# iroh's path-selection state is shared per peer identity, not per
# network, so a peer's own overlay address on one network can bleed onto
# the connection for a different network.
#
# What this actually asserts, and why: a genuine live bleed is a timing
# race (the original doc's own account: "reproduces immediately on boot,
# no forced trigger needed" on one run, cross-host specifically to force
# enough NAT/relay pressure to create the asymmetry needed) -- not
# reliably reproducible on every single run by design. So this test does
# not require catching the race in the act; it asserts the invariant that
# makes a caught bleed harmless either way: a connection this daemon
# reports as `Direct` must never have a `remote_addr` that is actually one
# of its OWN managed overlay subnets (this network's or the other one's).
# That is exactly the check PATHBLEED-STATUS-003's first (wrong) cut
# would have failed -- it made every candidate trustworthy unconditionally
# -- and the corrected version passes.
#
# Requires two hosts declared in hosts.conf (this one is not runnable with
# only "aorus local" -- skips cleanly if a second host isn't available,
# same convention as the tetron-binary-missing checks elsewhere in this
# suite).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"

RUN_A="pathbleed-crosshost-a-$$"
RUN_B="pathbleed-crosshost-b-$$"
BROUGHT_UP_A=0
BROUGHT_UP_B=0
HOST_A=""
HOST_B=""
SAW_DIRECT=0

cleanup() {
	[[ $BROUGHT_UP_A -eq 1 ]] && topology_down "$HOST_A" "$RUN_A"
	[[ $BROUGHT_UP_B -eq 1 ]] && topology_down "$HOST_B" "$RUN_B"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "pathbleed-crosshost: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ ${#TESTSUITE_HOSTS[@]} -lt 2 ]]; then
		log_warn "pathbleed-crosshost: needs two hosts in hosts.conf, only ${#TESTSUITE_HOSTS[@]} declared -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi
	local hosts_sorted
	hosts_sorted="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort)"
	HOST_A="$(echo "$hosts_sorted" | sed -n 1p)"
	HOST_B="$(echo "$hosts_sorted" | sed -n 2p)"
	log_info "using physical hosts: $HOST_A, $HOST_B"

	topology_up "$HOST_A" "$RUN_A" 1 || fatal "pathbleed-crosshost: topology_up failed on $HOST_A"
	BROUGHT_UP_A=1
	topology_up "$HOST_B" "$RUN_B" 1 || fatal "pathbleed-crosshost: topology_up failed on $HOST_B"
	BROUGHT_UP_B=1

	install_tetron "$HOST_A" "$RUN_A" node1
	install_tetron "$HOST_B" "$RUN_B" node1

	local create1_out invite1
	create1_out="$(vm_run "$HOST_A" "$RUN_A" node1 "sudo tetron create --network-name pbcross1 --hostname host-a-node")" || fatal "pathbleed-crosshost: create pbcross1 failed"
	invite1="$(echo "$create1_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite1" ]] || fatal "pathbleed-crosshost: no invite code for pbcross1: $create1_out"

	local create2_out invite2
	create2_out="$(vm_run "$HOST_A" "$RUN_A" node1 "sudo tetron create --network-name pbcross2 --hostname host-a-node")" || fatal "pathbleed-crosshost: create pbcross2 failed"
	invite2="$(echo "$create2_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite2" ]] || fatal "pathbleed-crosshost: no invite code for pbcross2: $create2_out"

	vm_run "$HOST_B" "$RUN_B" node1 "sudo tetron join $invite1 --hostname host-b-node" || fatal "pathbleed-crosshost: join pbcross1 failed"
	vm_run "$HOST_B" "$RUN_B" node1 "sudo tetron join $invite2 --hostname host-b-node" || fatal "pathbleed-crosshost: join pbcross2 failed"

	# Poll repeatedly, not once: the invariant below is only meaningfully
	# exercised once at least one network actually reaches Direct --
	# cross-host holepunch (each VM behind its own hypervisor's NAT, plus
	# whatever the real hosts' own network adds) can take longer than a
	# same-LAN VM pair, and a single early check that never sees Direct
	# would pass vacuously without having checked anything real. Tracks
	# whether Direct was ever seen at all so that case is reported
	# honestly rather than silently counted as a pass.
	log_info "waiting for admission + path negotiation, polling every 10s for up to 150s"
	local rc=0
	local saw_direct=0
	local elapsed=0
	while [[ $elapsed -lt 150 ]]; do
		sleep 10
		elapsed=$((elapsed + 10))
		log_info "poll at t=${elapsed}s"
		check_no_overlay_bleed "$HOST_A" "$RUN_A" "host A" || rc=1
		check_no_overlay_bleed "$HOST_B" "$RUN_B" "host B" || rc=1
	done

	# Staying relay-only between two genuinely separate physical machines is
	# itself a failure, not a neutral "nothing to check" -- P2P direct is
	# the actual goal this whole project exists for (see USER's own framing,
	# DO-NOT-COMMIT/RESEARCH_RelayVsDirect_iroh.md's design-goal section:
	# relay should be negotiation/last-resort, not a place traffic quietly
	# stays). A bled-address check that only ever runs against Relay
	# connections is not exercising the thing PATHBLEED-STATUS-003 actually
	# needs verified either.
	if [[ $SAW_DIRECT -eq 0 ]]; then
		log_fail "pathbleed-crosshost: neither network on either host ever reached Direct within 150s -- stayed Relay-only the entire run between two genuinely separate physical machines. This is a failure of the actual goal (P2P direct connections), not just a gap in this test's own coverage of the bled-address invariant."
		rc=1
	fi

	return $rc
}

install_tetron() {
	local host="$1" run_id="$2" node="$3"
	if [[ "${TESTSUITE_HOSTS[$host]}" == "local" ]]; then
		vm_upload "$host" "$run_id" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "pathbleed-crosshost: vm_upload failed on $host"
	else
		# vm_upload refuses a remote physical host by design (topology.sh's
		# own documented limitation) -- stage the binary on that host's own
		# filesystem first, then upload from there exactly as vm_upload
		# would internally.
		scp -o BatchMode=yes "$TESTSUITE_TETRON_BINARY" "${TESTSUITE_HOSTS[$host]#ssh:}:/tmp/tetron-staged-$$" || fatal "pathbleed-crosshost: scp to $host failed"
		local remote_dir
		remote_dir="$(topology_remote_dir "$run_id")"
		run_on "$host" "cd '$remote_dir' && vagrant upload '/tmp/tetron-staged-$$' '/tmp/tetron' '$node'" || fatal "pathbleed-crosshost: vagrant upload on $host failed"
	fi
	vm_run "$host" "$run_id" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "pathbleed-crosshost: install failed on $host"
}

# check_no_overlay_bleed <host> <run-id> <label>
# The core regression assertion: for every network on this node, if its
# peer connection is classified Direct, remote_addr's IP must not fall
# inside EITHER of the two overlay subnets this daemon itself manages --
# a genuine external address never will; a self-captured/bled candidate
# (a peer's own overlay address on the OTHER network) would.
check_no_overlay_bleed() {
	local host="$1" run_id="$2" label="$3"
	local status_json
	status_json="$(vm_run "$host" "$run_id" node1 "tetron status --json")" || {
		log_fail "PATH-BLEED-001/PATHBLEED-STATUS-003: could not reach $label's node to check status"
		return 1
	}

	local subnets
	subnets="$(json_get '[.networks[].subnet]' "$status_json")"
	local rc=0
	local i=0
	local net_count
	net_count="$(json_get '.networks | length' "$status_json")"
	while [[ $i -lt $net_count ]]; do
		local net_name conn_type remote_addr
		net_name="$(json_get ".networks[$i].network" "$status_json")"
		conn_type="$(json_get ".networks[$i].peers[0].connection.conn_type // \"None\"" "$status_json")"
		remote_addr="$(json_get ".networks[$i].peers[0].connection.remote_addr // \"\"" "$status_json")"
		if [[ "$conn_type" == "Direct" ]]; then
			SAW_DIRECT=1
			local ip
			ip="$(echo "$remote_addr" | sed -E 's#^ip:##; s#:[0-9]+$##')"
			if echo "$subnets" | jq -e --arg ip "$ip" '
				any(.[]; . as $s | ($s | split("/")[0]) as $base |
				  ($ip | split(".") | map(tonumber)) as $a |
				  ($base | split(".") | map(tonumber)) as $b |
				  $a[0] == $b[0] and $a[1] == $b[1] and $a[2] == $b[2])
			' >/dev/null 2>&1; then
				log_fail "PATH-BLEED-001/PATHBLEED-STATUS-003: $label network '$net_name' reports Direct with remote_addr $remote_addr -- that address is inside one of this daemon's OWN managed overlay subnets ($subnets), i.e. a self-captured/bled overlay address, not a real one"
				rc=1
			else
				log_pass "PATH-BLEED-001/PATHBLEED-STATUS-003: $label network '$net_name' Direct remote_addr ($remote_addr) is a genuine external address, not a managed overlay one"
			fi
		else
			log_pass "PATH-BLEED-001/PATHBLEED-STATUS-003: $label network '$net_name' is $conn_type (not Direct, nothing to check for this poll)"
		fi
		i=$((i + 1))
	done
	return $rc
}

main
