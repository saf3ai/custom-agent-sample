"""Hugging Face Inference Providers through the OpenAI-compatible router.
HF_TOKEN = a Hugging Face access token with "Inference Providers" permission.
LLM_MODEL = a model id from the Hub, e.g. an instruct model that lists an
inference provider on its model page."""
import os

from openai import OpenAI

from providers import required


class Provider:
    name = "huggingface"

    def __init__(self):
        self.model = required("LLM_MODEL")
        self.client = OpenAI(
            base_url=os.getenv("HF_BASE_URL", "https://router.huggingface.co/v1"),
            api_key=required("HF_TOKEN"),
        )

    def generate(self, system: str, user: str) -> str:
        resp = self.client.chat.completions.create(
            model=self.model,
            messages=[{"role": "system", "content": system},
                      {"role": "user", "content": user}],
        )
        return resp.choices[0].message.content or ""
