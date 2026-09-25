"""Claude via an Anthropic API key (ANTHROPIC_API_KEY).

Server-side refusal fallbacks are on: if the model declines a request on
safety-policy grounds, the API re-runs it on a fallback model within the same
call. Set ANTHROPIC_FALLBACKS=off to disable.
"""
import os

import anthropic

from providers import required


class Provider:
    name = "anthropic"

    def __init__(self):
        self.model = os.getenv("LLM_MODEL") or "claude-opus-5"
        self.max_tokens = int(os.getenv("LLM_MAX_TOKENS", "16000"))
        self.fallbacks = os.getenv("ANTHROPIC_FALLBACKS", "on").lower() != "off"
        self.client = anthropic.Anthropic(api_key=required("ANTHROPIC_API_KEY"))

    def generate(self, system: str, user: str) -> str:
        request = dict(
            model=self.model,
            max_tokens=self.max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
        resp = None
        if self.fallbacks:
            try:
                resp = self.client.beta.messages.create(
                    **request, betas=["server-side-fallback-2026-07-01"], fallbacks="default")
            except TypeError:  # SDK older than 1.8 (e.g. on Python 3.9): no fallbacks parameter
                self.fallbacks = False
        if resp is None:
            resp = self.client.messages.create(**request)
        if resp.stop_reason == "refusal":
            return "I can't help with that request."
        return "".join(b.text for b in resp.content if b.type == "text")
