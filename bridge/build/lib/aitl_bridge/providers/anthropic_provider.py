"""Claude via the official Anthropic SDK. Adaptive thinking is on; Fable 5.1 opts into server-side refusal fallbacks."""
from __future__ import annotations
from typing import AsyncIterator

from .base import Provider, ModelInfo, ProviderError
from .. import secrets

LABELS = {
    "claude-fable-5-1": "Claude Fable 5.1",
    "claude-opus-5-5": "Claude Opus 5.5",
    "claude-opus-5": "Claude Opus 5",
    "claude-sonnet-5-5": "Claude Sonnet 5.5",
    "claude-haiku-5-5": "Claude Haiku 5.5",
    "claude-opus-4-8": "Claude Opus 4.8",
}


class AnthropicProvider(Provider):
    name = "anthropic"
    label = "Anthropic"

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self._client = None
        self.last_usage: dict | None = None
        self.last_cost: float | None = None

    def _key(self) -> str | None:
        return secrets.get("anthropic")

    def available(self) -> bool:
        if self._key():
            return True
        try:  # `ant auth login` profile / ANTHROPIC_AUTH_TOKEN also work with a zero-arg client
            import anthropic  # noqa: F401
            return bool(__import__("os").environ.get("ANTHROPIC_AUTH_TOKEN"))
        except ImportError:
            return False

    def owns(self, model_id: str) -> bool:
        return model_id.startswith("claude-")

    def _get_client(self):
        if self._client is None:
            import anthropic
            key = self._key()
            self._client = anthropic.AsyncAnthropic(api_key=key) if key else anthropic.AsyncAnthropic()
        return self._client

    async def models(self) -> list[ModelInfo]:
        ok = self.available()
        ids = list(self.cfg.get("models") or LABELS.keys())
        if ok and self.cfg.get("live_list"):
            try:
                client = self._get_client()
                live = [m.id async for m in client.models.list()]
                ids = [i for i in ids if i in live] + [i for i in live if i not in ids and i.startswith("claude-")]
            except Exception:
                pass
        return [ModelInfo(i, LABELS.get(i, i), self.label, ok) for i in ids]

    async def stream(self, model_id: str, system: str, messages: list[dict], max_tokens: int) -> AsyncIterator[str]:
        if not self.available():
            raise ProviderError("Anthropic key missing. Run: aitl keys set anthropic")
        import anthropic
        client = self._get_client()
        kwargs = dict(model=model_id, max_tokens=max_tokens, system=system, messages=messages,
                      thinking={"type": "adaptive"})
        try:
            if model_id.startswith("claude-fable-") or model_id in ("claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"):
                # Opt into server-side refusal fallbacks (routes by refusal category; no model list to maintain).
                async with client.beta.messages.stream(betas=["server-side-fallback-2026-07-01"], fallbacks="default", **kwargs) as s:
                    async for text in s.text_stream:
                        yield text
                    final = await s.get_final_message()
            else:
                async with client.messages.stream(**kwargs) as s:
                    async for text in s.text_stream:
                        yield text
                    final = await s.get_final_message()
            if getattr(final, "usage", None):
                self.last_usage = {"input_tokens": final.usage.input_tokens, "output_tokens": final.usage.output_tokens}
            if final.stop_reason == "refusal":
                detail = getattr(getattr(final, "stop_details", None), "category", None)
                yield f"\n[declined{': ' + detail if detail else ''}]"
            elif final.stop_reason == "max_tokens":
                yield "\n[truncated: raise bridge.max_output_tokens]"
        except anthropic.AuthenticationError as e:
            raise ProviderError("Anthropic auth failed; check the key (aitl keys set anthropic)") from e
        except anthropic.RateLimitError as e:
            raise ProviderError("Anthropic rate limit; retry shortly") from e
        except anthropic.NotFoundError as e:
            raise ProviderError(f"Unknown model {model_id}") from e
        except anthropic.APIStatusError as e:
            raise ProviderError(f"Anthropic API {e.status_code}: {e.message}") from e
        except anthropic.APIConnectionError as e:
            raise ProviderError("Anthropic: network error") from e
