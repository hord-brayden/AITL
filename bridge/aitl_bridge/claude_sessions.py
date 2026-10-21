"""Browse Claude Code sessions (the `claude -r` archive under ~/.claude/projects) and read their transcripts."""
from __future__ import annotations
import json
import time
from dataclasses import dataclass
from pathlib import Path

from .importers import CLAUDE_PROJECTS, _text_of

MAX_SCAN_BYTES = 256 * 1024   # read only the head/tail of big logs for titles and views


@dataclass
class SessionInfo:
    id: str
    title: str
    project: str
    path: Path
    updated: float

    def age(self) -> str:
        d = max(0, time.time() - self.updated)
        if d < 3600: return f"{int(d // 60)}m"
        if d < 86400: return f"{int(d // 3600)}h"
        return f"{int(d // 86400)}d"

    def wire(self) -> dict:
        return {"id": self.id, "title": self.title[:40], "project": self.project[:24], "age": self.age()}


def _head_lines(path: Path, limit: int = MAX_SCAN_BYTES):
    with path.open("rb") as f:
        data = f.read(limit)
    for line in data.split(b"\n"):
        if line.startswith(b"{"):
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _tail_lines(path: Path, limit: int = MAX_SCAN_BYTES):
    size = path.stat().st_size
    with path.open("rb") as f:
        if size > limit:
            f.seek(size - limit)
            f.readline()
        data = f.read()
    for line in data.split(b"\n"):
        if line.startswith(b"{"):
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def describe(path: Path) -> SessionInfo | None:
    title, fallback, project, sid = "", "", "", path.stem
    for o in _head_lines(path):
        if o.get("type") == "ai-title" and o.get("aiTitle"):
            title = o["aiTitle"]                      # Claude Code's own title wins
        elif o.get("type") == "user" and not project:
            project = Path(o.get("cwd", "")).name
            sid = o.get("sessionId", sid)
            t = _text_of((o.get("message") or {}).get("content")).strip()
            if t and not t.startswith("<"):
                fallback = t.splitlines()[0][:60]
        if title and project:
            break
    title = title or fallback
    if not title and not project:
        return None
    return SessionInfo(id=sid, title=title or "(untitled)", project=project or path.parent.name[-24:], path=path, updated=path.stat().st_mtime)


def list_sessions(limit: int = 20, project_contains: str | None = None) -> list[SessionInfo]:
    if not CLAUDE_PROJECTS.exists():
        return []
    files = sorted(CLAUDE_PROJECTS.glob("*/*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    out: list[SessionInfo] = []
    for p in files:
        if project_contains and project_contains not in p.parent.name:
            continue
        if p.stat().st_size < 200 or p.parent.name.endswith("-config-aitl-cc"):
            continue                                   # skip tiny logs and the bridge's own device sessions
        info = describe(p)
        if info:
            out.append(info)
        if len(out) >= limit:
            break
    return out


def find(session_id: str) -> SessionInfo | None:
    for p in CLAUDE_PROJECTS.glob(f"*/{session_id}.jsonl"):
        return describe(p)
    return None


def transcript_tail(path: Path, limit_chars: int = 2800) -> tuple[str, str]:
    """(trimmed transcript, last assistant text) built from the end of the log."""
    turns: list[tuple[str, str]] = []
    for o in _tail_lines(path):
        k = o.get("type")
        if k not in ("user", "assistant"):
            continue
        t = _text_of((o.get("message") or {}).get("content")).strip()
        if not t or (k == "user" and t.startswith("<")):
            continue
        if turns and turns[-1][0] == k:
            turns[-1] = (k, turns[-1][1] + "\n" + t)
        else:
            turns.append((k, t))
    text = "\n".join((("> " + t) if k == "user" else t) + "\n" for k, t in turns)
    last = next((t for k, t in reversed(turns) if k == "assistant"), "")
    if len(text) > limit_chars:
        text = "…" + text[-limit_chars:]
    return text, last[:1500]
