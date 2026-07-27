#!/usr/bin/env bash
# VM topology provisioning for tetron-testsuite: generates and drives a
# per-physical-host Vagrantfile (vagrant-libvirt provider) for an N-node
# slice of a test topology. Sourced by bin/tetron-testsuite and tests/*.sh
# -- never executed directly. Depends on lib/common.sh already being
# sourced (uses run_on, TESTSUITE_HOSTS, log_*, fatal).

set -uo pipefail

# bento/ubuntu-24.04, not debian/bookworm64: a tetron binary built locally
# with a plain `cargo build --release` links against whatever glibc the
# build host ships (glibc 2.39 on this project's own Ubuntu 24.04 dev
# machines) -- Debian 12's older glibc 2.36 then fails at runtime with
# "GLIBC_2.39 not found," found live 2026-07-27 running this suite for the
# first time. bento/ubuntu-24.04 matches the build host's own glibc floor
# and is already proven to work (the manual VM lab that produced the
# PATH-BLEED-001/TUN-CAPTURE-001 evidence used this exact box on both
# hosts). Building with `just cross` instead (tetron's own release
# pipeline, targets glibc 2.35 via the `cross` tool) would let an older box
# work too, but isn't assumed here -- see the README's Prerequisites.
: "${TESTSUITE_VM_BOX:=bento/ubuntu-24.04}"
: "${TESTSUITE_VM_MEM_MB:=512}"
: "${TESTSUITE_VM_CPUS:=1}"

readonly TESTSUITE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TESTSUITE_VAGRANTFILE_TMPL="$TESTSUITE_ROOT/templates/Vagrantfile.tmpl"

# topology_workdir <run-id>
# Path (local to the controller) used to stage generated Vagrantfiles.
# Actual VM state lives on whichever physical host runs vagrant/libvirt;
# this is just the staging/rendering location before it's copied there.
topology_workdir() {
	echo "$TESTSUITE_ROOT/DO-NOT-COMMIT/topology-work/$1"
}

# topology_render <node-count> <output-dir>
# Renders templates/Vagrantfile.tmpl into <output-dir>/Vagrantfile.
topology_render() {
	local node_count="$1"
	local out_dir="$2"
	mkdir -p "$out_dir"
	sed \
		-e "s|__NODE_COUNT__|${node_count}|g" \
		-e "s|__BOX__|${TESTSUITE_VM_BOX}|g" \
		-e "s|__MEM_MB__|${TESTSUITE_VM_MEM_MB}|g" \
		-e "s|__CPUS__|${TESTSUITE_VM_CPUS}|g" \
		"$TESTSUITE_VAGRANTFILE_TMPL" >"$out_dir/Vagrantfile"
}

# topology_remote_dir <run-id>
# Where a rendered topology lives on the physical host that runs it
# (identical path whether that host is "local" or reached over ssh).
topology_remote_dir() {
	echo "/tmp/tetron-testsuite-topology-$1"
}

# topology_up <physical-host> <run-id> <node-count>
# Renders the Vagrantfile, stages it on the physical host, and brings the
# slice up. Idempotent-ish only in the sense vagrant itself is (re-running
# against an already-up topology is a vagrant reload, not an error).
topology_up() {
	local physical_host="$1"
	local run_id="$2"
	local node_count="$3"

	local work_dir
	work_dir="$(topology_workdir "$run_id")"
	topology_render "$node_count" "$work_dir"

	local remote_dir
	remote_dir="$(topology_remote_dir "$run_id")"

	local target="${TESTSUITE_HOSTS[$physical_host]:-}"
	[[ -n "$target" ]] || fatal "topology_up: unknown host '$physical_host'"

	if [[ "$target" == "local" ]]; then
		mkdir -p "$remote_dir"
		cp "$work_dir/Vagrantfile" "$remote_dir/Vagrantfile"
	else
		run_on "$physical_host" "mkdir -p '$remote_dir'"
		scp -o BatchMode=yes "$work_dir/Vagrantfile" "${target#ssh:}:$remote_dir/Vagrantfile" >&2
	fi

	log_info "bringing up $node_count node(s) on '$physical_host' ($remote_dir)"
	run_on "$physical_host" "cd '$remote_dir' && vagrant up --provider=libvirt"
}

# topology_down <physical-host> <run-id>
# Destroys the VMs and removes the staged directory on the physical host.
topology_down() {
	local physical_host="$1"
	local run_id="$2"
	local remote_dir
	remote_dir="$(topology_remote_dir "$run_id")"

	log_info "tearing down topology '$run_id' on '$physical_host'"
	run_on "$physical_host" "cd '$remote_dir' && vagrant destroy -f" || log_warn "vagrant destroy reported an error for '$run_id' on '$physical_host' -- may need manual cleanup"
	run_on "$physical_host" "rm -rf '$remote_dir'"
}

# vm_run <physical-host> <run-id> <node-name> <command...>
# Runs a command inside one VM. This is a nested dispatch: run_on gets us
# onto the physical host (local shell or ssh), then `vagrant ssh` from
# there gets us into the VM -- deliberately the same shape as the
# ssh-jump-host-cross-network test's own jump-hosting, since both are
# "reach a thing that is only reachable from an intermediate hop."
vm_run() {
	local physical_host="$1"
	local run_id="$2"
	local node_name="$3"
	shift 3
	local remote_dir
	remote_dir="$(topology_remote_dir "$run_id")"
	run_on "$physical_host" "cd '$remote_dir' && vagrant ssh $node_name -c \"$*\""
}

# vm_upload <physical-host> <run-id> <node-name> <local-path> <remote-path>
# Uploads a local file (e.g. a built tetron binary) into one VM via
# `vagrant upload`.
vm_upload() {
	local physical_host="$1"
	local run_id="$2"
	local node_name="$3"
	local local_path="$4"
	local remote_path="$5"
	local remote_dir
	remote_dir="$(topology_remote_dir "$run_id")"

	if [[ "${TESTSUITE_HOSTS[$physical_host]}" != "local" ]]; then
		fatal "vm_upload: uploading through a remote physical host is not yet implemented -- stage the file on '$physical_host' first and use vm_run with a local path there"
	fi
	run_on "$physical_host" "cd '$remote_dir' && vagrant upload '$local_path' '$remote_path' $node_name"
}

# vm_setup_peer_ssh <physical-host> <run-id> <node-name...>
# Generates one throwaway ed25519 keypair (once per run, cached under
# DO-NOT-COMMIT/topology-work/<run-id>/sshkey/) and installs it as both the
# private key and an additional authorized_keys entry on every named node
# -- so any named node can ssh/scp/rsync into any other named node as the
# `vagrant` user, over their mesh IPs, using the same shared key at every
# hop. Needed by any test that has one VM initiate a connection to
# another VM rather than just being reached by the controller
# (vm_run/vm_upload only ever go controller -> physical host -> one VM,
# never VM -> VM).
vm_setup_peer_ssh() {
	local physical_host="$1" run_id="$2"
	shift 2
	local nodes=("$@")

	local work_dir key_dir
	work_dir="$(topology_workdir "$run_id")"
	key_dir="$work_dir/sshkey"
	mkdir -p "$key_dir"

	if [[ ! -f "$key_dir/id_ed25519" ]]; then
		ssh-keygen -q -t ed25519 -N "" -f "$key_dir/id_ed25519" -C "tetron-testsuite-$run_id" || return 1
	fi
	local pubkey
	pubkey="$(cat "$key_dir/id_ed25519.pub")"

	local node
	for node in "${nodes[@]}"; do
		vm_upload "$physical_host" "$run_id" "$node" "$key_dir/id_ed25519" "/tmp/id_ed25519_shared" || return 1
		vm_run "$physical_host" "$run_id" "$node" \
			"mkdir -p ~/.ssh && chmod 700 ~/.ssh && mv /tmp/id_ed25519_shared ~/.ssh/id_ed25519_shared && chmod 600 ~/.ssh/id_ed25519_shared && echo '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" || return 1
	done
}

# wait_for_peer_port <physical-host> <run-id> <from-node> <ip> <port> [<timeout-seconds>=30]
# Retries a plain TCP connect from inside <from-node> to <ip>:<port> (via
# bash's own /dev/tcp, no extra tools needed) every 2s until it succeeds or
# <timeout-seconds> elapses. Found necessary live 2026-07-27: a fixed sleep
# after "join" succeeds is long enough for admission/roster propagation
# (what the tests already sleep for before querying status), but not
# reliably long enough for the actual data-plane path between two freshly
# joined peers to finish establishing (NAT traversal / relay fallback can
# take a few extra seconds) -- a `scp`/`ssh` attempt made right at that
# boundary saw a real "Connection timed out," not a logic bug. Any test
# that makes a real peer-to-peer connection (not just a status query)
# should wait_for_peer_port on the target's port before attempting it.
wait_for_peer_port() {
	local physical_host="$1" run_id="$2" from_node="$3" ip="$4" port="$5"
	local timeout_s="${6:-30}"
	local waited=0
	while ((waited < timeout_s)); do
		if vm_run "$physical_host" "$run_id" "$from_node" "timeout 3 bash -c 'echo >/dev/tcp/$ip/$port'" >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
		waited=$((waited + 2))
	done
	return 1
}
