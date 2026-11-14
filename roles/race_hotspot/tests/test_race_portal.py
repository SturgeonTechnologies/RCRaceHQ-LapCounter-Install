"""Tests for files/race-portal.

Run from the repo root:
    python3 -m pytest roles/race_hotspot/tests -q
"""

import importlib.machinery
import importlib.util
import pathlib
import subprocess
import sys
import threading
import urllib.request
import socket
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "files" / "race-portal"


def _load():
    loader = importlib.machinery.SourceFileLoader("race_portal", str(SCRIPT))
    spec = importlib.util.spec_from_loader("race_portal", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules["race_portal"] = module  # dataclasses look the module up
    loader.exec_module(module)
    return module


portal = _load()
CFG = portal.Config.from_env({})


# ── config ───────────────────────────────────────────────────────────────

def test_defaults():
    assert CFG.portal_url == "http://race/"
    assert CFG.hostnames == {"race", "race.lan", "10.77.0.1"}
    assert str(CFG.network) == "10.77.0.0/24"


def test_env_overrides():
    cfg = portal.Config.from_env({"PORTAL_GATEWAY": "10.9.0.1", "PORTAL_PREFIX": "16",
                                  "PORTAL_HOSTNAME": "Track", "PORTAL_DOMAIN": "club"})
    assert cfg.portal_url == "http://track/"
    assert "track.club" in cfg.hostnames
    assert str(cfg.network) == "10.9.0.0/16"


# ── host matching ────────────────────────────────────────────────────────

@pytest.mark.parametrize("header,expected", [
    ("race", "race"), ("RACE:80", "race"), ("race.lan.", "race.lan"),
    ("10.77.0.1:80", "10.77.0.1"), ("", ""), (None, ""),
])
def test_request_host(header, expected):
    assert portal.request_host(header) == expected


@pytest.mark.parametrize("header,expected", [
    ("race", "portal"), ("race.lan", "portal"), ("10.77.0.1", "portal"),
    ("captive.apple.com", "redirect"), ("connectivitycheck.gstatic.com", "redirect"),
    ("www.msftconnecttest.com", "redirect"), ("racetrack.com", "redirect"), (None, "redirect"),
])
def test_decide(header, expected):
    assert portal.decide(CFG, header) == expected
    assert portal.decide(CFG, header, "10.77.0.50") == expected


@pytest.mark.parametrize("client", ["192.168.0.20", "127.0.0.1", "::1", "garbage"])
def test_decide_off_hotspot_is_wired_whatever_the_host(client):
    for header in ("race", "racedecoder.local", "192.168.0.40", None):
        assert portal.decide(CFG, header, client) == "wired"


# ── who may be let through ───────────────────────────────────────────────

@pytest.mark.parametrize("client,ok", [
    ("10.77.0.50", True), ("10.77.0.254", True),
    ("10.77.0.1", False),       # the Pi itself
    ("10.77.0.0", False), ("10.77.0.255", False),
    ("192.168.0.20", False),    # uplink-side LAN
    ("::1", False), ("garbage", False),
])
def test_client_to_allow(client, ok):
    assert (portal.client_to_allow(CFG, client) is not None) == ok


def test_nft_command_is_an_argv_list():
    addr = portal.client_to_allow(CFG, "10.77.0.50")
    assert portal.nft_add_command(CFG, addr) == [
        "nft", "add", "element", "inet", "race_portal", "allowed",
        "{ 10.77.0.50 timeout 12h }"]


def test_grant_runs_nft():
    calls = []

    def fake_run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "", "")

    assert portal.grant_access(CFG, "10.77.0.60", run=fake_run)
    assert calls[0][-1] == "{ 10.77.0.60 timeout 12h }"


def test_grant_refuses_outsiders_without_running_nft():
    def fail_run(*_a, **_k):
        raise AssertionError("nft must not run")

    assert not portal.grant_access(CFG, "192.168.0.20", run=fail_run)


def test_grant_reports_nft_failure():
    def bad_run(argv, **kwargs):
        return subprocess.CompletedProcess(argv, 1, "", "No such file or directory")

    assert not portal.grant_access(CFG, "10.77.0.60", run=bad_run)


def test_landing_page_escapes_title():
    cfg = portal.Config.from_env({"PORTAL_TITLE": "<b>Club</b>"})
    body = portal.landing_page(cfg, "online").decode()
    assert "&lt;b&gt;Club&lt;/b&gt;" in body and "<b>Club" not in body


@pytest.mark.parametrize("status,text", [
    ("online", "Internet access is on"), ("offline", "couldn't be turned on"),
    ("wired", "on the track network"),
])
def test_landing_page_status(status, text):
    assert text in portal.landing_page(CFG, status).decode()


# ── HTTP behaviour end to end (loopback, nft stubbed out) ────────────────

# The test client is always 127.0.0.1. HOTSPOT_CFG puts that on the hotspot
# subnet; the default CFG makes it a wired (eth0-side) client.
HOTSPOT_CFG = portal.Config.from_env({"PORTAL_GATEWAY": "127.0.0.1", "PORTAL_PREFIX": "8"})


def _serve(monkeypatch, cfg):
    granted = []
    monkeypatch.setattr(portal, "grant_access", lambda cfg, client: granted.append(client) or True)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), portal.make_handler(cfg))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, granted


@pytest.fixture()
def server(monkeypatch):
    srv, granted = _serve(monkeypatch, HOTSPOT_CFG)
    yield srv.server_address[1], granted
    srv.shutdown()


@pytest.fixture()
def wired_server(monkeypatch):
    srv, granted = _serve(monkeypatch, CFG)
    yield srv.server_address[1], granted
    srv.shutdown()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _get(port, host, method="GET", data=None):
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(f"http://127.0.0.1:{port}/hotspot-detect.html",
                                 headers={"Host": host}, method=method, data=data)
    try:
        resp = opener.open(req, timeout=5)
    except urllib.error.HTTPError as err:
        resp = err
    return resp.status, resp.headers, resp.read()


def test_probe_is_redirected_to_portal(server):
    port, granted = server
    status, headers, _ = _get(port, "captive.apple.com")
    assert status == 302 and headers["Location"] == "http://race/"
    assert headers["Cache-Control"] == "no-store"
    assert granted == []


def test_visiting_race_grants_and_serves_page(server):
    port, granted = server
    status, headers, body = _get(port, "race")
    assert status == 200 and b"You're connected" in body
    assert headers["Content-Type"].startswith("text/html")
    assert granted == ["127.0.0.1"]


def test_head_has_no_body(server):
    port, _ = server
    status, _, body = _get(port, "race", method="HEAD")
    assert status == 200 and body == b""


def test_wired_client_gets_page_without_redirect_or_grant(wired_server):
    port, granted = wired_server
    for host in ("racedecoder.local", "192.168.0.40", "captive.apple.com"):
        status, _, body = _get(port, host)
        assert status == 200 and b"on the track network" in body
    assert granted == []


# ── serving the app (reverse proxy on :80) ──────────────────────────────

class _FakeApp(BaseHTTPRequestHandler):
    """Stands in for the lap counter app: echoes what it received."""
    seen: list = []

    def _reply(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        type(self).seen.append({"method": self.command, "path": self.path,
                                "headers": dict(self.headers), "body": body})
        if self.path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for i in range(3):
                self.wfile.write(f"data: {i}\n\n".encode())
                self.wfile.flush()
            return
        if self.path == "/go":
            self.send_response(302)
            self.send_header("Location", "/kiosk")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        out = f"app {self.command} {self.path}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Set-Cookie", "a=1")
        self.send_header("Set-Cookie", "b=2")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(out)

    do_GET = do_HEAD = do_POST = _reply

    def log_message(self, *args):
        pass


@pytest.fixture()
def app_server():
    _FakeApp.seen = []
    srv = ThreadingHTTPServer(("127.0.0.1", 0), _FakeApp)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv.server_address[1]
    srv.shutdown()


def _portal_with_app(monkeypatch, app_port, env):
    cfg = portal.Config.from_env({**env, "PORTAL_APP_PORT": str(app_port)})
    return _serve(monkeypatch, cfg)


HOTSPOT_ENV = {"PORTAL_GATEWAY": "127.0.0.1", "PORTAL_PREFIX": "8"}


def _req(port, host, path="/", method="GET", data=None, headers=None):
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}",
                                 headers={"Host": host, **(headers or {})},
                                 method=method, data=data)
    try:
        resp = opener.open(req, timeout=5)
    except urllib.error.HTTPError as err:
        resp = err
    return resp.status, resp.headers, resp.read()


def test_race_serves_the_app_on_port_80(monkeypatch, app_server):
    srv, granted = _portal_with_app(monkeypatch, app_server, HOTSPOT_ENV)
    try:
        status, headers, body = _req(srv.server_address[1], "race", "/checkin?x=1")
        assert status == 200 and body == b"app GET /checkin?x=1"
        assert headers.get_all("Set-Cookie") == ["a=1", "b=2"]
        assert granted == ["127.0.0.1"]
        seen = _FakeApp.seen[-1]["headers"]
        assert seen["Host"] == "race" and seen["X-Forwarded-For"] == "127.0.0.1"
    finally:
        srv.shutdown()


def test_probes_still_go_to_portal_not_app(monkeypatch, app_server):
    srv, granted = _portal_with_app(monkeypatch, app_server, HOTSPOT_ENV)
    try:
        status, headers, _ = _req(srv.server_address[1], "captive.apple.com", "/hotspot-detect.html")
        assert status == 302 and headers["Location"] == "http://race/"
        status, headers, _ = _req(srv.server_address[1], "captive.apple.com", "/x",
                                  method="POST", data=b"a=1")
        assert status == 303 and headers["Location"] == "http://race/"
        assert _FakeApp.seen == [] and granted == []
    finally:
        srv.shutdown()


def test_client_cannot_choose_the_forwarded_address(monkeypatch, app_server):
    srv, _ = _portal_with_app(monkeypatch, app_server, HOTSPOT_ENV)
    try:
        _req(srv.server_address[1], "race", headers={"X-Forwarded-For": "6.6.6.6",
                                                     "X-Real-IP": "6.6.6.6"})
        seen = _FakeApp.seen[-1]["headers"]
        assert seen["X-Forwarded-For"] == "127.0.0.1" and "X-Real-IP" not in seen
    finally:
        srv.shutdown()


def test_post_body_and_app_redirects_pass_through(monkeypatch, app_server):
    srv, _ = _portal_with_app(monkeypatch, app_server, HOTSPOT_ENV)
    try:
        status, _, body = _req(srv.server_address[1], "race", "/checkin", method="POST",
                               data=b"phone=5551234567")
        assert status == 200 and body == b"app POST /checkin"
        assert _FakeApp.seen[-1]["body"] == b"phone=5551234567"
        status, headers, _ = _req(srv.server_address[1], "race", "/go")
        assert status == 302 and headers["Location"] == "/kiosk"
    finally:
        srv.shutdown()


def test_live_stream_is_passed_through(monkeypatch, app_server):
    srv, _ = _portal_with_app(monkeypatch, app_server, HOTSPOT_ENV)
    try:
        status, headers, body = _req(srv.server_address[1], "race", "/stream")
        assert status == 200 and headers["Content-Type"] == "text/event-stream"
        assert body == b"data: 0\n\ndata: 1\n\ndata: 2\n\n"
    finally:
        srv.shutdown()


def test_head_through_proxy_has_no_body(monkeypatch, app_server):
    srv, _ = _portal_with_app(monkeypatch, app_server, HOTSPOT_ENV)
    try:
        status, _, body = _req(srv.server_address[1], "race", method="HEAD")
        assert status == 200 and body == b""
    finally:
        srv.shutdown()


def test_wired_client_gets_app_without_grant(monkeypatch, app_server):
    srv, granted = _portal_with_app(monkeypatch, app_server, {})
    try:
        for host in ("racedecoder.local", "192.168.0.40:80"):
            status, _, body = _req(srv.server_address[1], host, "/kiosk")
            assert status == 200 and body == b"app GET /kiosk"
        assert granted == []
    finally:
        srv.shutdown()


def test_oversized_body_is_refused(monkeypatch, app_server):
    srv, _ = _portal_with_app(monkeypatch, app_server, HOTSPOT_ENV)
    try:
        # Raw socket: the portal answers 413 from the headers alone, without
        # reading (or forwarding) the body.
        with socket.create_connection(srv.server_address, timeout=5) as sock:
            sock.sendall(b"POST / HTTP/1.1\r\nHost: race\r\nContent-Length: "
                         + str(portal.MAX_BODY + 1).encode() + b"\r\n\r\n")
            reply = sock.recv(64)
        assert reply.startswith(b"HTTP/1.0 413") and _FakeApp.seen == []
    finally:
        srv.shutdown()


def test_app_down_falls_back_to_page(monkeypatch):
    free = socket.socket()
    free.bind(("127.0.0.1", 0))
    port = free.getsockname()[1]
    free.close()
    srv, _ = _portal_with_app(monkeypatch, port, {})
    try:
        status, _, body = _req(srv.server_address[1], "racedecoder.local")
        assert status == 200 and b"isn't running yet" in body
    finally:
        srv.shutdown()


def test_no_app_port_serves_page(wired_server):
    port, _ = wired_server
    status, _, body = _req(port, "racedecoder.local", method="POST", data=b"x=1")
    assert status == 200 and b"on the track network" in body


def test_grant_cache_limits_nft_runs():
    now = [1000.0]
    cache = portal.GrantCache(refresh=600, clock=lambda: now[0])
    assert not cache.fresh("10.77.0.5")
    cache.mark("10.77.0.5")
    assert cache.fresh("10.77.0.5")
    now[0] += 601
    assert not cache.fresh("10.77.0.5")


def test_one_grant_for_many_requests(monkeypatch, app_server):
    calls = []
    cfg = portal.Config.from_env({**HOTSPOT_ENV, "PORTAL_APP_PORT": str(app_server)})
    monkeypatch.setattr(portal, "grant_access", lambda cfg, client: calls.append(client) or True)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), portal.make_handler(cfg))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        for path in ("/", "/static/live.js", "/checkin"):
            _req(srv.server_address[1], "race", path)
        assert calls == ["127.0.0.1"]
    finally:
        srv.shutdown()
