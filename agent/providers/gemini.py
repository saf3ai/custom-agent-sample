"""Gemini via a Google AI Studio API key (the Gemini API, generativelanguage.googleapis.com)."""
import os

from google import genai
from google.genai import types

from providers import required


class Provider:
    name = "gemini"

    def __init__(self):
        self.model = os.getenv("LLM_MODEL") or "gemini-flash-latest"
        self.client = genai.Client(api_key=required("GEMINI_API_KEY"))

    def generate(self, system: str, user: str) -> str:
        resp = self.client.models.generate_content(
            model=self.model,
            contents=user,
            config=types.GenerateContentConfig(system_instruction=system),
        )
        return resp.text or ""
