"""Relay macOS notifications (Zoom, Slack, Mail, anything) to the device.

Reads the Notification Center store (~/Library/Group Containers/group.com.apple.usernoted/db2/db). That needs
Full Disk Access for AITL Bridge.app (System Settings › Privacy & Security › Full Disk Access). The DB is copied to a
temp file before reading so the live store is never locked. New rows since the last poll become `notice` cards.
"""
from __future__ import annotations
import datetime as dt
import logging
import plistlib
import shutil
import sqlite3
import tempfile
import time
from pathlib import Path
from typing import Any

log = logging.getLogger("aitl.notify")
DB = Path.home() / "Library" / "Group Containers" / "group.com.apple.usernoted" / "db2" / "db"
MAC_EPOCH = 978307200.0   # 2001-01-01 in Unix time

FRIENDLY = {"us.zoom.xos": "Zoom", "com.tinyspeck.slackmacgap": "Slack", "com.apple.mail": "Mail", "com.apple.MobileSMS": "Messages",
            "com.google.chrome": "Chrome", "com.apple.iCal": "Calendar", "com.microsoft.teams2": "Teams", "com.microsoft.Outlook": "Outlook",
            "com.apple.reminders": "Reminders", "com.hnc.Discord": "Discord", "com.spotify.client": "Spotify"}
DEFAULT_IGNORE = {"com.apple.scripteditor2", "com.caeruli-obscuri.aitl", "com.apple.gamepolicynotifications",
                  "_system_center_:com.apple.diskarbitration.diskarbitrationagent", "com.apple.appstore"}


def accessible() -> tuple[bool, str]:
    if not DB.exists():
        return False, "Notification Center store not found"
    try:
        with DB.open("rb") as f:
            f.read(16)
        return True, ""
    except PermissionError:
        return False, "Full Disk Access not granted to AITL Bridge"
    except OSError as e:
        return False, str(e)


class NotificationWatcher:
    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg
        self.last_id: int | None = None
        self.tmp = Path(tempfile.gettempdir()) / "aitl-nc.db"

    def _snapshot(self) -> sqlite3.Connection | None:
        try:
            shutil.copy2(DB, self.tmp)
            for extra in ("-wal", "-shm"):
                src = DB.with_name(DB.name + extra)
                if src.exists():
                    shutil.copy2(src, self.tmp.with_name(self.tmp.name + extra))
            return sqlite3.connect(str(self.tmp))
        except Exception as e:  # noqa: BLE001
            log.debug("snapshot failed: %s", e)
            return None

    def poll(self) -> list[dict[str, Any]]:
        """Return new notifications since the last poll (first poll only primes the cursor)."""
        con = self._snapshot()
        if not con:
            return []
        out: list[dict[str, Any]] = []
        try:
            rows = con.execute("select record.rec_id, record.data, record.delivered_date, app.identifier from record "
                               "join app on record.app_id = app.app_id order by rec_id desc limit 40").fetchall()
        except sqlite3.Error as e:
            log.debug("query failed: %s", e); con.close(); return []
        con.close()
        if not rows:
            return []
        newest = rows[0][0]
        if self.last_id is None:
            self.last_id = newest
            return []
        allow = set(self.cfg.get("apps") or [])
        ignore = set(self.cfg.get("ignore") or []) | DEFAULT_IGNORE
        for rec_id, data, delivered, app in reversed(rows):
            if rec_id <= self.last_id:
                continue
            if app in ignore or (allow and app not in allow):
                continue
            try:
                d = plistlib.loads(data)
            except Exception:  # noqa: BLE001
                continue
            req = d.get("req") or {}
            title = str(req.get("titl") or "").strip(); sub = str(req.get("subt") or "").strip(); body = str(req.get("body") or "").strip()
            when = float(d.get("date") or delivered or 0) + MAC_EPOCH
            out.append({"app": FRIENDLY.get(app, app.split(".")[-1].title()), "bundle": app, "title": title, "subtitle": sub, "body": body,
                        "time": dt.datetime.fromtimestamp(when).strftime("%H:%M") if when > MAC_EPOCH else "", "id": rec_id})
        self.last_id = newest
        return out
