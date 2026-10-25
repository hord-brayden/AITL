"""One DeviceSession per connected device (serial or Wi-Fi). Handles the NDJSON protocol, streams chats,
and performs Mac actions. Transport-agnostic: a transport just supplies send() and feeds inbound frames."""
from __future__ import annotations
import asyncio
import logging
import time
from typing import Any, Awaitable, Callable

from . import __version__, config, mac, protocol, audio, stt
import secrets
from .chat_store import ChatStore, Chat
from .providers import ProviderError
from .router import Router
from .security import Registry, RateLimiter, cert_pem, cert_fingerprint, new_token, pairing_code

log = logging.getLogger("aitl.session")
SendFn = Callable[[dict[str, Any]], Awaitable[None]]


class Pairing:
    """Bridge-wide pairing window (Wi-Fi TOFU). Opened by `aitl serve --allow-pairing` or `aitl pair`."""
    def __init__(self):
        self.open_until = 0.0
        self.offers: dict[str, dict[str, Any]] = {}   # device id -> {code, token, name}

    def is_open(self) -> bool:
        return time.time() < self.open_until

    def open(self, seconds: int = 180) -> None:
        self.open_until = time.time() + seconds


class Shared:
    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg
        self.router = Router(cfg)
        self.chats = ChatStore()
        self.registry = Registry()
        self.pairing = Pairing()
        self.hid_limiter = RateLimiter(rate=4, burst=12)
        self.pair_limiter = RateLimiter(rate=0.05, burst=3)
        self.bridge_name = config.bridge_name(cfg)
        self.dict_state: dict[str, Any] = {"dictating": False}
        self.hid_notified = False
        self.device_settings: dict[str, dict[str, Any]] = {}
        self.device_networks: dict[str, dict[str, Any]] = {}
        self.device_scan: dict[str, list] = {}
        self.device_diag: dict[str, dict[str, Any]] = {}
        self.ntfy = None
        self.remote = None
        self.remote_task = None
        self.session_state: dict[str, dict[str, Any]] = {}     # Claude Code session id -> {state, at, project, note}
        self.usage_today: dict[str, Any] = {"day": time.strftime("%Y-%m-%d"), "turns": 0, "in": 0, "out": 0, "cost": 0.0}
        self.sessions: set["DeviceSession"] = set()
        self.hooks = None          # HookServer, attached by the CLI when serving
        self.pending_settings: dict[str, asyncio.Future] = {}

    def note_usage(self, usage: dict[str, Any] | None, cost: float | None) -> dict[str, Any]:
        day = time.strftime("%Y-%m-%d")
        if self.usage_today.get("day") != day:
            self.usage_today = {"day": day, "turns": 0, "in": 0, "out": 0, "cost": 0.0}
        u = {"in": int((usage or {}).get("input_tokens") or (usage or {}).get("in") or 0), "out": int((usage or {}).get("output_tokens") or (usage or {}).get("out") or 0), "cost": float(cost or 0)}
        self.usage_today["turns"] += 1; self.usage_today["in"] += u["in"]; self.usage_today["out"] += u["out"]; self.usage_today["cost"] += u["cost"]
        return u

    def overview(self) -> dict[str, Any]:
        """One frame for the device's overview screen: today's usage, formalized chats, live sessions."""
        from . import claude_sessions
        now = time.time()
        def age(ts: float) -> str:
            d = max(0, now - ts)
            return f"{int(d // 60)}m" if d < 3600 else f"{int(d // 3600)}h" if d < 86400 else f"{int(d // 86400)}d"
        chats = []
        for c in self.chats.list(12):
            ch = self.chats.get(c["id"])
            if not ch:
                continue
            st = ch.ext.get("stats") or {}
            sid = ch.ext.get("claude_code_session", "")
            state = self.session_state.get(sid, {}).get("state", "") if sid else ""
            chats.append({"id": ch.id, "title": (ch.title or "(untitled)")[:36], "model": ch.model.split("/")[-1][:18], "turns": len([m for m in ch.messages if m["role"] == "user"]),
                          "tok": int(st.get("in", 0)) + int(st.get("out", 0)), "cost": round(float(st.get("cost", 0.0)), 3), "age": age(ch.updated),
                          "session": sid[:8], "state": state})
        sessions = []
        for info in claude_sessions.list_sessions(limit=8):
            st = self.session_state.get(info.id, {})
            term = self.hooks.terminals.get(info.id, {}) if self.hooks else {}
            sessions.append({"id": info.id, "title": info.title[:36], "project": info.project[:18], "age": info.age(),
                             "state": st.get("state", ""), "live": bool(term), "app": term.get("app", "")})
        u = self.usage_today
        return {"t": "overview", "today": {"turns": u["turns"], "in": u["in"], "out": u["out"], "cost": round(u["cost"], 3)},
                "chats": chats, "sessions": sessions, "devices": len({x.device_id for x in self.sessions if x.device_id})}

    async def notification_loop(self) -> None:
        from . import notifications
        cfg = self.cfg.get("notifications", {})
        if not cfg.get("enabled", True):
            return
        ok, why = notifications.accessible()
        if not ok:
            log.warning("notifications: %s (relay disabled until granted)", why)
        watcher = notifications.NotificationWatcher(cfg)
        warned = not ok
        while True:
            try:
                if self.sessions:
                    ok, why = notifications.accessible()
                    if ok:
                        for n in watcher.poll():
                            title = f"{n['app']}: {n['title']}" if n["title"] else n["app"]
                            text = " ".join(x for x in (n["subtitle"], n["body"]) if x)[:300]
                            card = {"t": "alert", "id": secrets.token_hex(3), "kind": "modal" if cfg.get("modal") else "notice",
                                    "title": title[:60], "text": text or "(no text)", "project": n["time"], "session": "", "actions": ["OK"]}
                            await self.broadcast(card)
                            if self.ntfy and self.ntfy.wants("notice"):
                                await self.ntfy.send(title[:60], text or "(no text)", kind="notice")
                    elif not warned:
                        warned = True; log.warning("notifications: %s", why)
            except Exception as e:  # noqa: BLE001
                log.debug("notification loop: %s", e)
            await asyncio.sleep(float(cfg.get("poll_seconds", 4)))

    async def now_playing_loop(self) -> None:
        last: dict[str, Any] = {}
        while True:
            try:
                if self.sessions:
                    np = await mac.now_playing()
                    if np != last:
                        last = np
                        await self.broadcast({"t": "np", **np})
            except Exception as e:  # noqa: BLE001
                log.debug("now playing: %s", e)
            await asyncio.sleep(4)

    async def ntfy_apply(self) -> None:
        """(Re)build the ntfy forwarder from config and start/stop the remote Allow/Deny server to match."""
        from .ntfy import Ntfy, RemoteServer
        self.ntfy = Ntfy(self.cfg.get("ntfy", {}))
        if self.hooks:
            self.hooks.ntfy = self.ntfy
        if self.remote_task:
            self.remote_task.cancel(); self.remote_task = None; self.remote = None
        if self.ntfy.enabled:
            self.remote = RemoteServer(self.hooks.reply if self.hooks else (lambda a, b: False), self.cfg.get("ntfy", {}), self.ntfy)
            async def _answered(aid: str, action: str) -> None:
                await self.broadcast({"t": "alert.clear", "id": aid}); log.info("permission %s -> %s (from ntfy)", aid, action)
            self.remote.on_reply = _answered
            self.remote_task = asyncio.create_task(self.remote.run())
            log.info("ntfy: forwarding %s to %s/%s", ", ".join(sorted(self.ntfy.events)), self.ntfy.url, self.ntfy.topic)
        elif not getattr(self, "_ntfy_off_logged", False):
            self._ntfy_off_logged = True
            log.info("ntfy: off (set a topic in the app or config.toml [ntfy])")

    async def admin(self, op: str, data: dict[str, Any]) -> dict[str, Any]:
        """Loopback admin ops from `aitl set` / `aitl status`."""
        if op == "probe":
            return await mac.probe()
        if op == "get":
            fut: asyncio.Future = asyncio.get_running_loop().create_future()
            self.pending_settings["__dump__"] = fut
            n = await self.broadcast({"t": "settings.get"})
            if n == 0:
                return {"ok": False, "error": "no device linked"}
            try:
                await asyncio.wait_for(fut, 5)
            except asyncio.TimeoutError:
                return {"ok": False, "error": "device did not answer"}
            from .security import _local_ips, tailscale_ip, BRIDGE_DNS
            from .notifications import accessible as nc_ok
            return {"ok": True, "devices": self.device_settings, "diag": self.device_diag, "models": self.router.as_wire(),
                    "bridge": {"name": self.bridge_name, "wifi_mode": self.cfg["bridge"].get("wifi_mode", "signed"), "ws_port": self.cfg["bridge"]["ws_port"],
                               "hosts": {"mdns": BRIDGE_DNS, "lan": (_local_ips() or [""])[0], "tailscale": tailscale_ip()},
                               "notifications": {"enabled": bool(self.cfg.get("notifications", {}).get("enabled", True)), "accessible": nc_ok()[0], "why": nc_ok()[1]},
                               "ntfy": await self.admin("ntfy_status", {})}}
        if op == "provision":
            usb = [x for x in self.sessions if x.transport == "serial" and x.authenticated]
            if not usb:
                return {"ok": False, "error": "no device on USB (provisioning only goes over the cable)"}
            sent = []
            if data.get("ssid"):
                for x in usb:
                    await x.send({"t": "prov.wifi", "ssid": data["ssid"], "pass": data.get("password", "")})
                sent.append("wifi")
            if data.get("bridge"):
                from .security import new_token, cert_pem, BRIDGE_DNS
                token = new_token()
                host = data.get("host") or BRIDGE_DNS      # name, not IP: survives the Mac changing networks
                mode = self.cfg["bridge"].get("wifi_mode", "signed")
                for x in usb:
                    await x.send({"t": "prov.bridge", "host": host, "port": int(self.cfg["bridge"]["ws_port"]), "token": token,
                                  "name": self.bridge_name, "mode": mode, "ca": cert_pem() if mode == "tls" else ""})
                for x in usb:
                    self.registry.add(x.device_id or "usb-provisioned", f"AITL {x.device_id}", token, via="usb", fw=x.fw)
                sent.append(f"bridge {host}:{self.cfg['bridge']['ws_port']} ({mode})")
            return {"ok": True, "sent": sent, "devices": [x.device_id for x in usb]}
        if op == "overview":
            return self.overview()
        if op == "notify_test":
            await self.broadcast({"t": "alert", "id": secrets.token_hex(3), "kind": "notice", "title": str(data.get("title", "Test notification"))[:60],
                                  "text": str(data.get("text", "This came through the macOS notification relay path."))[:300], "project": time.strftime("%H:%M"), "session": "", "actions": ["OK"]})
            return {"ok": True}
        if op == "type_session":
            for x in list(self.sessions):
                if x.authenticated:
                    await x.on_type_session({"session": data.get("session", ""), "text": data.get("text", ""), "enter": data.get("enter", True)}); break
            return {"ok": True, "terminals": {k: {kk: vv for kk, vv in v.items() if kk != "at"} for k, v in (self.hooks.terminals if self.hooks else {}).items()}}
        if op == "pair_open":
            self.pairing.open(int(data.get("seconds", 180)))
            from .security import cert_fingerprint
            return {"ok": True, "fingerprint": cert_fingerprint(), "seconds": int(data.get("seconds", 180))}
        if op in ("wifi_list", "wifi_add", "wifi_remove", "wifi_use"):
            msg = {"wifi_list": {"t": "wifi.list"}, "wifi_add": {"t": "wifi.add", "ssid": data.get("ssid", ""), "pass": data.get("password", ""), "prio": int(data.get("prio", 0))},
                   "wifi_remove": {"t": "wifi.remove", "ssid": data.get("ssid", "")}, "wifi_use": {"t": "wifi.use", "ssid": data.get("ssid", "")}}[op]
            if op == "wifi_add":   # passwords only travel over the cable
                usb = [x for x in self.sessions if x.transport == "serial" and x.authenticated]
                if not usb:
                    return {"ok": False, "error": "adding a network needs the device on USB"}
                fut = asyncio.get_running_loop().create_future(); self.pending_settings["__wifi__"] = fut
                for x in usb:
                    await x.send(msg)
            else:
                fut = asyncio.get_running_loop().create_future(); self.pending_settings["__wifi__"] = fut
                if await self.broadcast(msg) == 0:
                    self.pending_settings.pop("__wifi__", None); return {"ok": False, "error": "no device linked"}
            try:
                await asyncio.wait_for(fut, 6)
            except asyncio.TimeoutError:
                self.pending_settings.pop("__wifi__", None); return {"ok": False, "error": "device did not answer"}
            nets = next(iter(self.device_networks.values()), {})
            return {"ok": True, **nets}
        if op == "wifi_scan":
            fut = asyncio.get_running_loop().create_future(); self.pending_settings["__scan__"] = fut
            if await self.broadcast({"t": "wifi.scan"}) == 0:
                self.pending_settings.pop("__scan__", None); return {"ok": False, "error": "no device linked"}
            try:
                await asyncio.wait_for(fut, 12)
            except asyncio.TimeoutError:
                self.pending_settings.pop("__scan__", None); return {"ok": False, "error": "scan timed out"}
            return {"ok": True, "list": next(iter(self.device_scan.values()), [])}
        if op == "ble_forget":
            fut = asyncio.get_running_loop().create_future(); self.pending_settings["__bonds__"] = fut
            if await self.broadcast({"t": "ble.forget"}) == 0:
                self.pending_settings.pop("__bonds__", None); return {"ok": False, "error": "no device linked"}
            try:
                count = await asyncio.wait_for(fut, 5)
            except asyncio.TimeoutError:
                self.pending_settings.pop("__bonds__", None); return {"ok": False, "error": "device did not answer"}
            return {"ok": True, "bonds": count}
        if op == "config_set":            # {"section": "ntfy", "key": "topic", "value": "..."}; persisted to config.toml
            from . import config as _config
            sec, key, value = str(data.get("section", "")), str(data.get("key", "")), data.get("value")
            if sec not in ("ntfy", "notifications", "bridge", "hid", "buttons", "stt") or not key:
                return {"ok": False, "error": "unknown config key"}
            self.cfg.setdefault(sec, {})[key] = value
            _config.save(self.cfg)
            if sec == "ntfy":
                await self.ntfy_apply()
            return {"ok": True}
        if op == "key_set":               # {"provider": "ntfy", "value": "..."} -> Keychain; never logged
            from . import secrets as _sec
            prov, value = str(data.get("provider", "")), str(data.get("value", ""))
            if not prov:
                return {"ok": False, "error": "provider required"}
            ok = _sec.delete(prov) if not value else _sec.set_key(prov, value)
            if prov == "ntfy":
                await self.ntfy_apply()
            return {"ok": bool(ok)}
        if op == "ntfy_status":
            n = self.ntfy
            return {"ok": True, "enabled": bool(n and n.enabled), "url": n.url if n else "", "topic": n.topic if n else "", "events": sorted(n.events) if n else [],
                    "actions": n.action_base if n else "", "token": bool(n and n.token)}
        if op == "ntfy_test":
            if not self.ntfy or not self.ntfy.enabled:
                return {"ok": False, "error": "set [ntfy] topic in config (or in the app) first"}
            ok = await self.ntfy.send("AITL test", str(data.get("text", "If you can read this on your phone, ntfy forwarding works.")), kind="notify")
            return {"ok": ok, "error": None if ok else "ntfy rejected the push (check url/topic/token in the bridge log)"}
        if op == "status":
            return {"devices": [{"id": s.device_id, "transport": s.transport, "model": s.model, "fw": s.fw} for s in self.sessions if s.authenticated and s.device_id]}
        if op == "set":
            key, value = str(data.get("key", "")), data.get("value")
            fut: asyncio.Future = asyncio.get_running_loop().create_future()
            self.pending_settings[key] = fut
            n = await self.broadcast({"t": "settings.set", "key": key, "value": value})
            if n == 0:
                self.pending_settings.pop(key, None); return {"ok": False, "error": "no device linked"}
            try:
                ok = await asyncio.wait_for(fut, 5)
            except asyncio.TimeoutError:
                self.pending_settings.pop(key, None); return {"ok": False, "error": "device did not acknowledge"}
            return {"ok": ok, "error": None if ok else "unknown key"}
        return {"error": "unknown op"}

    async def broadcast(self, msg: dict[str, Any]) -> int:
        n = 0
        for s in list(self.sessions):
            if s.authenticated and s.device_id:
                await s.send(msg); n += 1
        log.info("broadcast %s -> %d device(s)%s", msg.get("t"), n, "" if n else " (none linked: is the device showing 'USB' in green?)")
        return n


class DeviceSession:
    def __init__(self, shared: Shared, send: SendFn, transport: str, peer: str = ""):
        self.s = shared
        self._send = send
        self.transport = transport
        self.peer = peer
        self.device_id = ""
        self.fw = ""
        self.model = ""
        self.chat: Chat | None = None
        self.gen_task: asyncio.Task | None = None
        self.authenticated = transport == "serial"   # physical USB == trusted
        self.last_reply = ""
        self._audio: audio.AdpcmDecoder | None = None
        self._pcm = bytearray()
        self._audio_target = "ask"
        self._audio_seq = -1
        shared.sessions.add(self)

    async def send(self, msg: dict[str, Any]) -> None:
        try:
            await self._send(msg)
        except Exception as e:  # transport gone
            log.debug("send failed: %s", e)

    async def toast(self, text: str) -> None:
        await self.send({"t": "ui.toast", "msg": text[:200]})

    async def error(self, text: str) -> None:
        await self.send({"t": "chat.error", "msg": text[:300]})

    # ---------- inbound ----------
    async def handle(self, m: dict[str, Any]) -> None:
        t = m.get("t", "")
        if t == "ping":
            await self.send({"t": "pong"}); return
        if t == "pong":
            return
        if t == "hello":
            await self.on_hello(m); return
        if t in ("pair.confirm", "pair.reject"):
            await self.on_pair_reply(m); return
        if not self.authenticated:
            await self.send({"t": "ui.toast", "msg": "Not paired"}); return
        handler = {
            "chat.send": self.on_chat_send, "chat.stop": self.on_chat_stop, "chat.new": self.on_chat_new,
            "chat.open": self.on_chat_open, "chat.delete": self.on_chat_delete, "chat.list": self.on_chat_list,
            "model.list": self.on_model_list, "model.set": self.on_model_set, "action.list": self.on_action_list,
            "action.run": self.on_action_run, "hid.type": self.on_hid_type, "hid.key": self.on_hid_key,
            "dictation": self.on_dictation, "hid.paste_last": self.on_paste_last, "clip.set_last": self.on_clip_last,
            "media": self.on_media, "prov.ok": self.on_prov_ok,
            "cc.list": self.on_cc_list, "cc.open": self.on_cc_open, "alert.reply": self.on_alert_reply, "hid.type_session": self.on_type_session,
            "overview": self.on_overview,
            "audio.start": self.on_audio_start, "audio.chunk": self.on_audio_chunk, "audio.stop": self.on_audio_stop,
            "audio.cancel": self.on_audio_cancel, "settings.ack": self.on_settings_ack, "settings.dump": self.on_settings_dump,
            "wifi.networks": self.on_wifi_networks, "wifi.scan": self.on_wifi_scan, "ble.bonds": self.on_ble_bonds,
        }.get(t)
        if handler:
            await handler(m)
        else:
            log.info("unhandled %s", t)

    async def on_hello(self, m: dict[str, Any]) -> None:
        self.device_id = str(m.get("id", ""))[:32]
        self.fw = str(m.get("fw", ""))[:16]
        if not self.authenticated:
            await self.send({"t": "ui.toast", "msg": "Pairing required"}); return
        await self.s.router.refresh()
        wanted = m.get("model") or ""
        ok_ids = {mi.id for mi in self.s.router.catalog if mi.ok}
        self.model = wanted if wanted in ok_ids else self.s.router.pick_default()
        if m.get("chat"):
            self.chat = self.s.chats.get(str(m["chat"]))
        heap = int(m.get("heap") or 0)
        models = self.s.router.as_wire()
        if heap and heap < 70000:                      # low-RAM device (e.g. Wi-Fi on): only models it can use, fewer chats
            models = [x for x in models if x["ok"]][:12]
        ack = {"t": "hello.ack", "bridge": self.s.bridge_name, "version": __version__,
               "models": models, "chats": self.s.chats.list(8 if heap and heap < 70000 else 30), "actions": self.action_wire(),
               "model": self.model}
        if self.chat:
            ack["chat"] = self.chat.id; ack["title"] = self.chat.title
        if not protocol.fits(ack):
            ack["models"] = ack["models"][:24]; ack["chats"] = ack["chats"][:12]
        if heap:
            log.info("device heap %d KB free", heap // 1024)
        if m.get("reset"):
            ring = m.get("diag") or []              # newest first: ring[0] = this boot's reason + the previous run's uptime/min-heap
            prev = ring[0] if ring else {}
            up = int(m.get("up") or 0)
            if up < 20:
                log.info("device booted %ds ago: reset=%s%s%s", up, m["reset"],
                         f", previous run {int(prev.get('up', 0))}s, min heap {int(prev.get('minheap', 0)) // 1024} KB" if prev else "",
                         f", battery {m['bat']}%" if m.get("bat") is not None else "")
                if m["reset"] in ("panic", "int-wdt", "task-wdt", "wdt", "brownout"):
                    log.warning("device last reset was abnormal: %s (ring: %s)", m["reset"], ring)
            else:
                log.info("device relinked after %ds up (no reboot)%s", up, f", battery {m['bat']}%" if m.get("bat") is not None else "")
            self.s.device_diag[self.device_id] = {"reset": m["reset"], "ring": ring, "bat": m.get("bat"), "up": up}
        await self.send(ack)
        log.info("device %s fw %s linked via %s (model %s)", self.device_id, self.fw, self.transport, self.model)
        app = await mac.frontmost_app()
        await self.send({"t": "status", "dictating": self.s.dict_state["dictating"], "app": app})
        await self.push_now_playing()

    # ---------- chats ----------
    def action_wire(self) -> list[dict[str, str]]:
        return [{"id": a["id"], "label": a["label"]} for a in self.s.cfg.get("actions", [])]

    async def on_chat_send(self, m: dict[str, Any]) -> None:
        text = str(m.get("text", "")).strip()
        if not text:
            return
        if m.get("model"):
            self.model = str(m["model"])
        cid = str(m.get("chat") or "")
        if cid and (not self.chat or self.chat.id != cid):
            self.chat = self.s.chats.get(cid)
        await self.generate(text)

    async def generate(self, user_text: str, type_result: bool = False) -> None:
        if self.gen_task and not self.gen_task.done():
            self.gen_task.cancel()
        self.gen_task = asyncio.create_task(self._generate(user_text, type_result))

    async def _generate(self, user_text: str, type_result: bool) -> None:
        if not self.chat:
            self.chat = self.s.chats.new(self.model)
        chat = self.chat
        chat.model = self.model
        chat.messages.append({"role": "user", "content": user_text})
        reply: list[str] = []
        buf = ""
        last_flush = time.monotonic()
        t_start = time.monotonic()
        try:
            provider = self.s.router.resolve(self.model)
            system = self.s.cfg["bridge"]["system_prompt"]
            max_tokens = int(self.s.cfg["bridge"].get("max_output_tokens", 2048))
            history = chat.messages[-20:]
            if hasattr(provider, "session_id"):
                provider.session_id = chat.ext.get("claude_code_session") if chat.model == self.model else None
            async for piece in provider.stream(self.model, system, history, max_tokens):
                reply.append(piece); buf += piece
                now = time.monotonic()
                if len(buf) >= protocol.DELTA_CHUNK or now - last_flush > 0.12:
                    for c in protocol.chunks(buf):
                        await self.send({"t": "chat.delta", "d": c})
                    buf = ""; last_flush = now
            if buf:
                for c in protocol.chunks(buf):
                    await self.send({"t": "chat.delta", "d": c})
            full = "".join(reply)
            if getattr(provider, "last_session_id", None):
                chat.ext["claude_code_session"] = provider.last_session_id
            u = self.s.note_usage(getattr(provider, "last_usage", None), getattr(provider, "last_cost", None))
            st = chat.ext.setdefault("stats", {"in": 0, "out": 0, "cost": 0.0, "turns": 0, "ms": 0})
            st["in"] += u["in"]; st["out"] += u["out"]; st["cost"] = float(st.get("cost", 0)) + u["cost"]; st["turns"] = int(st.get("turns", 0)) + 1
            st["ms"] = int(st.get("ms", 0)) + int((time.monotonic() - t_start) * 1000)
            chat.messages.append({"role": "assistant", "content": full})
            self.last_reply = full
            if not chat.title:
                chat.title = (user_text.strip().splitlines()[0])[:40]
            self.s.chats.save(chat)
            await self.send({"t": "chat.done", "chat": chat.id, "title": chat.title, "usage": {"in": u["in"], "out": u["out"], "cost": round(u["cost"], 4), "ms": int((time.monotonic() - t_start) * 1000)}})
            if type_result and full:
                await self._hid_guard()
                await mac.type_text(full.strip(), self.s.cfg["hid"]["typing_method"], self.s.cfg["hid"]["restore_clipboard"])
        except asyncio.CancelledError:
            partial = "".join(reply)
            if partial:
                chat.messages.append({"role": "assistant", "content": partial + " [stopped]"})
                self.s.chats.save(chat)
            await self.send({"t": "chat.done", "chat": chat.id, "title": chat.title})
            raise
        except ProviderError as e:
            chat.messages.pop()  # drop the user turn that failed
            await self.error(str(e))
        except Exception as e:  # noqa: BLE001
            log.exception("generation failed")
            chat.messages.pop()
            await self.error(f"bridge error: {type(e).__name__}: {str(e)[:120]}")

    async def on_chat_stop(self, m: dict[str, Any]) -> None:
        if self.gen_task and not self.gen_task.done():
            self.gen_task.cancel()

    async def on_chat_new(self, m: dict[str, Any]) -> None:
        self.chat = None

    async def on_chat_open(self, m: dict[str, Any]) -> None:
        chat = self.s.chats.get(str(m.get("chat", "")))
        if not chat:
            await self.toast("Chat not found"); return
        self.chat = chat
        if chat.model:
            self.model = chat.model
        self.last_reply = chat.last_assistant()
        sid = chat.ext.get("claude_code_session", "")
        await self.send({"t": "chat.view", "chat": chat.id, "title": chat.title, "session": sid,
                         "live": bool(sid and self.s.hooks and self.s.hooks.terminals.get(sid)),
                         "text": chat.transcript(2800), "last": self.last_reply[:1500]})

    async def on_chat_delete(self, m: dict[str, Any]) -> None:
        cid = str(m.get("chat", ""))
        self.s.chats.delete(cid)
        if self.chat and self.chat.id == cid:
            self.chat = None
        await self.on_chat_list(m)

    async def on_chat_list(self, m: dict[str, Any]) -> None:
        await self.send({"t": "chat.list", "chats": self.s.chats.list()})

    async def on_model_list(self, m: dict[str, Any]) -> None:
        await self.s.router.refresh()
        await self.send({"t": "model.list", "models": self.s.router.as_wire()[:40], "model": self.model})

    async def on_model_set(self, m: dict[str, Any]) -> None:
        self.model = str(m.get("model", self.model))[:64]
        await self.toast(f"Model: {self.model}")

    async def on_action_list(self, m: dict[str, Any]) -> None:
        await self.send({"t": "action.list", "actions": self.action_wire()})

    async def on_action_run(self, m: dict[str, Any]) -> None:
        aid = str(m.get("id", ""))
        action = next((a for a in self.s.cfg.get("actions", []) if a["id"] == aid), None)
        if not action:
            await self.error("Unknown action"); return
        if m.get("model"):
            self.model = str(m["model"])
        kind = action.get("kind", "clipboard")
        hid = self.s.cfg["hid"]
        if kind == "ask_voice":
            await self.toast("Speak into the dialog on your Mac...")
            said = await mac.ask_by_voice(shortcut=hid["dictation_shortcut"], method=hid["dictation"])
            if not said.strip():
                await self.error("Nothing captured"); return
            self.chat = self.chat or self.s.chats.new(self.model)
            await self.generate(said.strip()); return
        clip = (await mac.clipboard_get()).strip()
        if not clip:
            await self.error("Mac clipboard is empty"); return
        prompt = action.get("prompt", "{clip}").replace("{clip}", clip[:12000])
        self.chat = self.s.chats.new(self.model)      # actions always start a fresh chat
        await self.generate(prompt, type_result=(kind == "clipboard_type"))

    # ---------- HID ----------
    async def _hid_guard(self) -> bool:
        if not self.s.hid_limiter.allow(self.device_id or self.peer):
            await self.error("HID rate limit"); return False
        if self.s.cfg["hid"].get("notify") and not self.s.hid_notified:
            self.s.hid_notified = True
            await mac.notify("AITL linked", f"Your AITL device can now type, press keys and start dictation on this Mac ({self.transport}).")
        return True

    async def on_hid_type(self, m: dict[str, Any]) -> None:
        text = str(m.get("text", ""))[:8000]
        if not text or not await self._hid_guard():
            return
        ok = await mac.type_text(text, self.s.cfg["hid"]["typing_method"], self.s.cfg["hid"]["restore_clipboard"])
        log.info("hid.type %d chars -> %s %s", len(text), "ok" if ok else "FAILED", "" if ok else mac.LAST_ERROR["text"][:120])
        if not ok:
            await self.error(("Typing blocked by macOS. " if mac.accessibility_denied(mac.LAST_ERROR["text"]) else "Typing failed. ") + mac.accessibility_hint())
        else:
            await self.toast(f"Typed {len(text)} chars into {await mac.frontmost_app() or 'the Mac'}")

    async def on_hid_key(self, m: dict[str, Any]) -> None:
        if not await self._hid_guard():
            return
        ok = await mac.key_combo(str(m.get("combo", ""))[:40])
        log.info("hid.key %s -> %s", m.get("combo"), "ok" if ok else "FAILED")
        if not ok:
            await self.error("Key combo failed. " + mac.accessibility_hint())

    async def on_dictation(self, m: dict[str, Any]) -> None:
        if not await self._hid_guard():
            return
        hid = self.s.cfg["hid"]
        ok = await mac.dictation(str(m.get("op", "toggle")), self.s.dict_state, hid["dictation"], hid["dictation_shortcut"])
        app = await mac.frontmost_app()
        path = self.s.dict_state.get("path", "")
        log.info("dictation %s in %s -> %s via %s (now %s)", m.get("op"), app, "ok" if ok else "FAILED", path or "-", "on" if self.s.dict_state["dictating"] else "off")
        await self.send({"t": "status", "dictating": self.s.dict_state["dictating"], "app": app})
        if not ok:
            await self.error("Dictation blocked: " + mac.accessibility_hint() if path == "denied" else "Could not start dictation. " + mac.accessibility_hint())
        elif path == "shortcut" and self.s.dict_state["dictating"]:
            await self.toast(f"{app}: no Start Dictation menu, sent {hid['dictation_shortcut'].replace(' ', '+')}. If nothing opened: System Settings > Keyboard > Dictation > Shortcut = Press Control key twice")

    async def on_paste_last(self, m: dict[str, Any]) -> None:
        if not self.last_reply:
            await self.toast("No reply to paste"); return
        if await self._hid_guard():
            await mac.type_text(self.last_reply.strip(), self.s.cfg["hid"]["typing_method"], self.s.cfg["hid"]["restore_clipboard"])

    async def on_clip_last(self, m: dict[str, Any]) -> None:
        if self.last_reply:
            await mac.clipboard_set(self.last_reply.strip())

    async def on_media(self, m: dict[str, Any]) -> None:
        if await self._hid_guard():
            ok = await mac.media(str(m.get("key", "play_pause")))
            log.info("media %s -> %s", m.get("key"), "ok" if ok else "FAILED")
            await asyncio.sleep(0.4)
            await self.push_now_playing(force=True)

    # ---------- Claude Code sessions (the `claude -r` archive) ----------
    async def on_overview(self, m: dict[str, Any]) -> None:
        await self.send(self.s.overview())

    async def on_cc_list(self, m: dict[str, Any]) -> None:
        from . import claude_sessions
        items = [i.wire() for i in claude_sessions.list_sessions(limit=int(m.get("limit", 15)))]
        await self.send({"t": "cc.list", "sessions": items})

    async def on_cc_open(self, m: dict[str, Any]) -> None:
        """Bind (or reuse) an AITL chat to a Claude Code session and show its transcript. Typing then resumes that session."""
        from . import claude_sessions
        sid = str(m.get("id", ""))[:36]
        info = claude_sessions.find(sid)
        if not info:
            await self.toast("Session not found"); return
        chat = None
        for c in self.s.chats.list(100):
            cand = self.s.chats.get(c["id"])
            if cand and cand.ext.get("claude_code_session") == sid:
                chat = cand; break
        if not chat:
            chat = self.s.chats.new("claude-code/default")
            chat.title = info.title[:40]
            chat.ext["claude_code_session"] = sid
        chat.model = chat.model if chat.model.startswith("claude-code/") else "claude-code/default"
        self.model = chat.model
        text, last = claude_sessions.transcript_tail(info.path)
        chat.messages = [{"role": "user", "content": f"(resumed Claude Code session {sid[:8]} • {info.project})"}, {"role": "assistant", "content": last or "(no reply yet)"}]
        self.s.chats.save(chat)
        self.chat = chat; self.last_reply = last
        live = bool(self.s.hooks and self.s.hooks.terminals.get(sid))
        await self.send({"t": "chat.view", "chat": chat.id, "title": chat.title, "text": text, "last": last, "session": sid, "live": live})
        await self.send({"t": "model.list", "models": self.s.router.as_wire()[:40], "model": self.model})

    async def on_type_session(self, m: dict[str, Any]) -> None:
        """Type text into the terminal window that runs a given Claude Code session (learned from its hooks)."""
        sid = str(m.get("session", ""))[:36]; text = str(m.get("text", ""))[:4000]; enter = bool(m.get("enter", True))
        term = (self.s.hooks.terminals.get(sid) if self.s.hooks else None) or {}
        if not text:
            return
        if not term.get("app"):
            await self.error("No live terminal known for that session yet. Type one prompt in it (or restart it) so its hooks report where it lives."); return
        if not await self._hid_guard():
            return
        ok = await mac.type_into_app(term["app"], text, enter, self.s.cfg["hid"]["typing_method"], self.s.cfg["hid"]["restore_clipboard"])
        log.info("type_session %s -> %s via %s (%s) %s", sid[:8], "ok" if ok else "FAILED", term["app"], term.get("tty"), "" if ok else mac.LAST_ERROR["text"][:140])
        if ok:
            await self.toast(f"Typed into {term['app']} ({term.get('project', '')})" + (" and sent" if enter else ""))
        else:
            await self.error("Could not type into " + term["app"] + ". " + mac.accessibility_hint())

    async def on_alert_reply(self, m: dict[str, Any]) -> None:
        aid, action = str(m.get("id", "")), str(m.get("action", "dismiss")).lower()
        if self.s.hooks and self.s.hooks.reply(aid, action):
            await self.s.broadcast({"t": "alert.clear", "id": aid})
            log.info("permission %s -> %s (device %s)", aid, action, self.device_id)

    # ---------- device microphone dictation ----------
    async def on_audio_start(self, m: dict[str, Any]) -> None:
        self._audio = audio.AdpcmDecoder(); self._pcm = bytearray(); self._audio_seq = -1
        self._audio_target = str(m.get("target", "ask"))
        log.info("audio: capture started (target %s, engine %s)", self._audio_target, stt.pick(self.s.cfg.get("stt", {})))

    async def on_audio_chunk(self, m: dict[str, Any]) -> None:
        if self._audio is None:
            return
        import base64
        try:
            data = base64.b64decode(m.get("d", ""))
        except ValueError:
            return
        seq = int(m.get("seq", 0))
        if self._audio_seq >= 0 and seq != self._audio_seq + 1:
            log.debug("audio: gap %d -> %d", self._audio_seq, seq)
        self._audio_seq = seq
        self._pcm += self._audio.decode(data)
        if len(self._pcm) > 16000 * 2 * 120:          # 2 minutes max
            await self.on_audio_stop({})

    async def on_audio_stop(self, m: dict[str, Any]) -> None:
        if self._audio is None:
            return
        pcm, target = bytes(self._pcm), self._audio_target
        self._audio = None; self._pcm = bytearray()
        secs = len(pcm) / 32000
        log.info("audio: %0.1fs captured, rms %0.0f", secs, audio.rms(pcm))
        if secs < 0.4 or audio.rms(pcm) < 60:
            await self.send({"t": "dictation.text", "text": "", "target": target, "note": "nothing heard (check mic wiring: SCK 22, WS 21, SD 35, L/R to GND)"})
            return
        await self.send({"t": "ui.toast", "msg": f"Transcribing {secs:0.1f}s..."})
        try:
            text = await stt.transcribe(audio.pcm_to_wav(pcm), self.s.cfg.get("stt", {}))
        except stt.SttError as e:
            await self.error(str(e)); return
        except Exception as e:  # noqa: BLE001
            log.exception("stt failed"); await self.error(f"Transcription failed: {type(e).__name__}"); return
        log.info("audio: transcript %r", text[:80])
        await self.send({"t": "dictation.text", "text": text[:4000], "target": target})
        if not text:
            return
        if target == "type":
            await self._hid_guard()
            await mac.type_text(text, self.s.cfg["hid"]["typing_method"], self.s.cfg["hid"]["restore_clipboard"])
        elif target == "ask":
            await self.generate(text)

    async def on_audio_cancel(self, m: dict[str, Any]) -> None:
        self._audio = None; self._pcm = bytearray()
        log.info("audio: capture cancelled (no speech)")

    async def on_settings_dump(self, m: dict[str, Any]) -> None:
        self.s.device_settings[self.device_id or self.peer] = {k: v for k, v in m.items() if k != "t"}
        fut = self.s.pending_settings.pop("__dump__", None)
        if fut and not fut.done():
            fut.set_result(True)

    async def on_settings_ack(self, m: dict[str, Any]) -> None:
        fut = self.s.pending_settings.pop(str(m.get("key", "")), None)
        if fut and not fut.done():
            fut.set_result(bool(m.get("ok")))

    async def push_now_playing(self, force: bool = False) -> None:
        np = await mac.now_playing()
        await self.send({"t": "np", **np})

    async def on_wifi_networks(self, m: dict[str, Any]) -> None:
        self.s.device_networks[self.device_id] = {k: v for k, v in m.items() if k != "t"}
        fut = self.s.pending_settings.pop("__wifi__", None)
        if fut and not fut.done():
            fut.set_result(True)

    async def on_wifi_scan(self, m: dict[str, Any]) -> None:
        self.s.device_scan[self.device_id] = m.get("list") or []
        fut = self.s.pending_settings.pop("__scan__", None)
        if fut and not fut.done():
            fut.set_result(True)

    async def on_ble_bonds(self, m: dict[str, Any]) -> None:
        fut = self.s.pending_settings.pop("__bonds__", None)
        if fut and not fut.done():
            fut.set_result(int(m.get("count", -1)))

    async def on_prov_ok(self, m: dict[str, Any]) -> None:
        log.info("device confirmed provisioning: %s", m.get("what"))

    # ---------- Wi-Fi pairing (TOFU with code + fingerprint confirmation) ----------
    async def offer_pairing(self) -> None:
        key = self.peer or "?"
        if not self.s.pair_limiter.allow(key):
            await self.send({"t": "ui.toast", "msg": "Pairing rate-limited"}); return
        if not self.s.pairing.is_open():
            await self.send({"t": "ui.toast", "msg": "Bridge pairing window is closed. Run: aitl pair"}); return
        code, token = pairing_code(), new_token()
        self.s.pairing.offers[key] = {"code": code, "token": token, "at": time.time()}
        fp = cert_fingerprint()
        print(f"\n  PAIRING REQUEST from {key}\n  code:        {code}\n  fingerprint: {fp}\n  Confirm on the device only if both match.\n")
        await self.send({"t": "pair.offer", "ca": cert_pem(), "fp": fp, "code": code, "token": token, "name": self.s.bridge_name})

    async def on_pair_reply(self, m: dict[str, Any]) -> None:
        offer = self.s.pairing.offers.pop(self.peer or "?", None)
        if m.get("t") == "pair.reject" or not offer:
            print("  pairing rejected / no offer")
            return
        if str(m.get("code")) != offer["code"] or time.time() - offer["at"] > 180:
            print("  pairing code mismatch or expired"); return
        self.s.registry.add(self.device_id or self.peer, f"AITL {self.device_id}", offer["token"], via="wifi", fw=self.fw)
        self.s.pairing.open_until = 0
        print(f"  paired device {self.device_id}. It will reconnect with the pinned certificate.")

    async def close(self) -> None:
        self.s.sessions.discard(self)
        if self.gen_task and not self.gen_task.done():
            self.gen_task.cancel()
