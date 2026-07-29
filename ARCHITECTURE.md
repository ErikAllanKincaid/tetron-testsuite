# tetron-testsuite Architecture

This document describes the structure, flow, and output behavior of the
tetron-testsuite project. Written 2026-07-28 after the initial v1 scaffold
was live-verified (commit 127cbd7) and several bugs were found and fixed.
Intended as a reference for anyone modifying the test runner, adding tests,
or building tooling around test output.

---

## 1. Directory structure

```
tetron-testsuite/
  bin/
    tetron-testsuite          # Runner: selects tests, executes them, reports results
  lib/
    common.sh                 # Shared library: logging, hosts.conf parser, ssh/run wrapper, JSON helpers
    topology.sh               # VM topology lifecycle: render, stage, vagrant up/down, VM operations
  tests/
    core-smoke.sh             # create -> join -> status shows peer -> leave -> gone
    regression.sh             # Regression checks for 2026-07-26 overlay-routing fixes
    alpine-musl.sh            # Musl-linked binary on Alpine Linux (no systemd path)
    rsync-transfer.sh         # rsync file between 2 VMs over mesh IP
    scp-transfer.sh           # scp file between 2 VMs over mesh IP
    http-reachability.sh      # HTTP reachability across mesh (MINIMAL-010 validation)
    ssh-pairwise.sh           # Full pairwise SSH between 3 nodes
    ssh-jump-host-cross-network.sh  # Jump-host SSH across 2 isolated tetron networks
  templates/
    Vagrantfile.tmpl          # Vagrantfile template rendered by topology.sh
  hosts.conf                  # Host inventory (gitignored, one per user)
  hosts.conf.example          # Example hosts.conf
  run-list.txt                # Master test catalog: one id per line, commented-out = excluded
  DO-NOT-COMMIT/
    topology-work/<run-id>/   # Rendered Vagrantfiles + ssh keys (gitignored)
      Vagrantfile
      sshkey/
        id_ed25519
        id_ed25519.pub
  README.md
  LICENSE                     # MPL-2.0
  .gitignore
  ARCHITECTURE.md             # This file
```

---

## 2. Complete flow of a test run

### Entry point: `bin/tetron-testsuite` (94 lines)

The runner does three things in sequence: select tests, execute them, report
results. It has no flags or options -- only positional test ids.

```bash
# Run everything uncommented in run-list.txt
./bin/tetron-testsuite

# Run specific test(s) by id, ignoring run-list.txt
./bin/tetron-testsuite core-smoke regression
```

**Test selection phase:**
- If arguments given: use those ids directly.
- If no arguments: call `select_from_run_list()`, which extracts the first
  word of every non-comment, non-blank line from `run-list.txt`.
- Exit with `fatal()` if no tests selected.

**Execution phase -- `run_one(id)`:**
1. Construct path `$TESTS_DIR/$id.sh`. If file not found: print `log_fail`
   + echo "FAIL", return.
2. Extract description metadata: `test_metadata()` greps for
   `# meta:description` in the test file.
3. Print `log_info "=== $id: <description> ==="`.
4. Execute test as a **subprocess**: `bash "$file"`. The test script is NOT
   sourced -- it runs in its own isolated shell.
5. Capture exit code `$rc`.
6. Map exit code to result:
   - `$rc == 0` --> `log_pass "$id"` + echo "PASS"
   - `$rc == 77` (SKIP_CODE) --> `log_warn "$id: SKIPPED"` + echo "SKIP"
   - Otherwise --> `log_fail "$id (exit $rc)"` + echo "FAIL"

Key design detail: the runner captures **only the last line** of the test's
stdout via `result="$(run_one "$id" | tail -n1)"`. This is the PASS/FAIL/SKIP
echo. The rest of the test's output (log messages, vagrant output, command
output) goes through stderr unfiltered.

**Summary phase:**
- Print blank line, then `=== summary ===`.
- For each test id: `printf '%-40s %s\n' "$id" "${results[$id]}"`.
- Print `$pass passed, $fail failed, $skip skipped`.
- Exit with `[[ $fail -eq 0 ]]` -- non-zero exit if any test failed.

### Test script lifecycle (example: `core-smoke.sh`, 96 lines)

Every test script follows the same pattern:

```bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp              # preflight: check required CLI tools

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="core-smoke-$$"              # unique run id for this execution
BROUGHT_UP=0

cleanup() {
    [[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT                   # always clean up VMs

main() {
    # 1. Skip check: if tetron binary missing -> log_warn + exit 77
    if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
        log_warn "...skipping"
        exit "$TESTSUITE_SKIP_CODE"
    fi

    # 2. Load hosts.conf, select physical host
    load_hosts_conf "$ROOT/hosts.conf"
    if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
        TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
    fi
    log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

    # 3. Bring up VMs
    topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "...topology_up failed"
    BROUGHT_UP=1

    # 4. Provision VMs (upload binary, install)
    vm_upload ... || fatal "...vm_upload failed"
    vm_run ... "sudo install ... && sudo tetron install" || fatal "...install failed"

    # 5. Drive tetron (create, join, status, leave)
    # 6. Assert on results (log_pass/log_fail, exit 1 on failure)
    # 7. If all pass, implicit exit 0 at end of main
}
main
```

### Phases within a test (visible from log output)

| Phase | What happens | Log marker |
|---|---|---|
| **Preflight** | binary existence check, `require_cmd` | `[warn]` if binary missing (skip) |
| **Host selection** | `load_hosts_conf`, pick first host | `[info] using physical host:` |
| **Rendering** | `topology_render` writes Vagrantfile (called by `topology_up`) | (silent unless error) |
| **Staging** | `topology_up` copies Vagrantfile to target host | (silent unless error) |
| **Vagrant up** | `topology_up` runs `vagrant up --provider=libvirt` | `[info] bringing up N node(s) on 'host'` |
| **Provisioning** | `vm_upload` + `vm_run` to install tetron + dependencies | test-id-specific messages |
| **Tetron operations** | create, join, status, leave | test-id-specific messages |
| **Asserting** | `json_get`, checksum compare, ssh checks | `[pass]` / `[fail]` per assertion |
| **Teardown** | `trap cleanup EXIT` -> `topology_down` | `[info] tearing down topology` |

### 2c. Phase tracking: How the runner knows what phase each test is in

**It does not know.** There is no structured phase tracking. The runner
spawns the test as a subprocess (`bash "$file"`) and only sees its exit
code. All phase information is embedded in the test's own log output, which
interleaves with vagrant's own output and the test's commands' output. The
only way to tell what phase a test is in is to read the `[info]`/`[warn]`
`[fail]`/`[pass]` log lines inline as they scroll by.

The phases (rendering, staging, vagrant up, provisioning, asserting,
teardown) are implicit in the sequence of function calls each test makes.
There are no formal state transitions or phase-change hooks anywhere in the
codebase. This is the single most important architectural constraint: **the
runner can not see inside a running test.**

---

## 3. `lib/topology.sh` -- in detail

**File:** 193 lines. Sourced by test scripts (and indirectly by the runner).
Never executed directly.

### Core functions

| Function | Signature | Purpose |
|---|---|---|
| `topology_workdir` | `<run-id>` | Returns local staging path: `$ROOT/DO-NOT-COMMIT/topology-work/<run-id>` |
| `topology_render` | `<node-count> <output-dir>` | Renders Vagrantfile from template by substituting `__NODE_COUNT__`, `__BOX__`, `__MEM_MB__`, `__CPUS__` via `sed` |
| `topology_remote_dir` | `<run-id>` | Returns path on physical host: `/tmp/tetron-testsuite-topology-<run-id>` |
| `topology_up` | `<physical-host> <run-id> <node-count>` | Renders Vagrantfile, copies to host (scp or local cp), runs `vagrant up --provider=libvirt` |
| `topology_down` | `<physical-host> <run-id>` | Runs `vagrant destroy -f` then `rm -rf` of remote dir on the physical host |
| `vm_run` | `<physical-host> <run-id> <node-name> <command...>` | Runs command inside a VM: controller -> physical host (`run_on`) -> VM (`vagrant ssh node_name -c "..."`) |
| `vm_upload` | `<physical-host> <run-id> <node-name> <local-path> <remote-path>` | Uploads file into a VM via `vagrant upload` (currently only works for `local` physical host) |
| `vm_setup_peer_ssh` | `<physical-host> <run-id> <node-name...>` | Generates one ed25519 keypair per run-id, uploads to every named node, adds pubkey to `authorized_keys` -- enables VM-to-VM ssh/scp/rsync |
| `wait_for_peer_port` | `<physical-host> <run-id> <from-node> <ip> <port> [timeout=30]` | Polls TCP connect from one VM to another via `/dev/tcp` every 2s until success or timeout |

### Configurable defaults

```bash
TESTSUITE_VM_BOX=bento/ubuntu-24.04    # Vagrant box
TESTSUITE_VM_MEM_MB=512                # RAM per VM
TESTSUITE_VM_CPUS=1                    # vCPUs per VM
```

### Outputs during operation

- **`topology_up`**: prints `[info] bringing up N node(s) on '<host>'`
  then vagrant's own output streams through stderr from the child process.
- **`topology_down`**: prints `[info] tearing down topology '<run-id>'
  on '<host>'`, may print `[warn] vagrant destroy reported an error...`
- **No structured output** -- all messages use `log_info()` from
  `common.sh`.

### SSH staging details

When target is `local`: `cp "$work_dir/Vagrantfile" "$remote_dir/Vagrantfile"`
When target is `ssh:host`: `scp "$work_dir/Vagrantfile" "host:$remote_dir/Vagrantfile"`

On remote hosts, the rendered Vagrantfile lives at
`/tmp/tetron-testsuite-topology-<run-id>/` and vagrant manages VMs from
there.

---

## 4. `lib/common.sh` -- in detail

**File:** 94 lines. Sourced by the runner and all test scripts. Never
executed directly.

### Logging functions (all print to stderr via `>&2`)

```bash
log_info()  { printf '[info]  %s\n' "$*" >&2; }
log_warn()  { printf '[warn]  %s\n' "$*" >&2; }
log_error() { printf '[error] %s\n' "$*" >&2; }
log_pass()  { printf '[pass]  %s\n' "$*" >&2; }
log_fail()  { printf '[fail]  %s\n' "$*" >&2; }
```

Key properties:
- All log output goes to **stderr** (file descriptor 2).
- No ANSI codes, no color, no escape sequences anywhere in the codebase.
- All output is plain text with a `[label]` prefix.
- There is no `--verbose`/`--quiet` flag, no `LOG_LEVEL` variable, no
  structured JSON output from the test runner itself.
- The final summary table (PASS/FAIL/SKIP) goes to stdout -- this is how
  `run_one()`'s `tail -n1` filtering works. Stderr passes through, last
  line of stdout is the result token.

### Other helpers

| Function | Purpose |
|---|---|
| `require_cmd <cmd...>` | Checks each command exists on the controller, `fatal()` if not |
| `load_hosts_conf <path>` | Parses hosts.conf into global associative array `TESTSUITE_HOSTS[name]=target`. Skips `#` comments and blank lines. Format: `<name> <target>` where target is `local` or `ssh:user@host` |
| `run_on <host-name> <command...>` | Runs command on host: if `local` -> `bash -c "$*"`; if `ssh:*` -> `ssh -o BatchMode=yes <target> "$@"` |
| `tetron_json <host-name> <subcommand args...>` | Runs `tetron <args...> --json` on host, prints raw JSON to stdout |
| `json_get <jq-filter> <json-text>` | Pipes JSON through `jq -r` with the given filter |

### Constants

```bash
TESTSUITE_SKIP_CODE=77                                    # Autotools-style skip
TESTSUITE_PEER_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
```

---

## 5. How test scripts signal PASS/FAIL/SKIP

This is the central mechanism. The runner communicates with the test
subprocess through exactly three channels: exit code, last stdout line,
and everything else on stderr.

| Exit code | Meaning | Triggered by | Detected by runner via |
|---|---|---|---|
| **0** | PASS | Implicit at end of `main()` | `$rc -eq 0` |
| **77** | SKIP | `exit "$TESTSUITE_SKIP_CODE"` when binary missing or precondition not met | `$rc -eq $SKIP_CODE` |
| **non-0, non-77** | FAIL | `exit 1` from assertion failures, or `fatal()` which calls `exit 1` | `else` branch |

How tests produce pass/fail output:
- Each assertion calls `log_pass "description"` (stderr) on success.
- Each assertion calls `log_fail "description"` (stderr) followed by
  `exit 1` on failure.
- Some tests (`regression.sh`, `ssh-pairwise.sh`) use an `rc` accumulator:
  multiple checks set `rc=1` on failure, then `return $rc` from `main()`.

The runner captures results by:
```bash
result="$(run_one "$id" | tail -n1)"
```
Every test subprocess has exactly one stdout line: the `echo "PASS"`,
`echo "FAIL"`, or `echo "SKIP"` produced by `run_one()` itself, not by the
test. The test only reports its exit code; `run_one()` translates it to the
result word.

---

## 6. `templates/Vagrantfile.tmpl` -- in detail

**File:** 28 lines. A Ruby ERB-style template rendered by `topology_render`
via `sed`.

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "__BOX__"
  config.vm.synced_folder ".", "/vagrant", disabled: true

  (1..__NODE_COUNT__).each do |i|
    config.vm.define "node#{i}" do |node|
      node.vm.hostname = "node#{i}"
      node.vm.provider :libvirt do |lv|
        lv.memory = __MEM_MB__
        lv.cpus = __CPUS__
      end
    end
  end
end
```

Template placeholders (substituted by `sed`):
- `__NODE_COUNT__` -- number of VMs
- `__BOX__` -- Vagrant box name
- `__MEM_MB__` -- RAM per VM
- `__CPUS__` -- vCPUs per VM

Synced folders disabled (NFS not assumed). VMs are named `node1`, `node2`,
etc. No explicit network configuration -- VMs get libvirt's default NAT
network.

---

## 7. `run-list.txt` format and test selection

**File:** 16 lines.

```
# tetron-testsuite run list.
#
# This file IS the master test catalog -- every known test is listed here.
# Uncomment a line to include it in the next ./bin/tetron-testsuite run.

regression
#core-smoke
#rsync-transfer
#scp-transfer
#http-reachability
#ssh-pairwise
#ssh-jump-host-cross-network
```

Format: one test id per line. Lines starting with `#` (even indented) or
blank are ignored. The runner's `select_from_run_list()` parses it:

```bash
grep -vE '^\s*(#|$)' "$RUN_LIST" | awk '{print $1}'
```

This extracts the first whitespace-delimited word from each non-comment,
non-blank line. Each id must match `tests/<id>.sh`.

---

## 8. Current output format -- complete description

**There is no color, no ANSI codes, no structured JSON output anywhere.**
The entire output is plain text with fixed `[label]` prefixes.

### Output stream breakdown

| Stream | Content | Example |
|---|---|---|
| **stdout** | Per-test result token (PASS/FAIL/SKIP) + final summary table | `PASS` / `FAIL` / `SKIP` + `=== summary ===` + `core-smoke PASS` |
| **stderr** | All log messages, vagrant output, command output, error details | `[info]  === core-smoke: Core smoke... ===` |

### Complete example of a run output

```
[info]  === core-smoke: Core smoke test: create -> join -> status shows peer -> leave -> gone ===
[info]  using physical host: aorus
[info]  bringing up 2 node(s) on 'aorus' (/tmp/tetron-testsuite-topology-core-smoke-1234)
    <vagrant output interleaved here>
[pass]  core-smoke: node1 sees node2 as a member after join
[pass]  core-smoke: node1 sees node2 gone after leave
PASS
[info]  === regression: Regression checks... ===
[info]  using physical host: aorus
[info]  bringing up 1 node(s) on 'aorus' (/tmp/tetron-testsuite-topology-regression-1235)
[pass]  SELFCAPTURE-ROUTE-001: ip rule ... present
[pass]  SUBNET-COLLISION-001: overlapping --subnet refused without --force
[pass]  SUBNET-COLLISION-001: --force overrides the overlap refusal
PASS

=== summary ===
core-smoke                                PASS
regression                                PASS
1 passed, 0 failed, 0 skipped
```

### Format of each message type

| Type | Format | Goes to |
|---|---|---|
| `log_info` | `[info]  <message>` | stderr |
| `log_warn` | `[warn]  <message>` | stderr |
| `log_error` | `[error] <message>` | stderr |
| `log_pass` | `[pass]  <message>` | stderr |
| `log_fail` | `[fail]  <message>` | stderr |
| `fatal` | `[error] <message>` then `exit 1` | stderr |
| Test result token | `PASS` / `FAIL` / `SKIP` (bare, no prefix) | stdout |
| Summary header | `=== summary ===` | stdout |
| Summary row | `<id> <40-char left-padded> PASS/FAIL/SKIP` | stdout |
| Summary totals | `<N> passed, <N> failed, <N> skipped` | stdout |

---

## 9. Environment variables and flags controlling output

**There are no options for output behavior.** The runner accepts only
positional test ids. There is no `--verbose`, `--quiet`, `--json`, or
`--format`. There is no `LOG_LEVEL`, no `NO_COLOR` (there is no color to
disable), no output file flags.

### Environment variables (all for test behavior, not output)

| Variable | Default | Function |
|---|---|---|
| `TESTSUITE_TETRON_BINARY` | `../tetron/target/release/tetron` | Path to tetron binary to install on VMs |
| `TESTSUITE_PHYSICAL_HOST` | First host alphabetically from hosts.conf | Which physical host to provision VMs on |
| `TESTSUITE_VM_BOX` | `bento/ubuntu-24.04` | Vagrant box for all VMs |
| `TESTSUITE_VM_MEM_MB` | `512` | MB RAM per VM |
| `TESTSUITE_VM_CPUS` | `1` | vCPUs per VM |

---

## 10. Key architectural notes

1. **Tests are subprocesses, not sourced.** The runner executes
   `bash "$file"`, so each test runs in a completely isolated shell
   environment. The test can not affect the runner's variables. This is
   intentional: isolation, no side effects, no namespace pollution.

2. **Result extraction is stdout-based.** The runner captures only the
   last line of the test's stdout via `| tail -n1`. All other output
   (log messages, command results, error details) goes to stderr and
   passes through unfiltered. This means stdout is a reserved channel --
   tests must not print anything to stdout that is not the expected
   result token.

3. **No structured output at all.** There is no JSON-lines output, no
   machine-parseable events, no log file output. The only structured
   output is the final summary table, and that is formatted as plain
   text with `printf`.

4. **Color: zero.** Zero ANSI escape sequences, zero `tput` calls, zero
   `NO_COLOR` support (there is nothing to disable).

5. **Phase tracking: implicit only.** The runner does not track or emit
   phase information. Each test script manages its own lifecycle and
   emits its own `[info]` messages describing what it is doing. There is
   no way for an external observer (web UI, logging system) to know what
   phase a test is in without parsing the free-text log messages.

6. **Cleanup is guaranteed via traps.** Every test sets `trap cleanup
   EXIT` before doing anything, and the cleanup guard (`BROUGHT_UP=0` /
   `BROUGHT_UP=1`) ensures `topology_down` only runs if `topology_up`
   succeeded. This is critical because VMs are expensive resources.

7. **Vagrant output is uncontrolled.** When `topology_up` runs
   `vagrant up`, vagrant's own progress output flows through to stderr
   directly, interleaved with the test's own log lines. There is no
   suppression or reformatting of vagrant output.

8. **No persistent daemon or server.** The runner starts, runs tests,
   and exits. There is no background process that could serve a
   dashboard or maintain state between runs.

9. **Minimal dependencies.** Currently depends on: bash, jq, ssh, scp,
   vagrant. Adding a new dependency (especially a language runtime) is a
   high bar.
