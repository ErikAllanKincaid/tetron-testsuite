#!/usr/bin/env bash
# meta:id alpine-musl
# meta:description Alpine musl smoke: create -> join -> status -> leave (daemon run directly, no systemd)
# meta:nodes 2
# meta:networks 1
#
# Tests the musl-linked tetron binary on an Alpine Linux VM. Alpine uses
# OpenRC, not systemd, so 'sudo tetron install' will fail. Instead we run
# 'tetron daemon' directly in the background after setting up the necessary
# directories and loading the tun module. The rest of the smoke test
# (create -> join -> status -> leave) exercises the same path as core-smoke.
#
# Like core-smoke, drives tetron black-box through its own CLI and --json
# output -- no internals touched.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="alpine-musl-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

# vm_daemon_start <physical-host> <run-id> <node>
# Starts tetron daemon in the background on the VM. Sets up the necessary
# directories first (normally created by 'tetron install'), loads the tun
# module, then launches the daemon as root. Stores the PID so the caller
# can kill it later.
vm_daemon_start() {
	local physical_host="$1" run_id="$2" node="$3"

	# Create required directories (install would do this on systemd)
	vm_run "$physical_host" "$run_id" "$node" \
		"sudo mkdir -p /etc/tetron /var/log/tetron /var/run/tetron && sudo chmod 0755 /etc/tetron /var/log/tetron /var/run/tetron" || return 1

	# Create the tetron group (needed for socket permissions).
	# grep /etc/group is more portable than 'getent' (musl-busybox Alpine).
	vm_run "$physical_host" "$run_id" "$node" \
		"grep -q '^tetron:' /etc/group 2>/dev/null || sudo addgroup -S tetron" || return 1

	# Load the tun module (Alpine does not load it by default)
	vm_run "$physical_host" "$run_id" "$node" \
		"sudo modprobe tun 2>/dev/null; sudo mkdir -p /dev/net; [ -c /dev/net/tun ] || sudo mknod /dev/net/tun c 10 200 && sudo chmod 0666 /dev/net/tun" || return 1

	# Start the daemon in background using sudo -b (detaches from the
	# SSH/tty session so vagrant ssh returning doesn't kill it).
	# Redirect output to a log file so we can see what happened if it
	# crashes. The shell runs under sudo so > redirect runs as root.
	vm_run "$physical_host" "$run_id" "$node" \
		"sudo -b sh -c '/usr/local/bin/tetron daemon >/var/log/tetron/daemon.log 2>&1'" || return 1

	# Give the daemon a moment to start, then verify it's alive and
	# accepting IPC. Use tetron status (unprivileged, connects via Unix
	# socket) rather than pgrep -- busybox/Alpine may not ship pgrep.
	sleep 3
	local alive
	alive="$(vm_run "$physical_host" "$run_id" "$node" "/usr/local/bin/tetron status >/dev/null 2>&1 && echo yes || echo no")"
	if [[ "$alive" != "yes" ]]; then
		log_error "tetron daemon failed to start on $node; daemon log follows:"
		vm_run "$physical_host" "$run_id" "$node" "tail -30 /var/log/tetron/daemon.log 2>/dev/null || echo '(no log file)'" >&2
		return 1
	fi
	log_info "tetron daemon running and accepting IPC on $node"
	return 0
}

# vm_daemon_stop <physical-host> <run-id> <node>
# Stops the tetron daemon and cleans up. Uses killall (busybox provides it
# on Alpine) rather than pkill or a PID-file approach, since bash variable
# expansion through vm_run's double-quoted ssh invocation is error-prone.
vm_daemon_stop() {
	local physical_host="$1" run_id="$2" node="$3"
	vm_run "$physical_host" "$run_id" "$node" \
		"sudo killall -q tetron 2>/dev/null; sleep 1; sudo killall -9 tetron 2>/dev/null; true" || true
}

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "alpine-musl: no tetron binary at $TESTSUITE_TETRON_BINARY (build one with 'cargo build --release --target x86_64-unknown-linux-musl' in the tetron repo, or set TESTSUITE_TETRON_BINARY) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	# Confirm the binary is actually musl-linked (static-pie) -- otherwise
	# it would fail on Alpine with a glibc mismatch, and that's the exact
	# bug we're here to catch.
	local binary_type
	binary_type="$(file "$TESTSUITE_TETRON_BINARY" 2>/dev/null | grep -o 'static-pie\|dynamically linked')"
	if [[ "$binary_type" != "static-pie" ]]; then
		log_warn "alpine-musl: binary is '$binary_type', not static-pie -- it will not run on Alpine. Point TESTSUITE_TETRON_BINARY at a musl build (x86_64-unknown-linux-musl target) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	# Override the VM box to Alpine -- this is the whole point of this test.
	# Note: must use direct assignment, not :=, because topology.sh already
	# set TESTSUITE_VM_BOX to bento/ubuntu-24.04 at source time.
	TESTSUITE_VM_BOX=generic/alpine319
	export TESTSUITE_VM_BOX
	log_info "using VM box: $TESTSUITE_VM_BOX"

	# Increase memory slightly for Alpine (still modest)
	# topology.sh already set TESTSUITE_VM_MEM_MB to 512
	TESTSUITE_VM_MEM_MB=768
	export TESTSUITE_VM_MEM_MB

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "alpine-musl: topology_up failed"
	BROUGHT_UP=1

	# Upload and install the musl binary on both nodes
	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "alpine-musl: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron" || fatal "alpine-musl: binary install failed on $node"
	done

	# Start the daemon on both nodes (no systemd available -- run directly)
	for node in node1 node2; do
		vm_daemon_start "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" || fatal "alpine-musl: daemon start failed on $node"
	done

	# Wait for both daemons to be fully ready for IPC
	sleep 3

	# node1 creates a network
	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo /usr/local/bin/tetron create --network-name alpine-test --hostname node1")" || {
		log_fail "alpine-musl: 'tetron create' failed on node1"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tail -30 /var/log/tetron/daemon.log 2>/dev/null" >&2
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2
		exit 1
	}
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	if [[ -z "$invite" ]]; then
		log_fail "alpine-musl: could not find an invite code in 'tetron create' output:"
		echo "$create_out" >&2
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2
		exit 1
	fi
	log_info "alpine-musl: node1 created network, invite code found"

	# node2 joins
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo /usr/local/bin/tetron join $invite --hostname node2" || {
		log_fail "alpine-musl: 'tetron join' failed on node2"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "tail -30 /var/log/tetron/daemon.log 2>/dev/null" >&2
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2
		exit 1
	}

	log_info "alpine-musl: waiting for admission to propagate"
	sleep 10

	# Assert node1 sees node2 as a member
	local status_json member_count peer_hostname
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "/usr/local/bin/tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	peer_hostname="$(json_get '.networks[0].peers[0].hostname // empty' "$status_json")"

	if [[ "$member_count" != "1" || "$peer_hostname" != "node2" ]]; then
		log_fail "alpine-musl: expected node1 to see 1 member (node2) after join, got member_count=$member_count peer_hostname=$peer_hostname"
		echo "$status_json" >&2
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2
		exit 1
	fi
	log_pass "alpine-musl: node1 sees node2 as a member after join"

	# Capture the network key for leave
	local net_key
	net_key="$(json_get '.networks[0].network_key // empty' "$status_json")"

	# node2 leaves
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo /usr/local/bin/tetron leave ${net_key:-alpine-test} --force" || {
		log_fail "alpine-musl: 'tetron leave' failed on node2"
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2
		exit 1
	}

	log_info "alpine-musl: waiting for departure to propagate"
	sleep 10

	# Assert node1 sees 0 members after node2 leaves
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "/usr/local/bin/tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "0" ]]; then
		log_fail "alpine-musl: expected node1 to see 0 members after node2 left, got member_count=$member_count"
		echo "$status_json" >&2
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1
		vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2
		exit 1
	fi
	log_pass "alpine-musl: node1 sees node2 gone after leave"

	# Clean shutdown of daemons
	vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1
	vm_daemon_stop "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2
}

main
