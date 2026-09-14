#!/usr/bin/env python3
"""Send fixed-size UDP datagrams matching what udp_sink.py expects.

Each datagram is larger than tetron's 1280-byte TUN MTU on purpose: the
sending kernel splits it into IP fragments before tetron ever sees it, which
is precisely the input FRAG-004 mishandled when the peer connection's
datagram ceiling was itself below 1280 (the ordinary case on a relay path).

Usage: udp_send.py <dst-ip> <port> <count> <payload-size> <interval-secs>
"""

import socket
import sys
import time


def main():
    dst, port, count, size, interval = sys.argv[1:6]
    port, count, size = int(port), int(count), int(size)
    interval = float(interval)

    tail = bytes((i % 251) for i in range(size - 4))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for seq in range(count):
        sock.sendto(seq.to_bytes(4, "big") + tail, (dst, port))
        time.sleep(interval)
    print(f"sent={count} size={size}")


main()
