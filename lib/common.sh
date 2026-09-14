#!/usr/bin/env bash
# Shared helpers for tetron-testsuite. Sourced by bin/tetron-testsuite and by
# individual tests/*.sh files -- never executed directly.

set -uo pipefail

# Autotools-style skip convention: a test that isn't implemented yet (or
# whose preconditions genuinely cannot be met) exits this code rather than
# reporting a false pass or an indistinguishable generic failure.
readonly TESTSUITE_SKIP_CODE=77

# Options for any ssh/scp/rsync hop between two VMs (not the physical-host
# hop, which already goes through vagrant's own ssh-config). Each VM is
# freshly created every run, so its host key is new and unknown every time
# -- accepting it unconditionally is correct here, not a security
# shortcut, since there is no prior legitimate host identity to compare
# against.
readonly TESTSUITE_PEER_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

declare -gA TESTSUITE_HOSTS=()

log_info()  { printf '[info]  %s\n' "$*" >&2; }
log_warn()  { printf '[warn]  %s\n' "$*" >&2; }
log_error() { printf '[error] %s\n' "$*" >&2; }
log_pass()  { printf '[pass]  %s\n' "$*" >&2; }
log_fail()  { printf '[fail]  %s\n' "$*" >&2; }

fatal() {
	log_error "$*"
	exit 1
}

require_cmd() {
	local cmd
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || fatal "required command not found on this controller: $cmd"
	done
}

# Populates TESTSUITE_HOSTS[name]=target from a hosts.conf-formatted file.
# target is "local" or "ssh:<user@host>", matching hosts.conf.example.
load_hosts_conf() {
	local conf_path="$1"
	[[ -f "$conf_path" ]] || fatal "hosts file not found: $conf_path (copy hosts.conf.example to hosts.conf and edit it)"

	TESTSUITE_HOSTS=()
	local line name target
	while IFS= read -r line; do
		line="${line%%#*}"
		line="$(echo "$line" | xargs)" || true
		[[ -z "$line" ]] && continue
		name="$(echo "$line" | awk '{print $1}')"
		target="$(echo "$line" | awk '{print $2}')"
		[[ -z "$name" || -z "$target" ]] && fatal "malformed hosts.conf line: $line"
		TESTSUITE_HOSTS["$name"]="$target"
	done <"$conf_path"

	[[ ${#TESTSUITE_HOSTS[@]} -gt 0 ]] || fatal "hosts file declares no hosts: $conf_path"
}

# run_on <host-name> <command...>
# Runs a command on the named host (local shell, or ssh for a "ssh:" target)
# and streams its stdout/stderr through. Returns the command's exit code.
run_on() {
	local host_name="$1"
	shift
	local target="${TESTSUITE_HOSTS[$host_name]:-}"
	[[ -n "$target" ]] || fatal "unknown host in hosts.conf: $host_name"

	if [[ "$target" == "local" ]]; then
		bash -c "$*"
	elif [[ "$target" == ssh:* ]]; then
		ssh -o BatchMode=yes "${target#ssh:}" "$@"
	else
		fatal "unrecognized hosts.conf target for '$host_name': $target (expected 'local' or 'ssh:user@host')"
	fi
}

# tetron_json <host-name> <tetron subcommand and args...>
# Runs `tetron <args...> --json` on the named host and prints the raw JSON
# to stdout for the caller to pipe into jq. Fails loudly (not silently) if
# the command's own exit code is non-zero.
tetron_json() {
	local host_name="$1"
	shift
	run_on "$host_name" "tetron $* --json"
}

# json_get <jq-filter> <json-text>
json_get() {
	local filter="$1"
	local json="$2"
	echo "$json" | jq -r "$filter"
}

# log_match_count <gzip-file> <grep-pattern>
# Counts lines matching <grep-pattern> across a gzip file's decompressed
# content, printing one integer. Use this instead of `zgrep -c` whenever
# the gzip file may have been built from `gzip -c file1 file2 ...` (a
# multi-file glob, e.g. rotated daily logs matching tetron.log.*) --
# zgrep -c reports a count PER underlying gzip member in that case (e.g.
# "0\n0" for two files with no matches), breaking any numeric comparison
# on the result. zcat decompresses a concatenated multi-member stream as
# one continuous byte stream, so grep -c over that gives one real total.
# Found live 2026-08-11 building tetron-testsuite's OOM-repro tests (see
# tetron-testsuite/DO-NOT-COMMIT/TODO_DETAILS.md#zgrep-multimember-undercount).
log_match_count() {
	local gzip_file="$1" pattern="$2"
	[[ -f "$gzip_file" ]] || { echo 0; return; }
	zcat "$gzip_file" 2>/dev/null | grep -c "$pattern" || echo 0
}
