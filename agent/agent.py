"""
The agent itself - plain Python, no Saf3AI code.

A small retail customer-support assistant. Replace SYSTEM_PROMPT and answer()
with your own logic; the Saf3AI wiring in saf3ai_setup.py does not change.
"""
from pathlib import Path

from providers import get_provider

SYSTEM_PROMPT = (Path(__file__).parent / "prompts" / "system_prompt.txt").read_text(encoding="utf-8")

provider = get_provider()


def answer(message: str) -> str:
    """One LLM call: system prompt + the user's message -> reply text."""
    return provider.generate(SYSTEM_PROMPT, message)
