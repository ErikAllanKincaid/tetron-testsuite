# tetron-testsuite

An automated VM testing suite for [tetron](https://github.com/ErikAllanKincaid/tetron), a P2P mesh VPN. It provisions disposable VM topologies, installs a tetron build on each, drives tetron entirely through its own CLI/`--json` output (the same way manual live-testing already worked), and asserts on real network behavior.

**Optional and separate from tetron on purpose**, same relationship tetron-webui and tetron-systray have to core: a genuinely separate, opt-in addon. Nothing about tetron's own behavior changes whether this exists or not. This addon tests whatever tetron binary you point it at; it does not carry a wire-compatibility relationship with one specific core version, so it versions independently rather than mirroring tetron's own minor version.

## Prerequisites (not automated -- verify these yourself first)

This suite deliberately does no preflight/auto-install/auto-detect logic. It assumes every host named in your `hosts.conf` already has, on that host:

- `vagrant` with the `vagrant-libvirt` plugin installed (`vagrant plugin install vagrant-libvirt`)
- `qemu-kvm` and `libvirt-daemon-system` installed and running
- Your user in the `libvirt`/`kvm` groups (re-login after adding)
- `/dev/kvm` present and usable
- For any host reached over SSH (not `local`): the SSH key already trusted, passwordless (or agent-forwarded) access working

If any of this is missing on a declared host, tests against that host will fail with whatever error `vagrant`/`ssh` produces -- this suite will not diagnose or fix environment setup for you.

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

Only `regression` and `core-smoke` are fully implemented as of this writing; the rest are stubs with the same metadata-header convention, ready to fill in. See each file's own header for status.

A second-pass backlog (invite/admission lifecycle, membership mutations, config-knob round-trips, resilience, IPv6, rate-limit abuse testing) exists but is explicitly deferred past v1.

## License

MPL-2.0. See `LICENSE`.
