#!/usr/bin/env bash
# Shared network-fault injection helpers for the OOM-reproduction tests
# (PLAN_tetron_reproduce-production-OOM_2026-08-11.md in the tetron repo).
# Factored out of tests/pr12-leak-repro.sh's inline IP-blackhole logic so
# T1/T2/T5 (and anything later) share one already-verified implementation
# instead of duplicating it.
#
# Sourced after lib/common.sh and lib/topology.sh. Relies on vm_run/fatal/
# log_info/log_warn/log_pass being available.

set -uo pipefail

# blackhole_host_ip <host> <run-id> <node> <hostname>
# Resolves <hostname> from inside <node> (both A and AAAA -- which protocol
# a given HTTP client prefers in a given environment isn't otherwise known,
# so both must be blocked) and installs iptables/ip6tables OUTPUT DROP
# rules against the resolved IPs. Prints "<ip4> <ip6>" (either may be
# empty) on stdout for the caller to save and pass to unblock_host_ip
# later. IP-level, not DNS-level -- a DNS-level block fails fast (~3s,
# already-bounded at the iroh-dns layer, see
# ANALYSIS_external-PR12-dht-leak-claim_2026-08-07.md Step 0) and would
# never exercise the unbounded-past-DNS HTTP path this is meant to test.
#
# IMPORTANT (found live during pr12-leak-repro.sh's first run): never
# embed a literal '$' in a command string passed to vm_run -- vm_run's
# nested "vagrant ssh -c \"$*\"" / "bash -c \"$*\"" layers each re-parse
# the fully-composed string as fresh shell syntax before it reaches the
# VM. Do any '$'-bearing text processing locally, on output already
# captured back from vm_run, exactly as this function does.
blackhole_host_ip() {
	local host="$1" run_id="$2" node="$3" hostname="$4"

	local lookup ip4 ip6
	lookup="$(vm_run "$host" "$run_id" "$node" "getent ahosts $hostname")"
	ip4="$(echo "$lookup" | awk '$1 !~ /:/ {print $1}' | head -n1 | tr -d '\r\n')"
	ip6="$(echo "$lookup" | awk '$1 ~ /:/ {print $1}' | head -n1 | tr -d '\r\n')"
	[[ -n "$ip4" || -n "$ip6" ]] || fatal "blackhole_host_ip: could not resolve $hostname from $node"

	log_info "blackhole_host_ip: blocking $hostname on $node -- IPv4=${ip4:-none} IPv6=${ip6:-none}"
	if [[ -n "$ip4" ]]; then
		vm_run "$host" "$run_id" "$node" "sudo iptables -A OUTPUT -d $ip4 -j DROP" || fatal "blackhole_host_ip: iptables rule failed on $node"
	fi
	if [[ -n "$ip6" ]]; then
		vm_run "$host" "$run_id" "$node" "sudo ip6tables -A OUTPUT -d $ip6 -j DROP" || fatal "blackhole_host_ip: ip6tables rule failed on $node"
	fi
	printf '%s %s\n' "${ip4:-}" "${ip6:-}"
}

# unblock_host_ip <host> <run-id> <node> <ip4> <ip6>
# Removes the DROP rules blackhole_host_ip installed. Either ip may be
# empty (matching what blackhole_host_ip printed).
unblock_host_ip() {
	local host="$1" run_id="$2" node="$3" ip4="$4" ip6="$5"
	[[ -n "$ip4" ]] && vm_run "$host" "$run_id" "$node" "sudo iptables -D OUTPUT -d $ip4 -j DROP" >/dev/null 2>&1
	[[ -n "$ip6" ]] && vm_run "$host" "$run_id" "$node" "sudo ip6tables -D OUTPUT -d $ip6 -j DROP" >/dev/null 2>&1
	return 0
}

# verify_blackhole <host> <run-id> <node> <hostname>
# Confirms <hostname> is unreachable but general connectivity (example.com)
# still works from <node> -- distinguishes a targeted block from a general
# network failure that would make the test meaningless either way.
verify_blackhole() {
	local host="$1" run_id="$2" node="$3" hostname="$4"
	if vm_run "$host" "$run_id" "$node" "curl -m 5 -sS https://$hostname/ >/dev/null 2>&1"; then
		log_warn "verify_blackhole: $node could still reach $hostname -- blackhole may not be effective, results should not be trusted"
		return 1
	fi
	log_pass "verify_blackhole: $node cannot reach $hostname (confirmed blocked)"
	if vm_run "$host" "$run_id" "$node" "curl -m 5 -sS https://example.com/ >/dev/null 2>&1"; then
		log_pass "verify_blackhole: $node's general internet/DNS still works (targeted block, not a general outage)"
	else
		log_warn "verify_blackhole: $node could not reach example.com either -- general connectivity may be broken, not just the targeted host"
		return 1
	fi
	return 0
}

# dns_blackout <host> <run-id> <node>
# Blocks DNS resolution wholesale on <node> -- not just a specific
# hostname's already-resolved IP (that is blackhole_host_ip's job). Drops
# outbound UDP+TCP port 53 to anything except loopback, so the local
# systemd-resolved stub (127.0.0.53) keeps answering from cache but its own
# upstream queries time out -- matching the production signature in
# ANALYSIS_derek-OOM-production-logs_2026-08-11.md's 08-09 death: both
# relay-connect (334x) and pkarr-publish (141x) failed identically with
# "Request timed out," consistent with the whole resolver being down, not
# one tetron-specific lookup. Decided in
# PLAN_tetron_reproduce-production-OOM_2026-08-11.md: wholesale, not
# narrow, to match that fidelity.
dns_blackout() {
	local host="$1" run_id="$2" node="$3"
	log_info "dns_blackout: blocking outbound DNS (port 53, non-loopback) on $node"
	vm_run "$host" "$run_id" "$node" "sudo iptables -A OUTPUT -p udp --dport 53 ! -d 127.0.0.1 -j DROP" || fatal "dns_blackout: iptables udp rule failed on $node"
	vm_run "$host" "$run_id" "$node" "sudo iptables -A OUTPUT -p tcp --dport 53 ! -d 127.0.0.1 -j DROP" || fatal "dns_blackout: iptables tcp rule failed on $node"
	vm_run "$host" "$run_id" "$node" "sudo ip6tables -A OUTPUT -p udp --dport 53 ! -d ::1 -j DROP" || fatal "dns_blackout: ip6tables udp rule failed on $node"
	vm_run "$host" "$run_id" "$node" "sudo ip6tables -A OUTPUT -p tcp --dport 53 ! -d ::1 -j DROP" || fatal "dns_blackout: ip6tables tcp rule failed on $node"
}

# dns_restore <host> <run-id> <node>
# Removes dns_blackout's rules.
dns_restore() {
	local host="$1" run_id="$2" node="$3"
	vm_run "$host" "$run_id" "$node" "sudo iptables -D OUTPUT -p udp --dport 53 ! -d 127.0.0.1 -j DROP" >/dev/null 2>&1
	vm_run "$host" "$run_id" "$node" "sudo iptables -D OUTPUT -p tcp --dport 53 ! -d 127.0.0.1 -j DROP" >/dev/null 2>&1
	vm_run "$host" "$run_id" "$node" "sudo ip6tables -D OUTPUT -p udp --dport 53 ! -d ::1 -j DROP" >/dev/null 2>&1
	vm_run "$host" "$run_id" "$node" "sudo ip6tables -D OUTPUT -p tcp --dport 53 ! -d ::1 -j DROP" >/dev/null 2>&1
	return 0
}

# force_relay_only <host> <run-id> <node-a> <node-b>
# Blocks UDP both directions between <node-a> and <node-b>'s real
# (non-mesh) VM IPs, so a direct tetron path between them can never
# succeed and every packet is forced through relay. Needed because two
# VMs on the same libvirt network have no NAT to traverse and will
# reliably prefer direct otherwise -- confirmed live building
# oom-repro-t2-relay-eof.sh (2026-08-11): once forced, the log showed the
# relay path actually selected and in use. Call before either node's
# daemon starts (or restart both after calling) so a direct path is never
# even attempted successfully in the first place. Prints "<node-a-ip>
# <node-b-ip>" for the caller to save and pass to restore_direct_path.
force_relay_only() {
	local host="$1" run_id="$2" node_a="$3" node_b="$4"
	local ip_a ip_b
	ip_a="$(vm_run "$host" "$run_id" "$node_a" "hostname -I" | awk '{print $1}' | tr -d '\r\n')"
	ip_b="$(vm_run "$host" "$run_id" "$node_b" "hostname -I" | awk '{print $1}' | tr -d '\r\n')"
	[[ -n "$ip_a" && -n "$ip_b" ]] || fatal "force_relay_only: could not determine VM IPs for $node_a/$node_b"

	log_info "force_relay_only: blocking direct UDP between $node_a ($ip_a) and $node_b ($ip_b)"
	vm_run "$host" "$run_id" "$node_a" "sudo iptables -A OUTPUT -p udp -d $ip_b -j DROP && sudo iptables -A INPUT -p udp -s $ip_b -j DROP" || fatal "force_relay_only: could not block on $node_a"
	vm_run "$host" "$run_id" "$node_b" "sudo iptables -A OUTPUT -p udp -d $ip_a -j DROP && sudo iptables -A INPUT -p udp -s $ip_a -j DROP" || fatal "force_relay_only: could not block on $node_b"
	printf '%s %s\n' "$ip_a" "$ip_b"
}

# restore_direct_path <host> <run-id> <node-a> <node-b> <ip-a> <ip-b>
# Removes force_relay_only's rules.
restore_direct_path() {
	local host="$1" run_id="$2" node_a="$3" node_b="$4" ip_a="$5" ip_b="$6"
	vm_run "$host" "$run_id" "$node_a" "sudo iptables -D OUTPUT -p udp -d $ip_b -j DROP && sudo iptables -D INPUT -p udp -s $ip_b -j DROP" >/dev/null 2>&1
	vm_run "$host" "$run_id" "$node_b" "sudo iptables -D OUTPUT -p udp -d $ip_a -j DROP && sudo iptables -D INPUT -p udp -s $ip_a -j DROP" >/dev/null 2>&1
	return 0
}

# relay_host_in_use <host> <run-id> <node>
# Discovers which relay hostname <node>'s daemon is actually using, from
# its own log -- not assumed. Primary signal (found live 2026-08-12,
# replacing two earlier, both-flawed attempts): iroh's own node-level
# "home is now relay https://host/, was ..." line
# (iroh::socket::transports::relay::actor, info level, always present --
# dependencies stay at compiled info regardless of tetron's own log-level,
# LOG-003). This is a one-time home-relay-assignment announcement, not a
# per-connection PathEvent transition, so unlike every format this
# function tried before, it does not race with whether a given peer
# connection's path happened to already be selected before
# log_path_events subscribed to it (confirmed live: tetron::forward's
# "path selected"/"path opened" lines can be entirely absent for a
# connection that is demonstrably live and relay-connected per `tetron
# status --json`, if the path was already chosen before the subscriber
# task started -- the same subscription-timing gap PATH-DIAG-005's own
# test hit). Falls back to the older per-connection line formats
# (Display "remote_addr=relay:..." from log_path_events's info-level
# "path selected", or the Debug "Relay(...)" text only ever written at
# debug level) if the home-relay line isn't found, for robustness against
# a node that hasn't picked a home relay yet but does have a per-peer one.
# Prints the bare hostname (no scheme/trailing slash), or empty if no
# relay is in use yet (caller should retry/wait, not treat as fatal -- a
# connection needs a moment after admission to actually negotiate a path).
relay_host_in_use() {
	local host="$1" run_id="$2" node="$3"
	local raw
	raw="$(vm_run "$host" "$run_id" "$node" "sudo grep -oE 'home is now relay [^,]+' /var/log/tetron/tetron.log.* 2>/dev/null | tail -n1")"
	raw="${raw#home is now relay }"
	if [[ -z "$raw" ]]; then
		raw="$(vm_run "$host" "$run_id" "$node" "sudo grep -oE 'remote_addr=relay:[^[:space:]]+|Relay\([^)]*\)' /var/log/tetron/tetron.log.* 2>/dev/null | tail -n1")"
		raw="${raw#remote_addr=}"
		raw="${raw#Relay(}"
		raw="${raw%)}"
	fi
	echo "$raw" | sed -e 's#^relay:##' -e 's#^https\?://##' -e 's#/.*##' -e 's#\.$##' | tr -d '\r\n'
}

# verify_dns_blackout <host> <run-id> <node> <probe-hostname>
# Confirms a fresh (uncached) lookup of <probe-hostname> genuinely times
# out from <node>. Use a hostname unlikely to already be in the local
# stub's cache (the test's own relay/discovery hostname is a natural
# choice since nothing else on a fresh VM would have queried it yet).
verify_dns_blackout() {
	local host="$1" run_id="$2" node="$3" probe_hostname="$4"
	if vm_run "$host" "$run_id" "$node" "timeout 8 getent ahosts $probe_hostname" >/dev/null 2>&1; then
		log_warn "verify_dns_blackout: $node could still resolve $probe_hostname -- DNS blackout may not be effective, results should not be trusted"
		return 1
	fi
	log_pass "verify_dns_blackout: $node cannot resolve $probe_hostname (confirmed DNS blacked out)"
	return 0
}
