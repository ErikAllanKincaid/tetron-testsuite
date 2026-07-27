#!/usr/bin/env bash
# meta:id http-reachability
# meta:description HTTP reachability across the mesh -- validates MINIMAL-010's "every mesh peer reaches every port a local service binds" claim
# meta:nodes 2
# meta:networks 1
#
# node2 runs a plain `python3 -m http.server` bound to its own mesh IP;
# node1 curls it and asserts the content matches. tetron has no
# data-plane packet filter of its own (MINIMAL-010) -- membership is the
# only gate -- so this should just work with no port-specific
# configuration on either side, unlike the rsync/scp/ssh tests which all
# need the extra vm_setup_peer_ssh key-trust step (this one doesn't --
# curl needs no VM-to-VM SSH trust at all).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="http-reachability-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "http-reachability: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "http-reachability: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "http-reachability: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "http-reachability: install failed on $node"
	done

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name httptest --hostname node1")" || fatal "http-reachability: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "http-reachability: could not find an invite code in 'tetron create' output: $create_out"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "http-reachability: 'tetron join' failed on node2"

	log_info "waiting for admission to propagate"
	sleep 8

	local status_json node2_ip
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	node2_ip="$(json_get '.networks[0].peers[0].ip // empty' "$status_json")"
	if [[ -z "$node2_ip" ]]; then
		log_fail "http-reachability: could not find node2's mesh IP in node1's status:"
		echo "$status_json" >&2
		exit 1
	fi
	log_info "node2's mesh IP: $node2_ip"

	wait_for_peer_port "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "$node2_ip" 22 30 \
		|| fatal "http-reachability: node2's mesh IP never became reachable from node1 (probed via its always-on sshd, port 22, as a stand-in for 'is the mesh path up at all')"

	local marker="tetron-testsuite-$RUN_ID"
	# Setup and server-start are deliberately two separate vm_run calls, and
	# the second is a single simple command with no leading "&&" before its
	# trailing "&" (using --directory instead of "cd &&"). Found live
	# 2026-07-27: under this suite's `vagrant ssh -c` (which allocates a
	# PTY and runs `bash -l -c '...'`), backgrounding a multi-command "&&"
	# chain -- even a trivial one like `cd dir && nohup ... &` -- hangs the
	# whole ssh session indefinitely even though the backgrounded server
	# itself starts and runs fine; the trailing "&" only reliably detaches
	# when it backgrounds one single simple command. setsid or extra
	# subshell grouping around the multi-command chain did not fix it in
	# testing -- only removing the "&&" chain from the backgrounded command
	# did.
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "mkdir -p /tmp/httproot && echo '$marker' > /tmp/httproot/testfile.txt" \
		|| fatal "http-reachability: could not create test file on node2"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 \
		"nohup python3 -m http.server 8080 --bind $node2_ip --directory /tmp/httproot </dev/null >/tmp/httpserver.log 2>&1 & sleep 1" \
		|| fatal "http-reachability: could not start http.server on node2"

	log_info "waiting for http.server to bind"
	sleep 2

	local body
	body="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "curl -s --max-time 5 http://$node2_ip:8080/testfile.txt")"

	if [[ "$body" != "$marker" ]]; then
		log_fail "http-reachability: expected '$marker' from node2's http.server over its mesh IP, got '$body'"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "cat /tmp/httpserver.log" >&2 || true
		exit 1
	fi
	log_pass "http-reachability: node1 reached node2's http.server over its mesh IP, content matched"
}

main
