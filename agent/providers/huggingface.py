"""Hugging Face Inference Providers through the OpenAI-compatible router.
HF_TOKEN = a Hugging Face access token with "Inference Providers" permission.
LLM_MODEL = a Hub model id served by Inference Providers (default openai/gpt-oss-20b;
live list: https://router.huggingface.co/v1/models)."""
import os

from openai import OpenAI

from providers import required


class Provider:
    name = "huggingface"

    def __init__(self):
        self.model = os.getenv("LLM_MODEL") or "openai/gpt-oss-20b"
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
