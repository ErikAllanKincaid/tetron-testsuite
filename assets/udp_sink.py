#!/usr/bin/env python3
"""Receive fixed-size UDP datagrams and report how many arrived intact.

Used by tests/oversized-udp-fragmentation-relay.sh (FRAG-004). Every
datagram is a 4-byte big-endian sequence number followed by a deterministic
byte pattern, so a datagram that was reassembled from scrambled IP fragments
is detectable as corrupt rather than merely missing -- the FRAG-004 bug
could in principle produce either outcome, and the two are worth telling
apart in the log.

Usage: udp_sink.py <bind-ip> <port> <expected-count> <payload-size> <deadline-secs>
Prints one line to stdout: "ok=<n> corrupt=<n> wrong_size=<n> distinct=<n>"
"""

import socket
import sys
import time


def pattern(size):
    """Payload bytes after the 4-byte sequence prefix."""
    return bytes((i % 251) for i in range(size - 4))


def main():
    bind_ip, port, expected, size, deadline = sys.argv[1:6]
    port, expected, size = int(port), int(expected), int(size)
    deadline = time.monotonic() + float(deadline)

    expected_tail = pattern(size)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # Room for every datagram in flight; the kernel would otherwise drop
    # some at the socket buffer under a burst and muddy the result.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    sock.bind((bind_ip, port))

    ok = corrupt = wrong_size = 0
    seen = set()
    while len(seen) < expected and time.monotonic() < deadline:
        sock.settimeout(max(0.1, deadline - time.monotonic()))
        try:
            data, _ = sock.recvfrom(65535)
        except socket.timeout:
            break
        seq = int.from_bytes(data[:4], "big") if len(data) >= 4 else -1
        seen.add(seq)
        if len(data) != size:
            wrong_size += 1
        elif data[4:] != expected_tail:
            corrupt += 1
        else:
            ok += 1

    print(f"ok={ok} corrupt={corrupt} wrong_size={wrong_size} distinct={len(seen)}")


main()
