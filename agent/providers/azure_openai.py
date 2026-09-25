"""Azure OpenAI. LLM_MODEL = your *deployment name*, not the base model name."""
import os

from openai import AzureOpenAI

from providers import required


class Provider:
    name = "azure-openai"

    def __init__(self):
        self.model = required("LLM_MODEL")
        self.client = AzureOpenAI(
            azure_endpoint=required("AZURE_OPENAI_ENDPOINT"),
            api_key=required("AZURE_OPENAI_API_KEY"),
            api_version=os.getenv("AZURE_OPENAI_API_VERSION", "2024-10-21"),
        )

    def generate(self, system: str, user: str) -> str:
        resp = self.client.chat.completions.create(
            model=self.model,
            messages=[{"role": "system", "content": system},
                      {"role": "user", "content": user}],
        )
        return resp.choices[0].message.content or ""
