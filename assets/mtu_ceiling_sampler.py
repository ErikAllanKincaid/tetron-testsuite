#!/usr/bin/env python3
"""Sample this node's per-peer QUIC datagram ceiling over time.

Disposable instrumentation for the branch-2 (initial_mtu) question: how
long does max_datagram_size stay below tetron's 1280-byte TUN MTU at the
start of a connection, and what does it settle at? Runs inside a VM and
polls `tetron status --json` (MTU-DIAG-001's per-peer
connection.max_datagram_size), writing one whitespace-separated row per
sample: <unix-seconds> <max_datagram_size|none> <conn_type|none>

Usage: mtu_ceiling_sampler.py <out-path> <duration-secs> [interval-secs]
"""

import json
import subprocess
import sys
import time


def sample():
    """(max_datagram_size, conn_type) for the first peer, or (None, reason)."""
    try:
        raw = subprocess.run(
            ["tetron", "status", "--json"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        doc = json.loads(raw)
    except Exception as exc:
        return None, f"err:{type(exc).__name__}"
    nets = doc.get("networks") or []
    if not nets:
        return None, "no-network"
    peers = nets[0].get("peers") or []
    if not peers:
        return None, "no-peer"
    conn = peers[0].get("connection")
    if not conn:
        return None, "no-connection"
    return conn.get("max_datagram_size"), conn.get("conn_type")


def main():
    out_path, duration = sys.argv[1], float(sys.argv[2])
    interval = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    end = time.monotonic() + duration
    with open(out_path, "w") as out:
        while time.monotonic() < end:
            mds, ct = sample()
            out.write(f"{time.time():.3f} {mds if mds is not None else 'none'} {ct}\n")
            out.flush()
            time.sleep(interval)


main()
