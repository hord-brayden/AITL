"""Claude through the Claude Agent SDK (your Claude Code login / subscription). No API key involved.

Each AITL chat maps to a Claude Code session: the first turn starts one, later turns `resume` it, so the
conversation state lives in Claude Code and the device only has to send the new message. Built-in tools are
disabled: this is a pure chat surface, not an agent with file or shell access.
"""
from __future__ import annotations
import asyncio
import shutil
from typing import AsyncIterator

from .base import Provider, ModelInfo, ProviderError

PREFIX = "claude-code/"
LABELS = {"default": "Claude (Code default)", "opus": "Claude Opus", "sonnet": "Claude Sonnet", "haiku": "Claude Haiku"}


class ClaudeCodeProvider(Provider):
    name = "claude-code"
    label = "Claude Code (subscription)"

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.session_id: str | None = None      # set by the session layer per chat before each stream()
        self.last_session_id: str | None = None

    def available(self) -> bool:
        try:
            import claude_agent_sdk  # noqa: F401
        except ImportError:
            return False
        return shutil.which("claude") is not None or bool(__import__("os").path.exists(__import__("os").path.expanduser("~/.local/bin/claude")))

    def owns(self, model_id: str) -> bool:
        return model_id.startswith(PREFIX)

    async def models(self) -> list[ModelInfo]:
        ok = self.available()
        ids = list(self.cfg.get("models") or ["default", "opus", "sonnet", "haiku"])
        return [ModelInfo(PREFIX + i, LABELS.get(i, f"Claude {i}"), self.label, ok) for i in ids]

    async def stream(self, model_id: str, system: str, messages: list[dict], max_tokens: int) -> AsyncIterator[str]:
        if not self.available():
            raise ProviderError("Claude Code not found. Install Claude Code and run `claude` once to log in.")
        from claude_agent_sdk import query, ClaudeAgentOptions, AssistantMessage, ResultMessage, StreamEvent, TextBlock
        model = model_id[len(PREFIX):]
        latest = messages[-1]["content"] if messages else ""
        prompt = latest
        if not self.session_id and len(messages) > 1:
            # Imported or pre-existing history: fold earlier turns into the first prompt of the new session.
            hist = "\n\n".join(("User: " if m["role"] == "user" else "Assistant: ") + m["content"] for m in messages[:-1])
            prompt = f"Conversation so far (for context):\n\n{hist[-12000:]}\n\n---\nUser: {latest}"
        from .. import config as _cfg
        work = _cfg.CONFIG_DIR / "cc"; work.mkdir(parents=True, exist_ok=True)   # device-born sessions live here, not in your projects
        opts = ClaudeAgentOptions(
            cwd=str(work),
            system_prompt=system,
            model=None if model == "default" else model,
            tools=[],                       # no built-in tools: chat only
            allowed_tools=[],
            permission_mode="plan",         # belt and braces: nothing may run even if a tool slipped through
            max_turns=1,
            include_partial_messages=True,
            resume=self.session_id,
            effort=self.cfg.get("effort") or None,
        )
        streamed = False
        final_text: list[str] = []
        try:
            async for msg in query(prompt=prompt, options=opts):
                if isinstance(msg, StreamEvent):
                    ev = msg.event or {}
                    if ev.get("type") == "content_block_delta" and ev.get("delta", {}).get("type") == "text_delta":
                        streamed = True
                        yield ev["delta"]["text"]
                elif isinstance(msg, AssistantMessage):
                    for b in msg.content:
                        if isinstance(b, TextBlock):
                            final_text.append(b.text)
                elif isinstance(msg, ResultMessage):
                    self.last_session_id = msg.session_id
                    if msg.is_error:
                        raise ProviderError(f"Claude Code: {msg.result or msg.subtype}")
            if not streamed and final_text:
                yield "".join(final_text)
        except ProviderError:
            raise
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001
            raise ProviderError(f"Claude Code: {type(e).__name__}: {str(e)[:160]}") from e
