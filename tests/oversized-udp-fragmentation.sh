#!/usr/bin/env bash
# meta:id oversized-udp-fragmentation
# meta:description FRAG-004: oversized ICMP/UDP must survive tetron's own re-fragmentation whenever the peer connection's datagram ceiling sits below the 1280-byte TUN MTU
# meta:nodes 2
# meta:networks 1
#
# The gap FRAG-001/FRAG-002's live verification never covered. Anything
# larger than tetron's 1280-byte TUN MTU is split by the *host kernel*
# before tetron sees it, so tetron receives IP fragments, not whole
# packets. When the peer connection's max_datagram_size is also below 1280,
# tetron has to split those pieces again, and until FRAG-004 it rebuilt
# each one as though it were the start of a fresh packet: fragment offsets
# restarted at zero and More-Fragments was cleared on the last piece
# regardless of the input. The receiving kernel then dropped the datagram
# or reassembled scrambled bytes, with no drop counted and nothing in the
# logs.
#
# Bulk TCP cannot detect this: TCP sizes its own segments to the 1280 MTU,
# so the kernel never pre-splits them. That is why scp/rsync/ssh tests pass
# either way, and why this test drives ICMP and UDP specifically.
#
# WHAT PUTS THE CEILING BELOW 1280 (measured, not assumed -- 2026-08-15):
# a *direct* path with a clamped underlay MTU. This test was first written
# to force a relay path instead, on the theory that relay is where the
# ceiling is lowest. Two live runs disproved that: with relay forced, node1
# fragmented only 12 and then 9 packets against traffic implying ~100, even
# with the underlay NIC clamped to 1300 -- because iroh carries relay
# traffic inside a TCP connection to the relay server, so the local NIC MTU
# does not bound the QUIC datagram ceiling there at all, and it stays above
# 1280. The handful of fragmentation events seen were the handshake window
# before the relay path settled. A direct path does real UDP path-MTU
# discovery bounded by the NIC, so clamping the NIC is what deterministically
# forces the regime under test. The precondition below asserts the ceiling
# directly (MTU-DIAG-001's per-peer max_datagram_size) rather than
# inferring it, so a future change in any of this fails loudly instead of
# quietly making the test vacuous.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"
# tetron's TUN MTU (src/tun.rs's TUN_MTU, not configurable in tetron
# itself). Named here because every size decision below is relative to it.
: "${TESTSUITE_TUN_MTU:=1280}"
# Underlay (physical NIC) MTU on both VMs. QUIC's path MTU on a direct path
# is bounded by this, and max_datagram_size is roughly path MTU minus ~50
# bytes of IP/UDP/QUIC overhead -- so 1300 here puts the ceiling near 1250,
# below the TUN MTU, which is exactly the regime that forces tetron to
# re-fragment every oversized piece the host kernel hands it.
: "${TESTSUITE_UNDERLAY_MTU:=1300}"
# Ping payload sizes, in bytes. 1000 is the control: it fits inside the
# TUN MTU, is never fragmented by anything, and proves the tunnel itself
# works, so a failure at the larger sizes is specifically about
# fragmentation. 2000 splits into two kernel pieces, of which only the
# first needs re-fragmenting -- it exercises the cleared-More-Fragments
# half of the bug. 4000 splits into four, three of which need
# re-fragmenting at a non-zero base offset -- it exercises the reset-offset
# half as well.
: "${TESTSUITE_PING_SIZES:=1000 2000 4000}"
: "${TESTSUITE_PING_COUNT:=10}"
# UDP flow: 20 datagrams of 4000 bytes each, one every 50ms.
: "${TESTSUITE_UDP_COUNT:=20}"
: "${TESTSUITE_UDP_SIZE:=4000}"
: "${TESTSUITE_UDP_PORT:=51888}"
# QUIC datagrams are not retransmitted, so a genuinely lossy path can
# legitimately cost a packet or two. The bug being guarded against loses
# every oversized packet, not a few, so this threshold separates the two
# without making the test flaky on a bad day.
: "${TESTSUITE_MIN_DELIVERY_PCT:=90}"
# The run must fragment at least this fraction of what the traffic implies,
# or the traffic did not go through the regime under test.
: "${TESTSUITE_MIN_FRAG_PCT:=50}"

TEST_ID="oversized-udp-fragmentation"
ASSETS_DIR="$ROOT/assets"
RUN_ID="$TEST_ID-$$"
BROUGHT_UP=0
FAILED=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

# ping_received <node> <dst-ip> <size> <count>
# Runs ping from <node> and prints how many replies came back. Never
# fatals on a non-zero exit: 100% loss is exactly what this test is here to
# detect, and ping exits non-zero for it.
ping_received() {
	local node="$1" dst="$2" size="$3" count="$4" out
	out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" \
		"ping -c $count -s $size -W 2 -i 0.3 $dst" 2>/dev/null || true)"
	# Parsed on the controller, not in the VM: vm_run's nested ssh layers
	# re-parse the command string as shell syntax, so anything with a '$'
	# in it belongs here rather than there.
	echo "$out" | grep -oE '[0-9]+ received' | grep -oE '^[0-9]+' | head -n1
}

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "$TEST_ID: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi
	local asset
	for asset in udp_sink.py udp_send.py; do
		[[ -f "$ASSETS_DIR/$asset" ]] || fatal "$TEST_ID: missing asset $ASSETS_DIR/$asset"
	done

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "$TEST_ID: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "$TEST_ID: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "$TEST_ID: install failed on $node"
	done

	# Before either daemon starts, so QUIC's own path-MTU discovery never
	# sees the unclamped interface. See the header for why this, and not
	# relay forcing, is what produces the regime under test.
	local iface
	for node in node1 node2; do
		iface="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "ip -o -4 route show to default" | grep -oE 'dev [^ ]+' | head -n1 | cut -d' ' -f2 | tr -d '\r\n')"
		[[ -n "$iface" ]] || fatal "$TEST_ID: could not determine the default-route interface on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo ip link set dev $iface mtu $TESTSUITE_UNDERLAY_MTU" \
			|| fatal "$TEST_ID: could not set $iface MTU to $TESTSUITE_UNDERLAY_MTU on $node"
		log_info "$node: underlay interface $iface clamped to MTU $TESTSUITE_UNDERLAY_MTU"
	done

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name fragtest --hostname node1")" || fatal "$TEST_ID: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "$TEST_ID: could not find an invite code"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "$TEST_ID: 'tetron join' failed on node2"

	log_info "waiting for admission and path selection (30s)"
	sleep 30

	local status_json member_count
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "1" ]]; then
		log_fail "$TEST_ID: expected node1 to see 1 member (node2), got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi

	local node2_ip
	node2_ip="$(json_get '.networks[0].peers[] | select(.hostname=="node2") | .ip' "$status_json")"
	[[ -n "$node2_ip" && "$node2_ip" != "null" ]] || fatal "$TEST_ID: could not read node2's mesh IP from node1's status"
	log_info "node2 mesh IP: $node2_ip"

	# ── Precondition, measured directly (MTU-DIAG-001) ────────────────
	# The whole test is meaningless unless the datagram ceiling sits below
	# the TUN MTU, so read it rather than assume it. Retried: the ceiling
	# moves as QUIC's path-MTU discovery converges early in a connection's
	# life.
	local ceiling="" attempt
	for attempt in 1 2 3 4 5; do
		status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
		ceiling="$(json_get '.networks[0].peers[] | select(.hostname=="node2") | .connection.max_datagram_size // empty' "$status_json")"
		[[ -n "$ceiling" && "$ceiling" != "null" ]] && break
		sleep 5
	done
	if [[ -z "$ceiling" || "$ceiling" == "null" ]]; then
		log_fail "$TEST_ID: node1 reports no max_datagram_size for node2 -- the connection does not support QUIC datagrams, so nothing about the data path can be concluded"
		echo "$status_json" >&2
		exit 1
	fi
	if [[ "$ceiling" -ge "$TESTSUITE_TUN_MTU" ]]; then
		log_fail "$TEST_ID: node1's datagram ceiling to node2 is $ceiling, at or above the ${TESTSUITE_TUN_MTU}-byte TUN MTU -- nothing will be re-fragmented and this run would prove nothing about FRAG-004. The underlay MTU clamp to $TESTSUITE_UNDERLAY_MTU did not bound the path as expected (a relay path, for one, is not bounded by it -- see this test's header)."
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "$TEST_ID: datagram ceiling to node2 is $ceiling, below the ${TESTSUITE_TUN_MTU}-byte TUN MTU -- every oversized piece must be re-fragmented"

	# ── ICMP: one run per payload size ────────────────────────────────
	local size received min_received
	min_received=$(( TESTSUITE_PING_COUNT * TESTSUITE_MIN_DELIVERY_PCT / 100 ))
	for size in $TESTSUITE_PING_SIZES; do
		received="$(ping_received node1 "$node2_ip" "$size" "$TESTSUITE_PING_COUNT")"
		received="${received:-0}"
		if [[ "$received" -lt "$min_received" ]]; then
			log_fail "$TEST_ID: ping -s $size returned $received/$TESTSUITE_PING_COUNT replies (need at least $min_received)"
			FAILED=1
		else
			log_pass "$TEST_ID: ping -s $size returned $received/$TESTSUITE_PING_COUNT replies"
		fi
	done

	# ── UDP flow ──────────────────────────────────────────────────────
	vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "$ASSETS_DIR/udp_sink.py" "/tmp/udp_sink.py" || fatal "$TEST_ID: could not upload udp_sink.py to node2"
	vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "$ASSETS_DIR/udp_send.py" "/tmp/udp_send.py" || fatal "$TEST_ID: could not upload udp_send.py to node1"

	# One single simple command before the trailing '&': backgrounding a
	# '&&' chain under this suite's `vagrant ssh -c` hangs the ssh session
	# outright (found live 2026-07-27, see tests/http-reachability.sh).
	local sink_deadline=$(( TESTSUITE_UDP_COUNT / 10 + 30 ))
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 \
		"nohup python3 /tmp/udp_sink.py $node2_ip $TESTSUITE_UDP_PORT $TESTSUITE_UDP_COUNT $TESTSUITE_UDP_SIZE $sink_deadline </dev/null >/tmp/udp_sink.out 2>&1 & sleep 1" \
		|| fatal "$TEST_ID: could not start udp_sink.py on node2"
	sleep 2

	log_info "sending $TESTSUITE_UDP_COUNT UDP datagrams of $TESTSUITE_UDP_SIZE bytes to $node2_ip"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 \
		"python3 /tmp/udp_send.py $node2_ip $TESTSUITE_UDP_PORT $TESTSUITE_UDP_COUNT $TESTSUITE_UDP_SIZE 0.05" \
		|| fatal "$TEST_ID: udp_send.py failed on node1"

	log_info "waiting for the sink to finish"
	sleep 5
	local sink_out ok corrupt wrong_size min_ok
	sink_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "cat /tmp/udp_sink.out")"
	log_info "udp_sink: $sink_out"
	ok="$(echo "$sink_out" | grep -oE 'ok=[0-9]+' | grep -oE '[0-9]+' | head -n1)"
	corrupt="$(echo "$sink_out" | grep -oE 'corrupt=[0-9]+' | grep -oE '[0-9]+' | head -n1)"
	wrong_size="$(echo "$sink_out" | grep -oE 'wrong_size=[0-9]+' | grep -oE '[0-9]+' | head -n1)"
	ok="${ok:-0}"; corrupt="${corrupt:-0}"; wrong_size="${wrong_size:-0}"
	min_ok=$(( TESTSUITE_UDP_COUNT * TESTSUITE_MIN_DELIVERY_PCT / 100 ))

	if [[ "$corrupt" -ne 0 || "$wrong_size" -ne 0 ]]; then
		log_fail "$TEST_ID: $corrupt corrupt and $wrong_size wrong-sized datagrams arrived -- reassembly produced bytes that were never sent, which no amount of packet loss can explain"
		FAILED=1
	fi
	if [[ "$ok" -lt "$min_ok" ]]; then
		log_fail "$TEST_ID: only $ok/$TESTSUITE_UDP_COUNT UDP datagrams of $TESTSUITE_UDP_SIZE bytes arrived intact (need at least $min_ok)"
		FAILED=1
	else
		log_pass "$TEST_ID: $ok/$TESTSUITE_UDP_COUNT UDP datagrams of $TESTSUITE_UDP_SIZE bytes arrived intact"
	fi

	# ── Second precondition: the traffic went through that regime ─────
	# The ceiling check proves the path was right; this proves the packets
	# actually took it. Expectation is derived from what was sent: the host
	# kernel splits each oversized packet into pieces carrying TUN_MTU-20
	# bytes of payload, and every piece that is itself full-size has to be
	# split again by tetron. Ping *replies* are fragmented by node2 and
	# counted there, so they are deliberately not in this sum.
	local payload_per_piece=$(( TESTSUITE_TUN_MTU - 20 ))
	local expected_frags=0 min_frags pieces
	for size in $TESTSUITE_PING_SIZES; do
		pieces=$(( (size + 8) / payload_per_piece ))
		expected_frags=$(( expected_frags + pieces * TESTSUITE_PING_COUNT ))
	done
	pieces=$(( (TESTSUITE_UDP_SIZE + 8) / payload_per_piece ))
	expected_frags=$(( expected_frags + pieces * TESTSUITE_UDP_COUNT ))
	min_frags=$(( expected_frags * TESTSUITE_MIN_FRAG_PCT / 100 ))

	local frag_count
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	frag_count="$(json_get '.fragmented_ipv4 // 0' "$status_json")"
	frag_count="${frag_count:-0}"
	if [[ "$frag_count" -lt "$min_frags" ]]; then
		log_fail "$TEST_ID: node1 fragmented only $frag_count packets, expected at least $min_frags of roughly $expected_frags implied by the traffic sent"
		echo "$status_json" >&2
		FAILED=1
	else
		log_pass "$TEST_ID: node1 fragmented $frag_count packets (at least $min_frags of ~$expected_frags implied by the traffic)"
	fi

	# json_get takes (filter, json) only -- no jq flags -- so the compact
	# rendering happens here rather than via jq -c.
	log_info "$TEST_ID: node1 drop counters: $(json_get '.drops // {}' "$status_json" | tr -d '\n' | tr -s ' ')"

	[[ $FAILED -eq 0 ]] || exit 1
	log_pass "$TEST_ID: oversized ICMP and UDP survive tetron's re-fragmentation below the TUN MTU"
}

main
