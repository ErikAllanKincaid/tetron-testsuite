# tetron-testsuite

An automated VM testing suite for [tetron](https://github.com/ErikAllanKincaid/tetron), a P2P mesh VPN. It provisions disposable VM topologies, installs a tetron build on each, drives tetron entirely through its own CLI/`--json` output (the same way manual live-testing already worked), and asserts on real network behavior.

**Optional and separate from tetron on purpose**, same relationship tetron-webui and tetron-systray have to core: a genuinely separate, opt-in addon. Nothing about tetron's own behavior changes whether this exists or not. This addon tests whatever tetron binary you point it at; it does not carry a wire-compatibility relationship with one specific core version, so it versions independently rather than mirroring tetron's own minor version.

## Prerequisites (not automated -- set these up yourself first)

This suite deliberately does no preflight/auto-install/auto-detect logic of its own -- if any of the below is missing on a declared host, tests against that host will fail with whatever error `vagrant`/`ssh` produces, and this suite will not diagnose or fix environment setup for you. Run the following once on **every host** you intend to list in `hosts.conf` (both `local` and any `ssh:` target), before running any test.

### 1. Confirm hardware virtualization is available

```bash
grep -E '(vmx|svm)' /proc/cpuinfo >/dev/null && echo "virtualization extensions present" || echo "NOT PRESENT -- stop here, this host cannot run KVM guests"
ls /dev/kvm 2>/dev/null && echo "/dev/kvm exists" || echo "/dev/kvm missing -- install qemu-kvm below, then re-check"
```

If `/dev/kvm` is still missing after installing `qemu-kvm` (next step), that host will fall back to slow software emulation for its VMs -- workable for these tests (they are not compute-heavy), but noticeably slower to boot.

### 2. Install libvirt/KVM (Debian/Ubuntu -- adjust package manager for other distros)

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst

sudo usermod -aG libvirt,kvm "$USER"
# Log out and back in (or `newgrp libvirt`) for the group change to take effect
# before continuing -- the next steps assume it already has.
```

### 3. Install Vagrant

Distro package repos often lag behind; use HashiCorp's own apt repo instead:

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y vagrant
```

### 4. Install the vagrant-libvirt plugin

```bash
vagrant plugin install vagrant-libvirt
```

### 5. Install the other controller-side tools this suite's own scripts call directly

```bash
sudo apt install -y jq openssh-client
```

`jq` is only needed on the **controller** (the machine you run `./bin/tetron-testsuite` from), not on every declared host -- `lib/common.sh`'s `json_get` pipes a VM's `tetron status --json` output back to the controller and parses it there.

### 6. Sanity check everything above actually worked

```bash
virsh list --all      # should run with no error -- proves the libvirt daemon + your group membership are correct
vagrant plugin list    # should list vagrant-libvirt
vagrant box list       # first real run will download debian/bookworm64 automatically; fine if empty now
```

### 7. For any host reached over SSH (a `hosts.conf` entry that is not `local`)

Trust must already work non-interactively -- this suite never prompts for a password or passphrase.

```bash
ssh-copy-id user@remote-host          # if you don't already have a trusted key there
ssh -o BatchMode=yes user@remote-host true && echo "passwordless ssh works"
```

If you use an agent-forwarded or `IdentityFile`-pinned key via `~/.ssh/config` instead of a bare `user@host`, that Host alias is exactly what should go in `hosts.conf` as the SSH target (see `hosts.conf.example`) -- `run_on` shells out to plain `ssh`, so anything `ssh` itself resolves works here too.

### Summary checklist

- [ ] `/proc/cpuinfo` shows `vmx`/`svm`, and `/dev/kvm` exists
- [ ] `qemu-kvm` + `libvirt-daemon-system` installed, your user in `libvirt`/`kvm` groups (re-logged-in)
- [ ] `vagrant` installed, `vagrant-libvirt` plugin installed
- [ ] `jq` installed on the controller
- [ ] `virsh list --all` and `vagrant plugin list` both run clean
- [ ] Any SSH-reached host accepts a passwordless `ssh -o BatchMode=yes <target> true`

## Design

- **Bash + Python, not Rust.** This addon does not link `tetron-proto`; it drives tetron black-box, so there is no need for the Cargo toolchain tetron-webui/tetron-systray require.
- **Host inventory is fully generic.** `hosts.conf` lists hosts as `local` or an SSH target. The code never distinguishes "same LAN" from "different network reached over the open internet" -- both are just an inventory entry with a reachable target. No hostnames are hardcoded anywhere in the scripts.
- **No named tiers.** There is no "Basic/Medium/Advanced" concept. Every test is a flat, independently selectable unit, including regression -- nothing is special-cased to "always run."
- **`run-list.txt` is the master catalog, not a separate list plus a curated selection.** It ships with every known test listed as one line each. All are commented out except the regression test, which stays active by default. Editing this file to add/remove entries from a run is a purely manual, direct edit for v1 -- there is no helper script.
- **One test = one file**, living flat in `tests/` for v1. Test discovery uses stable ids and would glob recursively if subdirectories are introduced later, even though only one level exists today.
- **Topology is parameterized from day one**, not bolted on later: `lib/topology.sh` takes node count, network count, and a host-assignment map, and generates a `Vagrantfile` from `templates/Vagrantfile.tmpl`. This is required even for v1, since one of the seven launch tests (`ssh-jump-host-cross-network`) specifically needs a multi-network topology, not just a single shared network.

## Layout

```
hosts.conf.example   -- copy to hosts.conf (gitignored) and edit for your fleet
run-list.txt          -- master test catalog; uncomment a line to include it in a run
bin/tetron-testsuite   -- the runner: reads run-list.txt, executes each enabled test, prints a summary
lib/common.sh          -- logging, hosts.conf parsing, local/ssh command wrapper, tetron JSON helpers
lib/topology.sh         -- N-node/M-network VM topology generation (vagrant-libvirt) and lifecycle
templates/Vagrantfile.tmpl -- template rendered by lib/topology.sh
tests/*.sh              -- one file per test, metadata header + body
```

## Test file convention

Every file in `tests/` opens with a metadata header, parsed by the runner as `# meta:<key> <value>` lines:

```bash
#!/usr/bin/env bash
# meta:id core-smoke
# meta:description Core smoke test: create -> join -> status shows peer -> leave -> gone
# meta:nodes 2
# meta:networks 1
```

`nodes`/`networks` tell the runner what topology to bring up via `lib/topology.sh` before running the test body. The body is free to use `lib/common.sh`'s helpers to run `tetron` commands on any declared node and assert on the result. A test exits `0` for pass, non-zero for fail; `tests/` scripts not yet implemented exit with a distinct SKIP code and print why, rather than silently reporting a false pass.

## Running

```bash
cp hosts.conf.example hosts.conf   # edit for your fleet
./bin/tetron-testsuite              # runs everything uncommented in run-list.txt
./bin/tetron-testsuite core-smoke   # runs one test by id, regardless of run-list.txt
```

## v1 test list

1. `regression` -- the five 2026-07-26 overlay-routing fixes (`TUN-CAPTURE-001`, `PATH-BLEED-001`, `SUBNET-COLLISION-001`, `SUBNET-COLLISION-002`, `SELFCAPTURE-ROUTE-001`).
2. `core-smoke` -- create, join, status shows peer, leave, gone.
3. `rsync-transfer` -- file transfer between two VMs over their mesh IPs.
4. `scp-transfer` -- deliberately separate from rsync, not folded together.
5. `http-reachability` -- validates `MINIMAL-010`'s "every mesh peer reaches every port a local service binds" claim directly.
6. `ssh-pairwise` -- SSH between every node in the topology.
7. `ssh-jump-host-cross-network` -- validates `MULTISEG-003`'s documented jump-hosting workaround across two tetron networks with no direct route between them.

All seven are implemented and have each passed at least one full live run against real VMs on real hardware (`aorus`) as of this writing -- not just syntax-checked. `rsync-transfer`, `scp-transfer`, and `ssh-pairwise`/`ssh-jump-host-cross-network` additionally use `lib/topology.sh`'s `vm_setup_peer_ssh` helper -- it installs one throwaway shared keypair across the named VMs so they can `ssh`/`scp`/`rsync` each other directly over their mesh IPs (`vm_run`/`vm_upload` alone only ever reach controller -> physical host -> one VM, never VM -> VM). `wait_for_peer_port` (also `lib/topology.sh`) retries a plain TCP connect before any test attempts a real peer-to-peer connection -- a fixed sleep after "join" was found live to not always be enough time for the actual data-plane path between two fresh peers to finish establishing, even once admission itself has propagated. A single live run is evidence the happy path works, not a guarantee against flakiness on a different host or a slower boot -- re-run before trusting a specific result under time pressure.

A second-pass backlog (invite/admission lifecycle, membership mutations, config-knob round-trips, resilience, IPv6, rate-limit abuse testing) exists but is explicitly deferred past v1.

## License

MPL-2.0. See `LICENSE`.
