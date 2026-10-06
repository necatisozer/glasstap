#!/usr/bin/env python3
"""Interactive remote for an iPhone through WebDriverAgent.

Serves a page on 127.0.0.1:9300 that shows the phone screen and turns
clicks into taps, drags into swipes, and text into key presses.
"""
import base64
import hmac
import http.client
import json
import os
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# WDA is reached through a Unix socket, not a TCP port. WDA allows any origin
# and has no authentication, so a TCP port would let any website control the iPhone.
WDA_SOCKET = os.environ.get("PHONE_REMOTE_WDA_SOCKET", os.path.expanduser("~/.tapstream/wda.sock"))
# Every request must carry this token, so that other local users and other
# websites cannot see or control the iPhone.
TOKEN = os.environ.get("PHONE_REMOTE_TOKEN", "")
# The newest-frame relay (phone_frame_relay.py), reached through a tunnel.
FRAMES = "http://127.0.0.1:9200/frame"
# If set, the page plays the H.265/H.264 stream of iPhoneCapture.app instead.
VIDEO = os.environ.get("PHONE_REMOTE_VIDEO", "")
PORT = 9300
state = {"sid": None, "size": None}


class WDAError(Exception):
    pass


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def wda(method, path, body=None, timeout=30):
    conn = UnixHTTPConnection(WDA_SOCKET, timeout)
    try:
        conn.request(method, path, body=json.dumps(body) if body is not None else None,
                     headers={"Content-Type": "application/json"})
        r = conn.getresponse()
        data = r.read()
    finally:
        conn.close()
    if r.status >= 400:
        raise WDAError(f"WDA {r.status}: {data[:200].decode(errors='replace')}")
    return json.loads(data)


def session():
    if not state["sid"]:
        sid = wda("GET", "/status").get("sessionId")
        if not sid:
            sid = wda("POST", "/session",
                      {"capabilities": {"alwaysMatch": {"platformName": "iOS"}}})["sessionId"]
        state["sid"] = sid
    # Fetch the size whenever it is missing. An earlier failure can leave a session without one.
    if not state["size"]:
        state["size"] = wda("GET", f"/session/{state['sid']}/window/size")["value"]
    return state["sid"]


def pointer(moves):
    return {"actions": [{"type": "pointer", "id": "finger1",
                         "parameters": {"pointerType": "touch"}, "actions": moves}]}


def act(kind, p):
    # Reuse the cached session. If WDA rejects it, get a fresh one and retry once.
    try:
        return send(kind, p, session())
    except WDAError:
        state["sid"] = state["size"] = None
        return send(kind, p, session())


def send(kind, p, sid):
    if kind == "tap":
        x, y = round(p["x"]), round(p["y"])
        return wda("POST", f"/session/{sid}/actions", pointer([
            {"type": "pointerMove", "duration": 0, "x": x, "y": y},
            {"type": "pointerDown", "button": 0},
            {"type": "pause", "duration": int(p.get("hold", 60))},
            {"type": "pointerUp", "button": 0}]))
    if kind == "swipe":
        return wda("POST", f"/session/{sid}/actions", pointer([
            {"type": "pointerMove", "duration": 0, "x": round(p["x1"]), "y": round(p["y1"])},
            {"type": "pointerDown", "button": 0},
            {"type": "pause", "duration": 30},
            {"type": "pointerMove", "duration": int(p.get("ms", 250)),
             "x": round(p["x2"]), "y": round(p["y2"])},
            {"type": "pointerUp", "button": 0}]))
    if kind == "switcher":
        # A swipe made of W3C pointer actions does not start the system gesture.
        # One XCTest press, drag and hold from the bottom edge does (tested).
        w, h = state["size"]["width"], state["size"]["height"]
        return wda("POST", f"/session/{sid}/wda/pressAndDragWithVelocity", {
            "fromX": w / 2, "fromY": h - 1, "toX": w / 2, "toY": round(h * 0.61),
            "pressDuration": 0.05, "holdDuration": 0.8, "velocity": 600})
    if kind == "wake":
        return wda("POST", "/wda/unlock", {})
    if kind == "home":
        return wda("POST", "/wda/homescreen", {})
    if kind == "type":
        return wda("POST", f"/session/{sid}/wda/keys", {"value": list(p["text"])})
    raise ValueError(kind)


# The page lives next to this file. It is read on each request, so edits show on reload.
PAGE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "phone_remote.html")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def allowed(self):
        """Reject DNS rebinding, other websites, and requests without the token."""
        host = self.headers.get("Host") or ""
        if host.rsplit(":", 1)[0] not in ("127.0.0.1", "localhost"):
            return False
        if self.command == "POST":
            origin = self.headers.get("Origin")
            if origin is not None and origin != f"http://{host}":
                return False
        # The page sends the token in a custom header. A cross-site request with a
        # custom header needs a CORS preflight, and this server never grants one.
        # The page itself holds no secret, so it loads without the token. It reads
        # the token from the URL fragment, which the browser never sends to a server.
        if self.command == "GET" and urlparse(self.path).path == "/":
            return True
        token = self.headers.get("X-Tapstream") or parse_qs(urlparse(self.path).query).get("token", [""])[0]
        return hmac.compare_digest(token, TOKEN)

    def reply(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.allowed():
            return self.reply(403, "forbidden", "text/plain")
        path = urlparse(self.path).path
        if path == "/":
            with open(PAGE_FILE) as f:
                page = f.read()
            screen = '<canvas id="screen"></canvas>' if VIDEO else '<img id="screen" draggable="false" alt="">'
            page = page.replace("__FRAMES__", FRAMES).replace("__VIDEO__", VIDEO).replace("__SCREEN__", screen)
            return self.reply(200, page, "text/html; charset=utf-8")
        if path == "/screenshot":
            try:
                png = base64.b64decode(wda("GET", "/screenshot")["value"])
            except Exception as e:
                return self.reply(502, str(e), "text/plain")
            name = time.strftime("iphone-%Y%m%d-%H%M%S.png")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(png)))
            self.send_header("Content-Disposition", f'attachment; filename="{name}"')
            self.end_headers()
            self.wfile.write(png)
            return
        if path == "/info":
            try:
                session()
                return self.reply(200, json.dumps(state["size"]))
            except Exception as e:
                return self.reply(502, str(e), "text/plain")
        self.reply(404, "not found", "text/plain")

    def do_POST(self):
        if not self.allowed():
            return self.reply(403, "forbidden", "text/plain")
        kind = urlparse(self.path).path.strip("/")
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        try:
            act(kind, body)
            self.reply(200, "{}")
        except Exception as e:
            self.reply(502, str(e), "text/plain")


if __name__ == "__main__":
    if not TOKEN:
        sys.exit("error: set PHONE_REMOTE_TOKEN. phone-remote does this for you.")
    print(f"iPhone remote on http://127.0.0.1:{PORT}/")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
