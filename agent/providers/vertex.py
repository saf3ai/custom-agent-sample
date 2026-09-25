"""Gemini on Google Cloud Vertex AI. Auth = Application Default Credentials
(the workload's service account on Cloud Run / GKE / GCE, or `gcloud auth
application-default login` locally). No API key."""
import os

from google import genai
from google.genai import types

from providers import required


class Provider:
    name = "vertex"

    def __init__(self):
        self.model = os.getenv("LLM_MODEL") or "gemini-2.5-flash"
        self.client = genai.Client(
            vertexai=True,
            project=required("GOOGLE_CLOUD_PROJECT"),
            location=os.getenv("GOOGLE_CLOUD_LOCATION", "global"),
        )

    def generate(self, system: str, user: str) -> str:
        resp = self.client.models.generate_content(
            model=self.model,
            contents=user,
            config=types.GenerateContentConfig(system_instruction=system),
        )
        return resp.text or ""
