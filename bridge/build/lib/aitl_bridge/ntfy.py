"""ntfy forwarding: every alert the device gets can also go to your phone/laptop via ntfy (self-hosted or ntfy.sh).

Permission cards carry Allow / Deny buttons. Those buttons hit a tiny "remote" HTTP server that the bridge binds to
your Tailscale IP only (never 0.0.0.0), with a per-install secret in the URL, so answering from a phone on the tailnet
works and nothing on the open internet can resolve a prompt.
"""
from __future__ import annotations
import asyncio
import json
import logging
import secrets as _secrets
import urllib.request
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlsplit

from .config import CONFIG_DIR
from .security import tailscale_ip, _local_ips

log = logging.getLogger("aitl.ntfy")
SECRET_FILE = CONFIG_DIR / "remote_secret"


def remote_secret() -> str:
    try:
        if SECRET_FILE.exists():
            return SECRET_FILE.read_text().strip()
        s = _secrets.token_urlsafe(24)
        SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
        SECRET_FILE.write_text(s); SECRET_FILE.chmod(0o600)
        return s
    except Exception:  # noqa: BLE001
        return _secrets.token_urlsafe(24)


def _hdr(v: str) -> str:
    """HTTP headers are Latin-1; ntfy accepts RFC 2047 for anything else (the bullet in our titles, emoji in app names)."""
    try:
        v.encode("latin-1"); return v
    except UnicodeEncodeError:
        import base64
        return "=?UTF-8?B?" + base64.b64encode(v.encode("utf-8")).decode("ascii") + "?="


class Ntfy:
    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg
        self.url = str(cfg.get("url", "https://ntfy.sh")).rstrip("/")
        self.topic = str(cfg.get("topic", "")).strip()
        self.events = set(cfg.get("events") or ["permission", "notify", "done"])
        self.action_base = ""                       # set by RemoteServer once it knows its bind address
        self.action_base_secret = ""
        from . import secrets as sec
        self.token = sec.get("ntfy") or ""

    @property
    def enabled(self) -> bool:
        return bool(self.topic)

    def wants(self, kind: str) -> bool:
        return self.enabled and kind in self.events

    async def send(self, title: str, text: str, *, kind: str = "notify", alert_id: str = "", tags: str = "") -> bool:
        if not self.enabled:
            return False
        headers = {"Title": _hdr(title[:120]), "Priority": "high" if kind == "permission" else "default",
                   "Tags": tags or {"permission": "question", "done": "white_check_mark", "notify": "speech_balloon", "notice": "bell"}.get(kind, "robot")}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if kind == "permission" and alert_id and self.action_base:
            headers["Actions"] = (f"http, Allow, {self.action_base}/act?id={alert_id}&a=allow&k={self.action_base_secret}, clear=true; "
                                  f"http, Deny, {self.action_base}/act?id={alert_id}&a=deny&k={self.action_base_secret}, clear=true")
        req = urllib.request.Request(f"{self.url}/{self.topic}", data=text.encode("utf-8")[:4000], headers=headers, method="POST")
        def _post() -> bool:
            with urllib.request.urlopen(req, timeout=8) as r:
                return 200 <= r.status < 300
        try:
            return await asyncio.to_thread(_post)
        except Exception as e:  # noqa: BLE001
            log.warning("ntfy: %s", e)
            return False


class RemoteServer:
    """GET/POST /act?id=<alert>&a=allow|deny&k=<secret> -> resolves a pending permission. Tailscale-only by default."""
    def __init__(self, reply: Callable[[str, str], bool], cfg: dict[str, Any], ntfy: Ntfy):
        self.reply, self.cfg, self.ntfy = reply, cfg, ntfy
        self.port = int(cfg.get("remote_port", 7779))
        self.secret = remote_secret()
        self.bind = ""
        self.on_reply: Callable[[str, str], Any] | None = None

    def resolve_bind(self) -> str:
        want = str(self.cfg.get("remote_bind", "tailscale"))
        if want == "tailscale":
            return tailscale_ip()
        if want == "lan":
            return (_local_ips() or [""])[0]
        return want                                   # explicit IP

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            req = await asyncio.wait_for(reader.readline(), 5)
            method, path, *_ = req.decode("latin1").split(" ") + ["", ""]
            while True:
                h = await asyncio.wait_for(reader.readline(), 5)
                if h in (b"\r\n", b"\n", b""):
                    break
            u = urlsplit(path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
            body, status = "AITL remote: nothing here.", 404
            if u.path == "/act":
                if not _secrets.compare_digest(q.get("k", ""), self.secret):
                    body, status = "forbidden", 403
                else:
                    aid, a = q.get("id", ""), q.get("a", "")
                    if a in ("allow", "deny") and self.reply(aid, a):
                        body, status = f"{'Allowed' if a == 'allow' else 'Denied'} ✓ (alert {aid})", 200
                        if self.on_reply:
                            await self.on_reply(aid, a)
                    else:
                        body, status = "That prompt already expired or was answered.", 410
            out = f"<!doctype html><meta name=viewport content='width=device-width'><body style='font:20px -apple-system;padding:2em;background:#07111a;color:#e6edf3'>{body}</body>".encode()
            writer.write(b"HTTP/1.1 %d OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % (status, len(out)) + out)
            await writer.drain()
        except Exception as e:  # noqa: BLE001
            log.debug("remote request failed: %s", e)
        finally:
            writer.close()

    async def run(self) -> None:
        self.bind = self.resolve_bind()
        if not self.bind:
            log.info("remote actions: no Tailscale IP (install/start Tailscale, or set [ntfy] remote_bind = \"lan\"); ntfy cards will have no buttons")
            return
        self.ntfy.action_base = f"http://{self.bind}:{self.port}"
        # the secret rides along as a query parameter on every action URL
        self.ntfy.action_base_secret = self.secret
        srv = await asyncio.start_server(self._handle, self.bind, self.port)
        log.info("remote actions: listening on %s:%d (Allow/Deny from ntfy)", self.bind, self.port)
        async with srv:
            await srv.serve_forever()
