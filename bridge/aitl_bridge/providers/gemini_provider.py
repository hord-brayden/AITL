"""Google Gemini via the google-genai SDK."""
from __future__ import annotations
from typing import AsyncIterator

from .base import Provider, ModelInfo, ProviderError
from .. import secrets


class GeminiProvider(Provider):
    name = "gemini"
    label = "Google Gemini"

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self._client = None

    def available(self) -> bool:
        return bool(secrets.get("gemini"))

    def owns(self, model_id: str) -> bool:
        return model_id.startswith("gemini-")

    def _get_client(self):
        if self._client is None:
            from google import genai
            self._client = genai.Client(api_key=secrets.get("gemini"))
        return self._client

    async def models(self) -> list[ModelInfo]:
        ok = self.available()
        ids = list(self.cfg.get("models") or [])
        if ok and self.cfg.get("live_list"):
            try:
                client = self._get_client()
                live = []
                async for m in await client.aio.models.list():
                    actions = getattr(m, "supported_actions", None) or []
                    mid = (m.name or "").replace("models/", "")
                    skip = ("tts", "image", "embedding", "customtools", "audio", "live", "native")
                    if mid.startswith("gemini-") and (not actions or "generateContent" in actions) and not any(k in mid for k in skip):
                        live.append(mid)
                ids = [i for i in ids if i in live] + [i for i in live if i not in ids][:12]
            except Exception:
                pass
        return [ModelInfo(i, i.replace("gemini-", "Gemini ").replace("-", " ").title(), self.label, ok) for i in ids]

    async def stream(self, model_id: str, system: str, messages: list[dict], max_tokens: int) -> AsyncIterator[str]:
        if not self.available():
            raise ProviderError("Gemini key missing. Run: aitl keys set gemini")
        from google.genai import types
        client = self._get_client()
        contents = [types.Content(role="user" if m["role"] == "user" else "model", parts=[types.Part(text=m["content"])])
                    for m in messages]
        cfg = types.GenerateContentConfig(system_instruction=system, max_output_tokens=max_tokens)
        try:
            async for chunk in await client.aio.models.generate_content_stream(model=model_id, contents=contents, config=cfg):
                if chunk.text:
                    yield chunk.text
        except Exception as e:  # google-genai raises several error classes; surface the message
            raise ProviderError(f"Gemini: {str(e)[:160]}") from e
