#!/usr/bin/env python3
"""A viewer that reads the glasstap video stream slowly, to test adaptive bitrate.

It connects to the video listener, asks for stats messages, reads at a fixed rate,
and prints the message types that it sees each second and every stats message.
Like the viewer page, it reports the bytes it has received every 250 ms on the control port.
It takes the newest viewer slot, so an open viewer page shows "Take it back".

    scripts/slow-viewer.py                    # 20 KB/s for 30 s, token from the viewer-link file
    scripts/slow-viewer.py --rate 0           # full speed
    scripts/slow-viewer.py --no-report        # like a page that does not report: host-side signal only
    scripts/slow-viewer.py --seconds 90 --full-speed-after 30   # the link recovers: does the bitrate?
    scripts/slow-viewer.py --token T --seconds 60 --rate 40
"""

import argparse
import http.client
import json
import os
import socket
import sys
import time
from collections import Counter
from urllib.parse import parse_qs, urlsplit

LINK_FILE = os.path.expanduser("~/Library/Application Support/glasstap/viewer-link")
TYPE_NAMES = {0: "config", 1: "key", 2: "delta", 3: "replaced", 4: "stats"}


def token_from_link_file():
    with open(LINK_FILE) as f:
        fragment = urlsplit(f.read().strip()).fragment
    token = parse_qs(fragment).get("token", [""])[0]
    if not token:
        sys.exit(f"no token in {LINK_FILE}")
    return token


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--token", help=f"the viewer token (default: read from {LINK_FILE})")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=9301, help="the video port (default: 9301)")
    p.add_argument("--control-port", type=int, default=9300, help="the control port for reports (default: 9300)")
    p.add_argument("--no-report", action="store_true", help="do not report the received bytes")
    p.add_argument("--rate", type=float, default=20, help="KB/s to read; 0 reads at full speed (default: 20)")
    p.add_argument("--seconds", type=float, default=30, help="exit after this long (default: 30)")
    p.add_argument("--full-speed-after", type=float, metavar="SECONDS",
                   help="read at full speed from this time on, as if the link recovered")
    p.add_argument("--rcvbuf", type=int, default=16384,
                   help="socket receive buffer in bytes. A small buffer makes the host feel the slow reader sooner"
                        " (default: 16384; 0 keeps the system default)")
    args = p.parse_args()
    token = args.token or token_from_link_file()

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if args.rcvbuf:
        # Set before connect, so that the TCP window starts small.
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, args.rcvbuf)
    s.connect((args.host, args.port))
    s.sendall(f"GET /video?token={token}&stats=1 HTTP/1.1\r\nHost: {args.host}:{args.port}\r\n\r\n".encode())

    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            sys.exit("the server closed the connection before the header")
        buf += chunk
    header, buf = buf.split(b"\r\n\r\n", 1)
    status = header.split(b"\r\n", 1)[0].decode()
    print(status)
    if status.split()[1:2] != ["200"]:
        sys.exit(1)

    rate = args.rate * 1000
    chunk_size = 4096 if rate == 0 else max(256, min(4096, int(rate / 20)))
    start = time.monotonic()
    received = 0
    # Every byte of the stream body counts, also those that came with the header.
    body_received = len(buf)
    session, next_report, last_report_status = None, 0.0, 200
    second, types, second_bytes = 0, Counter(), 0

    def print_second():
        names = ", ".join(f"{TYPE_NAMES.get(t, t)} {n}" for t, n in sorted(types.items()))
        print(f"{second + 1:4d} s  {second_bytes / 1000:6.1f} KB  {names or 'nothing'}", flush=True)

    # One connection for all reports, as the page keeps one. A new one each time would cost
    # a round trip, and through ssh -L a new SSH channel.
    control = None

    def send_report():
        nonlocal control
        body = json.dumps({"session": session, "received": body_received})
        for attempt in range(2):
            try:
                if control is None:
                    control = http.client.HTTPConnection(args.host, args.control_port, timeout=1)
                control.request("POST", "/stats", body=body,
                                headers={"X-Glasstap": token, "Content-Type": "application/json"})
                response = control.getresponse()
                response.read()
                return response.status
            except (OSError, http.client.HTTPException) as e:
                # The server may have closed an idle connection. Try once on a new one.
                control.close()
                control = None
                if attempt == 1:
                    return str(e)

    while True:
        now = time.monotonic() - start
        if now >= args.seconds:
            break
        if int(now) > second:
            print_second()
            second, types, second_bytes = int(now), Counter(), 0
        if session and not args.no_report and now >= next_report:
            next_report = now + 0.25
            status = send_report()
            # Print a failure once, not four times a second.
            if status != 200 and status != last_report_status:
                print(f"       report failed: {status}", flush=True)
            last_report_status = status
        wake = min(second + 1, args.seconds, next_report if session and not args.no_report else args.seconds)
        if rate and args.full_speed_after is not None and now >= args.full_speed_after:
            print(f"       full speed from {now:.0f} s", flush=True)
            rate, chunk_size = 0, 4096
        if rate:
            # Hold the average at the rate: wait until the bytes so far are due.
            due = received / rate
            if due > now:
                time.sleep(max(0.0, min(due, wake) - now))
                continue
        # Wake at the next second or report at the latest, so that a still screen still gets its line.
        s.settimeout(max(0.01, wake - now))
        try:
            chunk = s.recv(chunk_size)
        except socket.timeout:
            continue
        if not chunk:
            print("the server closed the stream")
            break
        received += len(chunk)
        body_received += len(chunk)
        second_bytes += len(chunk)
        buf += chunk
        while len(buf) >= 5:
            n = int.from_bytes(buf[:4], "big")
            if len(buf) < 4 + n:
                break
            kind, payload, buf = buf[4], buf[5:4 + n], buf[4 + n:]
            types[kind] += 1
            if kind == 4:
                stats = json.loads(payload)
                print(f"       stats: {stats['bitrate'] / 1000:.0f} kbit/s, {stats['fps']} fps", flush=True)
            elif kind == 0:
                print(f"       config: {payload.decode()}", flush=True)
                session = json.loads(payload).get("session")
            elif kind == 3:
                print("       replaced by another viewer")
                return
    print_second()
    s.close()
    print(f"{received / 1000:.1f} KB in {time.monotonic() - start:.1f} s")


if __name__ == "__main__":
    main()
