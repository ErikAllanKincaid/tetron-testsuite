#!/usr/bin/env bash
# meta:id experiment-mtu-ceiling-timeline
# meta:description EXPERIMENT (not a pass/fail test): how long the QUIC datagram ceiling stays below tetron's 1280-byte TUN MTU at connection start, on an unclamped direct path
# meta:nodes 2
# meta:networks 1
#
# Disposable instrumentation for one question: is there a case for raising
# noq's default initial_mtu (1200) in tetron's transport config? The only
# surviving argument for it is the connection-startup window, where the
# datagram ceiling sits below the 1280-byte TUN MTU and every full-size
# packet must be fragmented until MTU discovery raises it. That argument is
# worth exactly as much as the window is long, which nobody has measured.
#
# Deliberately NOT a pass/fail test and not in run-list.txt: it reports
# numbers, it does not assert. Kept because the numbers are the evidence
# for (or against) a requirement that does not exist yet.
#
# Nothing here clamps any MTU -- the point is to observe an ordinary path,
# unlike tests/oversized-udp-fragmentation.sh which deliberately forces the
# sub-1280 regime.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"
: "${TESTSUITE_TUN_MTU:=1280}"
: "${TESTSUITE_SAMPLE_SECS:=120}"
: "${TESTSUITE_SAMPLE_INTERVAL:=0.5}"

TEST_ID="experiment-mtu-ceiling-timeline"
ASSETS_DIR="$ROOT/assets"
RUN_ID="$TEST_ID-$$"
RESULTS_DIR="$ROOT/DO-NOT-COMMIT/mtu-ceiling-timeline"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "$TEST_ID: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi
	[[ -f "$ASSETS_DIR/mtu_ceiling_sampler.py" ]] || fatal "$TEST_ID: missing assets/mtu_ceiling_sampler.py"
	mkdir -p "$RESULTS_DIR"

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
	vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "$ASSETS_DIR/mtu_ceiling_sampler.py" "/tmp/mtu_ceiling_sampler.py" || fatal "$TEST_ID: could not upload the sampler"

	# Report the underlay MTU so the numbers below are interpretable.
	local iface mtu
	iface="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "ip -o -4 route show to default" | grep -oE 'dev [^ ]+' | head -n1 | cut -d' ' -f2 | tr -d '\r\n')"
	mtu="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "cat /sys/class/net/$iface/mtu" | tr -d '\r\n')"
	log_info "$TEST_ID: node1 underlay $iface MTU is $mtu (unclamped)"

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name mtutimeline --hostname node1")" || fatal "$TEST_ID: 'tetron create' failed"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "$TEST_ID: could not find an invite code"

	# Sampler first, so the very first moment the peer connection exists is
	# captured -- the window under measurement is at the start of it.
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 \
		"nohup python3 /tmp/mtu_ceiling_sampler.py /tmp/mtu-timeline.txt $TESTSUITE_SAMPLE_SECS $TESTSUITE_SAMPLE_INTERVAL </dev/null >/tmp/sampler.log 2>&1 & sleep 1" \
		|| fatal "$TEST_ID: could not start the sampler on node1"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "$TEST_ID: 'tetron join' failed on node2"

	log_info "$TEST_ID: sampling the ceiling for ${TESTSUITE_SAMPLE_SECS}s"
	sleep "$((TESTSUITE_SAMPLE_SECS + 5))"

	local timeline="$RESULTS_DIR/timeline-$(date +%Y%m%d-%H%M%S).txt"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "cat /tmp/mtu-timeline.txt" > "$timeline" 2>/dev/null
	log_info "$TEST_ID: raw timeline saved to $timeline"

	# Analysis is local, on the captured rows.
	python3 - "$timeline" "$TESTSUITE_TUN_MTU" <<'PYEOF'
import sys

rows = []
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) != 3:
        continue
    ts, mds, ct = parts
    rows.append((float(ts), None if mds == "none" else int(mds), ct))

tun_mtu = int(sys.argv[2])
connected = [r for r in rows if r[1] is not None]
print(f"samples: {len(rows)} total, {len(connected)} with a live connection")
if not connected:
    print("NO CONNECTION EVER OBSERVED -- nothing to conclude")
    raise SystemExit(0)

t0 = connected[0][0]
print(f"first ceiling reading: {connected[0][1]} bytes ({connected[0][2]})")
below = [r for r in connected if r[1] < tun_mtu]
print(f"samples below the {tun_mtu}-byte TUN MTU: {len(below)} of {len(connected)}")

if below:
    last_below = max(r[0] for r in below)
    print(f"last sample below {tun_mtu}: t+{last_below - t0:.1f}s after the connection appeared")
else:
    print(f"never below {tun_mtu} at any point after the connection appeared")

# Ceiling trajectory, deduplicated to transitions only.
print("\nceiling transitions (t+secs, bytes, conn_type):")
prev = None
for ts, mds, ct in connected:
    if (mds, ct) != prev:
        print(f"  t+{ts - t0:6.1f}s  {mds:5d}  {ct}")
        prev = (mds, ct)
PYEOF

	log_pass "$TEST_ID: measurement complete (this experiment reports, it does not assert)"
}

main
