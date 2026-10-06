#!/usr/bin/env python3
"""Newest-frame relay for the WDA MJPEG stream.

Runs on the Mac that has the iPhone. It reads the stream from localhost,
keeps only the newest frame, and serves it smaller on request. Each frame goes
out only when a client asks for it, so frames never queue on a slow link and
the picture stays current.

Usage: phone_frame_relay.py [port] [width] [jpeg-quality]
GET /frame?c=<client> waits up to 2 s for a frame that this client did not get
yet. It answers 200 with the JPEG and an X-Frame-Id header, or 204 if no new
frame came. A client can keep several requests open, and each one gets a
different, newer frame. This hides the round trip of a slow link.
"""
import hmac
import io
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from PIL import Image

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9150
WIDTH = int(sys.argv[2]) if len(sys.argv) > 2 else 393
QUALITY = int(sys.argv[3]) if len(sys.argv) > 3 else 60

# Only the viewer page may read frames. "*" would let any website read the screen.
VIEWER_ORIGINS = {"http://127.0.0.1:9300", "http://localhost:9300"}

cond = threading.Condition()
latest = {"id": 0, "raw": None, "jpg": None}
sent = {}  # client id -> id of the newest frame sent to it


def frames():
    """Yield JPEG frames from the WDA MJPEG stream, split by Content-Length."""
    s = socket.create_connection(("localhost", 9100), timeout=10)
    s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    buf = b""
    while True:
        chunk = s.recv(262144)
        if not chunk:
            return
        buf += chunk
        while True:
            i = buf.lower().find(b"content-length:")
            if i < 0:
                break
            j = buf.find(b"\r\n\r\n", i)
            if j < 0:
                break
            n = int(buf[i + 15:buf.find(b"\r\n", i)].strip())
            if len(buf) < j + 4 + n:
                break
            yield buf[j + 4:j + 4 + n]
            buf = buf[j + 4 + n:]


def reader():
    while True:
        try:
            for raw in frames():
                with cond:
                    if raw == latest["raw"]:
                        continue
                    latest.update(id=latest["id"] + 1, raw=raw, jpg=None)
                    cond.notify_all()
        except Exception as e:
            print("stream error:", e, flush=True)
        time.sleep(1)


def encoded():
    """Return (id, smaller JPEG) for the newest frame. Encode each frame once."""
    with cond:
        fid, raw, jpg = latest["id"], latest["raw"], latest["jpg"]
    if jpg is None:
        im = Image.open(io.BytesIO(raw)).convert("RGB")
        h = round(im.height * WIDTH / im.width)
        out = io.BytesIO()
        im.resize((WIDTH, h), Image.BILINEAR).save(out, "JPEG", quality=QUALITY)
        jpg = out.getvalue()
        with cond:
            if latest["id"] == fid:
                latest["jpg"] = jpg
    return fid, jpg


def read_token():
    """The token of this run, or None. With no token, the relay refuses every request."""
    try:
        with open(os.path.expanduser("~/.tapstream/token")) as f:
            return f.read().strip() or None
    except OSError:
        return None


class Handler(BaseHTTPRequestHandler):
    # Keep connections open. Through an SSH tunnel, each new connection costs
    # an extra round trip to open a channel.
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def cors(self):
        origin = self.headers.get("Origin")
        if origin in VIEWER_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Expose-Headers", "X-Frame-Id")
            self.send_header("Vary", "Origin")

    def empty(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.cors()
        self.end_headers()

    def do_GET(self):
        # Reject DNS rebinding: a foreign site name that points at 127.0.0.1.
        if (self.headers.get("Host") or "").rsplit(":", 1)[0] not in ("127.0.0.1", "localhost"):
            return self.empty(403)
        if urlparse(self.path).path != "/frame":
            return self.empty(404)
        query = parse_qs(urlparse(self.path).query)
        # Require the token that phone-remote wrote, so that other local users cannot read the screen.
        expected = read_token()
        if expected is None or not hmac.compare_digest(query.get("token", [""])[0], expected):
            return self.empty(403)
        client = query.get("c", [""])[0]
        with cond:
            # Claim the frame while holding the lock, so that two open requests
            # from one client never get the same frame.
            ready = cond.wait_for(
                lambda: latest["raw"] is not None and latest["id"] > sent.get(client, 0),
                timeout=2)
            if ready:
                sent[client] = latest["id"]
        if not ready:
            return self.empty(204)
        fid, jpg = encoded()
        with cond:
            # A newer frame may have arrived since the claim. Record that one.
            sent[client] = max(sent.get(client, 0), fid)
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(jpg)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Id", str(fid))
        self.cors()
        self.end_headers()
        self.wfile.write(jpg)


if __name__ == "__main__":
    threading.Thread(target=reader, daemon=True).start()
    print(f"frame relay on 127.0.0.1:{PORT}, width {WIDTH}, quality {QUALITY}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
