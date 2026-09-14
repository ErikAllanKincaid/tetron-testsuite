#!/usr/bin/env bash
# meta:id install-path-override
# meta:description PORTABILITY-004: tetron install --config-dir/--log-dir/--socket-path inject env vars into the service unit
# meta:nodes 1
# meta:networks 1
#
# Asserts that the three new flags write the expected Environment= lines
# into the systemd unit, and that unset flags leave no trace (the unit
# file is identical to a bare `tetron install` for those vars).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="install-path-override-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "install-path-override: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 1 || fatal "topology_up failed"
	BROUGHT_UP=1

	vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "vm_upload failed"
	# Install without flags first -- capture the bare unit file as reference.
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "bare install failed"
	bare_unit="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "cat /etc/systemd/system/tetron.service")" || fatal "could not read unit file"

	local rc=0

	# Test 1: all three flags set.
	log_info "test 1: --config-dir + --log-dir + --socket-path all set"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 \
		"sudo tetron install \
			--config-dir /tmp/custom-tetron-config \
			--log-dir /tmp/custom-tetron-logs \
			--socket-path /tmp/custom-tetron-socket/tetron.sock" \
		|| fatal "install failed with --config-dir/--log-dir/--socket-path"
	unit="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "cat /etc/systemd/system/tetron.service")" || fatal "could not read unit file"
	if echo "$unit" | grep -q "Environment=TETRON_CONFIG_DIR=/tmp/custom-tetron-config" \
		&& echo "$unit" | grep -q "Environment=TETRON_LOG_DIR=/tmp/custom-tetron-logs" \
		&& echo "$unit" | grep -q "Environment=TETRON_SOCKET_PATH=/tmp/custom-tetron-socket/tetron.sock"; then
		log_pass "PORTABILITY-004: all three Environment= lines present in unit"
	else
		log_fail "PORTABILITY-004: expected Environment= lines for all three vars, got:"
		echo "$unit" >&2
		rc=1
	fi

	# Test 2: no flags (reinstall bare) -- unit should match the bare reference
	# (the lines from test 1 should have been removed since they're unset).
	log_info "test 2: no flags -- unit reverts to clean state"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron install" || fatal "bare reinstall failed"
	unit="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "cat /etc/systemd/system/tetron.service")" || fatal "could not read unit file"
	if ! echo "$unit" | grep -q "TETRON_CONFIG_DIR" \
		&& ! echo "$unit" | grep -q "TETRON_LOG_DIR" \
		&& ! echo "$unit" | grep -q "TETRON_SOCKET_PATH"; then
		log_pass "PORTABILITY-004: no flag lines present after bare reinstall"
	else
		log_fail "PORTABILITY-004: expected no TETRON_* lines after bare reinstall, got:"
		echo "$unit" >&2
		rc=1
	fi

	# Test 3: single flag (--socket-path only).
	log_info "test 3: --socket-path alone, others unset"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 \
		"sudo tetron install --socket-path /opt/tetron/tetron.sock" \
		|| fatal "install failed with --socket-path only"
	unit="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "cat /etc/systemd/system/tetron.service")" || fatal "could not read unit file"
	if echo "$unit" | grep -q "Environment=TETRON_SOCKET_PATH=/opt/tetron/tetron.sock" \
		&& ! echo "$unit" | grep -q "TETRON_CONFIG_DIR" \
		&& ! echo "$unit" | grep -q "TETRON_LOG_DIR"; then
		log_pass "PORTABILITY-004: only --socket-path injected, others absent"
	else
		log_fail "PORTABILITY-004: expected only SOCKET_PATH line, got:"
		echo "$unit" >&2
		rc=1
	fi

	# Test 4: ensure the daemon actually starts after an overridden install.
	log_info "test 4: daemon responds to IPC after --config-dir install"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 \
		"sudo tetron install --config-dir /tmp/tetron-etc" \
		|| fatal "install failed with --config-dir"
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron status --json" 2>&1)"
	if echo "$status_json" | grep -q '"daemon_version"'; then
		log_pass "PORTABILITY-004: daemon reachable and responding to IPC after --config-dir install"
	else
		log_fail "PORTABILITY-004: expected IPC response (daemon_version field), got:"
		echo "$status_json" >&2
	fi

	return $rc
}

main
