"""OpenAI Chat Completions with an OpenAI API key (OPENAI_API_KEY)."""
from openai import OpenAI

from providers import required


class Provider:
    name = "openai"

    def __init__(self):
        self.model = required("LLM_MODEL")
        self.client = OpenAI(api_key=required("OPENAI_API_KEY"))

    def generate(self, system: str, user: str) -> str:
        resp = self.client.chat.completions.create(
            model=self.model,
            messages=[{"role": "system", "content": system},
                      {"role": "user", "content": user}],
        )
        return resp.choices[0].message.content or ""
