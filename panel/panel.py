#!/usr/bin/env python3
"""
Nash Tunnel Panel — single-file web panel (stdlib only).

Serves:
  GET  /                 dashboard (web/index.html)
  GET  /api/status       live system + tunnel status
  GET  /api/nodes        node list with health
  GET  /api/logs?unit=   last lines of a systemd unit
  POST /api/login        {"password": "..."} -> session cookie
  POST /api/action       {"action": "restart-frp"} etc.

Config: /etc/nash/config.json  (override with NASH_CONFIG)
State : /etc/nash/panel.json   (password hash, sessions)
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "1.0.0"
BASE = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.environ.get("NASH_CONFIG", "/etc/nash/config.json"))
STATE_PATH = Path(os.environ.get("NASH_STATE", "/etc/nash/panel.json"))
SESSION_TTL = 12 * 3600


def web_root():
    """Locate the web/ directory for both layouts:
    /opt/nash-panel/panel.py + /opt/nash-panel/web/  and  repo/panel/panel.py + repo/web/."""
    for cand in (BASE / "web", BASE.parent / "web"):
        if (cand / "index.html").exists():
            return cand
    return BASE / "web"

DEFAULTS = {
    "listen": "0.0.0.0",
    "port": 8090,
    "title": "Nash Tunnel",
    "role": "iran",              # iran | foreign
    "gre_iface": "gre-tunnel",
    "frp_service": "nash-frpc",
    "xray_service": "nash-xray",
    "panel_service": "nash-panel",
    "watchdog_service": "nash-watchdog",
    "telegram": {"token": "", "chat_id": ""},
    "nodes": [],
}

# ---------------------------------------------------------------- state / auth

def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(default, dict):
            merged = dict(default)
            merged.update(data if isinstance(data, dict) else {})
            return merged
        return data
    except Exception:
        return default if not isinstance(default, dict) else dict(default)


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def cfg():
    return load_json(CONFIG_PATH, DEFAULTS)


def state():
    st = load_json(STATE_PATH, {"password_hash": "", "salt": "", "sessions": {}})
    if not st.get("password_hash"):
        pw = os.environ.get("NASH_PASSWORD") or secrets.token_urlsafe(9)
        set_password(st, pw)
        save_json(STATE_PATH, st)
        print(f"[panel] initial password: {pw}", flush=True)
    return st


def hash_password(password, salt):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 120_000).hex()


def set_password(st, password):
    salt = secrets.token_hex(16)
    st["salt"] = salt
    st["password_hash"] = hash_password(password, salt)
    st["sessions"] = {}


def check_password(st, password):
    if not st.get("password_hash"):
        return False
    return hmac.compare_digest(hash_password(password, st["salt"]), st["password_hash"])


# ---------------------------------------------------------------- helpers

def run(cmd, timeout=8):
    """Run a shell command, return (rc, stdout+stderr stripped)."""
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True,
                           text=True, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
        return p.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)


def unit_active(name):
    rc, out = run(["systemctl", "is-active", name])
    return out.splitlines()[0].strip() if out else "unknown"


def unit_restarts(name):
    rc, out = run(["systemctl", "show", name, "-p", "NRestarts", "--value"])
    try:
        return int(out.strip() or 0)
    except ValueError:
        return 0


def iface_up(iface):
    try:
        return Path(f"/sys/class/net/{iface}/operstate").read_text().strip() == "up"
    except Exception:
        return False


def read_first(path):
    try:
        return Path(path).read_text().strip()
    except Exception:
        return ""


def cpu_percent():
    def snap():
        parts = read_first("/proc/stat").split()
        vals = [int(x) for x in parts[1:8]]
        return sum(vals), vals[3] + (vals[4] if len(vals) > 4 else 0)
    try:
        t1, i1 = snap()
        time.sleep(0.25)
        t2, i2 = snap()
        dt, di = t2 - t1, i2 - i1
        return round(100.0 * (dt - di) / dt, 1) if dt > 0 else 0.0
    except Exception:
        return 0.0


def mem_info():
    info = {}
    for line in read_first("/proc/meminfo").splitlines():
        key, _, rest = line.partition(":")
        info[key] = int(rest.strip().split()[0]) if rest.strip() else 0
    total = info.get("MemTotal", 0) // 1024
    avail = info.get("MemAvailable", 0) // 1024
    used = total - avail
    pct = round(100.0 * used / total, 1) if total else 0.0
    return {"total_mb": total, "used_mb": used, "percent": pct}


def disk_info():
    try:
        du = shutil.disk_usage("/")
        return {"total_gb": round(du.total / 2**30, 1),
                "used_gb": round(du.used / 2**30, 1),
                "percent": round(100.0 * du.used / du.total, 1)}
    except Exception:
        return {"total_gb": 0, "used_gb": 0, "percent": 0}


def uptime_text():
    try:
        secs = float(read_first("/proc/uptime").split()[0])
    except Exception:
        return "-"
    d, rem = divmod(int(secs), 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d {h}h {m}m"
    if h:
        return f"{h}h {m}m"
    return f"{m}m"


def tcp_check(host, port, timeout=3.0):
    started = time.time()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True, round((time.time() - started) * 1000)
    except Exception:
        return False, None


def ping_check(host, count=3, timeout=6):
    rc, out = run(["ping", "-c", str(count), "-W", "2", host], timeout=timeout + 4)
    if rc != 0:
        return {"ok": False, "avg_ms": None, "loss": 100}
    m = re.search(r"(\d+)% packet loss", out)
    loss = int(m.group(1)) if m else 100
    m = re.search(r"rtt min/avg/max/mdev = [\d.]+/([\d.]+)/", out)
    avg = round(float(m.group(1)), 1) if m else None
    return {"ok": loss < 100, "avg_ms": avg, "loss": loss}


def node_health(node):
    """node: {name, host, port, ping}"""
    result = {"name": node.get("name") or node.get("host"), "host": node.get("host"),
              "port": node.get("port"), "ok": False, "latency_ms": None, "loss": None}
    host = node.get("host")
    if not host:
        return result
    if node.get("port"):
        ok, ms = tcp_check(host, node["port"])
        result["ok"] = ok
        result["latency_ms"] = ms
        return result
    p = ping_check(host)
    result["ok"] = p["ok"]
    result["latency_ms"] = p["avg_ms"]
    result["loss"] = p["loss"]
    return result


def tail_unit(name, lines=60):
    rc, out = run(["journalctl", "-u", name, "-n", str(lines), "--no-pager", "-o", "short-iso"],
                  timeout=10)
    if rc != 0 or not out:
        rc2, out2 = run(["systemctl", "status", name, "--no-pager", "-n", str(lines)], timeout=10)
        return out2 or out or "no logs"
    return out


ACTIONS = {
    "restart-frp": ["systemctl", "restart", "{frp_service}"],
    "restart-xray": ["systemctl", "restart", "{xray_service}"],
    "restart-panel": ["systemctl", "restart", "{panel_service}"],
    "restart-gre": ["systemctl", "restart", "nash-gre"],
    "start-watchdog": ["systemctl", "start", "nash-watchdog.timer"],
    "stop-watchdog": ["systemctl", "stop", "nash-watchdog.timer"],
    "gre-up": ["systemctl", "start", "nash-gre"],
    "gre-down": ["systemctl", "stop", "nash-gre"],
}


# ---------------------------------------------------------------- HTTP layer

class Handler(BaseHTTPRequestHandler):
    server_version = f"NashPanel/{VERSION}"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter logs
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -- utils
    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False)
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(raw)
        except BrokenPipeError:
            pass

    def _json_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            return json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            return {}

    def _session_token(self):
        cookie = self.headers.get("Cookie") or ""
        for part in cookie.split(";"):
            k, _, v = part.strip().partition("=")
            if k == "nash_session":
                return v
        auth = self.headers.get("Authorization") or ""
        if auth.startswith("Bearer "):
            return auth[7:].strip()
        return ""

    def _authed(self):
        st = state()
        tok = self._session_token()
        sess = (st.get("sessions") or {}).get(tok)
        if not sess:
            return False
        if time.time() > float(sess.get("exp", 0)):
            st["sessions"].pop(tok, None)
            save_json(STATE_PATH, st)
            return False
        return True

    # -- routes
    def do_GET(self):  # noqa: N802
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            index = web_root() / "index.html"
            if index.exists():
                return self._send(200, index.read_text(encoding="utf-8"),
                                  "text/html; charset=utf-8")
            return self._send(500, {"error": "web/index.html missing"})
        if path == "/api/health":
            return self._send(200, {"ok": True, "version": VERSION})
        if path == "/api/status":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, build_status())
        if path == "/api/nodes":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            c = cfg()
            return self._send(200, {"nodes": [node_health(n) for n in c.get("nodes", [])]})
        if path == "/api/logs":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            unit = (self.path.split("unit=")[1].split("&")[0] if "unit=" in self.path else "")
            allowed = {"nash-panel", "nash-frpc", "nash-frps", "nash-xray", "nash-gre",
                       "nash-watchdog", "nash-watchdog.timer"}
            if unit not in allowed:
                return self._send(400, {"error": "unit not allowed"})
            return self._send(200, {"unit": unit, "log": tail_unit(unit)})
        return self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?")[0]
        if path == "/api/login":
            body = self._json_body()
            st = state()
            if not check_password(st, str(body.get("password", ""))):
                time.sleep(0.6)
                return self._send(401, {"error": "wrong password"})
            tok = secrets.token_urlsafe(32)
            st.setdefault("sessions", {})[tok] = {"exp": time.time() + SESSION_TTL,
                                                  "ip": self.client_address[0]}
            save_json(STATE_PATH, st)
            cookie = f"nash_session={tok}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}"
            return self._send(200, {"ok": True}, extra={"Set-Cookie": cookie})
        if path == "/api/logout":
            st = state()
            st.get("sessions", {}).pop(self._session_token(), None)
            save_json(STATE_PATH, st)
            return self._send(200, {"ok": True},
                              extra={"Set-Cookie": "nash_session=; Path=/; Max-Age=0"})
        if path == "/api/action":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            body = self._json_body()
            action = str(body.get("action", ""))
            template = ACTIONS.get(action)
            if not template:
                return self._send(400, {"error": "unknown action"})
            c = cfg()
            cmd = [part.format(**c) for part in template]
            rc, out = run(cmd, timeout=25)
            return self._send(200 if rc == 0 else 500,
                              {"ok": rc == 0, "rc": rc, "out": out[-800:]})
        if path == "/api/password":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            body = self._json_body()
            new = str(body.get("password", ""))
            if len(new) < 8:
                return self._send(400, {"error": "min 8 chars"})
            st = state()
            set_password(st, new)
            save_json(STATE_PATH, st)
            return self._send(200, {"ok": True, "note": "re-login required"})
        return self._send(404, {"error": "not found"})


def build_status():
    c = cfg()
    iface = c.get("gre_iface", "gre-tunnel")
    nodes = [node_health(n) for n in c.get("nodes", [])]
    healthy = sum(1 for n in nodes if n["ok"])
    return {
        "version": VERSION,
        "role": c.get("role"),
        "hostname": socket.gethostname(),
        "uptime": uptime_text(),
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "cpu": cpu_percent(),
        "mem": mem_info(),
        "disk": disk_info(),
        "gre": {"iface": iface, "up": iface_up(iface)},
        "units": {
            "panel": unit_active(c.get("panel_service", "nash-panel")),
            "frp": unit_active(c.get("frp_service", "nash-frpc")),
            "xray": unit_active(c.get("xray_service", "nash-xray")),
            "watchdog": unit_active("nash-watchdog.timer"),
        },
        "restarts": {
            "frp": unit_restarts(c.get("frp_service", "nash-frpc")),
            "xray": unit_restarts(c.get("xray_service", "nash-xray")),
        },
        "nodes": {"total": len(nodes), "healthy": healthy, "items": nodes},
    }


def main():
    c = cfg()
    host = c.get("listen", "0.0.0.0")
    port = int(c.get("port", 8090))
    state()  # ensure password exists
    httpd = ThreadingHTTPServer((host, port), Handler)
    httpd.daemon_threads = True
    print(f"[panel] {c.get('title', 'Nash Tunnel')} v{VERSION} on http://{host}:{port}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
