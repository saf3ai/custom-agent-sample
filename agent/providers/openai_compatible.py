"""Any OpenAI-compatible endpoint: self-hosted vLLM / Ollama / TGI / LiteLLM,
or hosted Groq, Together, DeepSeek, Fireworks, ...

OPENAI_BASE_URL  e.g. http://vllm:8000/v1  or  http://ollama:11434/v1
OPENAI_API_KEY   whatever the endpoint expects ("none" for local servers)
"""
import os

from openai import OpenAI

from providers import required


class Provider:
    name = "openai-compatible"

    def __init__(self):
        self.model = required("LLM_MODEL")
        self.client = OpenAI(base_url=required("OPENAI_BASE_URL"),
                             api_key=os.getenv("OPENAI_API_KEY", "none"))

    def generate(self, system: str, user: str) -> str:
        resp = self.client.chat.completions.create(
            model=self.model,
            messages=[{"role": "system", "content": system},
                      {"role": "user", "content": user}],
        )
        return resp.choices[0].message.content or ""
