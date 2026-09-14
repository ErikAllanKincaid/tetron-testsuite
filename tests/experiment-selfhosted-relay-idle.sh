#!/usr/bin/env bash
# meta:id experiment-selfhosted-relay-idle
# meta:description One-off experiment (not a standing regression test): does
# the idle-connection ~10-16s reconnect cycle
# (ANALYSIS_idle-timeout-reconnect-churn_2026-08-11.md) reproduce against a
# self-hosted tetron-relay instead of the public n0 relay? Distinguishes
# "n0's relay deployment specifically" from "iroh's relay protocol in
# general" as the actual cause, after the keepalive-fix experiment (Phase 2
# Experiment A) failed to resolve it.
# meta:nodes 2
# meta:networks 1
#
# Prerequisite: a self-hosted relay already brought up via
# `tetron-relay up --host <name> --domain <ip> --dev` (self-signed cert --
# real tetron clients reject this by default, "UnknownIssuer", per
# tetron-relay's own README; this test installs the cert into each VM's own
# OS trust store to work around that, since these are disposable VMs, not
# real trust changes).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"
# shellcheck source=../lib/memleak_collect.sh
source "$ROOT/lib/memleak_collect.sh"
# shellcheck source=../lib/randomized_poll.sh
source "$ROOT/lib/randomized_poll.sh"
# shellcheck source=../lib/network_faults.sh
source "$ROOT/lib/network_faults.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=x10sra}"
: "${TESTSUITE_RELAY_URL:=https://192.168.1.113}"
: "${TESTSUITE_RELAY_CERT_HOST:=x10sra}"
: "${TESTSUITE_RELAY_CERT_PATH:=/var/lib/iroh-relay/dev-cert.pem}"
: "${TESTSUITE_IDLE_DURATION_S:=180}"
: "${TESTSUITE_POLL_MIN_S:=15}"
: "${TESTSUITE_POLL_MAX_S:=20}"

TEST_ID="experiment-selfhosted-relay-idle"
RUN_ID="experiment-relay-$$"
BROUGHT_UP=0
EVIDENCE_DIR="$ROOT/DO-NOT-COMMIT/oom-repro-evidence/$RUN_ID"

cleanup() {
	if [[ $BROUGHT_UP -eq 1 ]]; then
		topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
	fi
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "$TEST_ID: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	mkdir -p "$EVIDENCE_DIR"
	log_info "$TEST_ID: evidence directory: $EVIDENCE_DIR"

	local cert_pem
	cert_pem="$(ssh "${TESTSUITE_HOSTS[$TESTSUITE_RELAY_CERT_HOST]#ssh:}" "sudo cat $TESTSUITE_RELAY_CERT_PATH")"
	[[ -n "$cert_pem" ]] || fatal "$TEST_ID: could not read the relay's dev cert from $TESTSUITE_RELAY_CERT_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "$TEST_ID: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "$TEST_ID: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "$TEST_ID: install failed on $node"

		# Install the relay's self-signed cert into this VM's own OS trust
		# store -- disposable VM, not a real trust change. Base64-round-trip
		# to get the multi-line PEM through vm_run's nested-quoting safely.
		local cert_b64
		cert_b64="$(echo "$cert_pem" | base64 -w0)"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "echo $cert_b64 | base64 -d | sudo tee /usr/local/share/ca-certificates/tetron-relay-dev.crt >/dev/null && sudo update-ca-certificates" \
			|| fatal "$TEST_ID: could not install the relay cert into $node's trust store"

		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo tetron config set log-level info" || fatal "$TEST_ID: could not set log-level on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo tetron config set relay $TESTSUITE_RELAY_URL --replace" || fatal "$TEST_ID: could not set custom relay on $node"
	done

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo systemctl restart tetron" || fatal "$TEST_ID: daemon restart failed on node1"
	sleep 3
	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name relay-experiment --hostname node1")" || fatal "$TEST_ID: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "$TEST_ID: no invite code in create output: $create_out"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron resume" || fatal "$TEST_ID: 'tetron resume' failed on node1"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo systemctl restart tetron" || fatal "$TEST_ID: daemon restart failed on node2"
	sleep 3
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "$TEST_ID: 'tetron join' failed on node2"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "tetron resume" || fatal "$TEST_ID: 'tetron resume' failed on node2"

	log_info "$TEST_ID: waiting for admission to propagate (natural path first, likely direct on same LAN)"
	sleep 10

	# Now sever direct -- forces the already-established membership onto
	# relay for the idle observation, without needing the very first
	# blob-fetch-during-join handshake to bootstrap over relay cold.
	force_relay_only "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 node2 >/dev/null
	log_info "$TEST_ID: direct path now blocked -- waiting for relay path to establish"
	sleep 15

	local relay_host
	relay_host="$(relay_host_in_use "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1)"
	log_info "$TEST_ID: node1 is using relay host: ${relay_host:-<none selected yet>}"
	if [[ "$relay_host" != *192.168.1.113* ]]; then
		log_warn "$TEST_ID: node1's selected relay ('$relay_host') does not look like our self-hosted one -- check the config actually took effect before trusting this run's result"
	fi

	log_info "$TEST_ID: === starting ${TESTSUITE_IDLE_DURATION_S}s idle window against self-hosted relay ==="
	poll_loop_randomized "$TESTSUITE_IDLE_DURATION_S" "$TESTSUITE_POLL_MIN_S" "$TESTSUITE_POLL_MAX_S" "$EVIDENCE_DIR/run" node1

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo gzip -c /var/log/tetron/tetron.log.*" >"$EVIDENCE_DIR/node1-info.log.gz" 2>/dev/null || log_warn "$TEST_ID: could not pull node1's log"
	local reconnect_count
	reconnect_count="$(log_match_count "$EVIDENCE_DIR/node1-info.log.gz" "peer connection lost\|removing dead peer\|known member reconnecting")"

	{
		echo "=== experiment-selfhosted-relay-idle summary ($RUN_ID) ==="
		echo "relay: $TESTSUITE_RELAY_URL (self-hosted, dev cert)"
		echo "relay actually selected by node1: ${relay_host:-none}"
		echo "idle duration (s): $TESTSUITE_IDLE_DURATION_S"
		echo "reconnect/teardown events during idle window: $reconnect_count"
		echo "evidence dir: $EVIDENCE_DIR"
	} | tee "$EVIDENCE_DIR/summary.txt"

	log_info "$TEST_ID: === done, evidence under $EVIDENCE_DIR ==="
}

main
