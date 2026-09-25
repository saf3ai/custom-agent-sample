"""Amazon Bedrock via the Converse API - works for any Converse-capable model
(Anthropic Claude, Amazon Nova, Meta Llama, Mistral, ...).

Auth = the standard AWS credential chain: the EC2 instance profile, ECS task
role, Lambda execution role or EKS pod identity. Locally: `aws sso login` or
AWS_PROFILE. No API key in the environment.

LLM_MODEL = the model ID or inference-profile ID shown in your Bedrock console.
"""
import os

import boto3

from providers import required


class Provider:
    name = "bedrock"

    def __init__(self):
        self.model = required("LLM_MODEL")
        self.client = boto3.client("bedrock-runtime",
                                   region_name=os.getenv("AWS_REGION", "us-east-1"))

    def generate(self, system: str, user: str) -> str:
        resp = self.client.converse(
            modelId=self.model,
            system=[{"text": system}],
            messages=[{"role": "user", "content": [{"text": user}]}],
        )
        blocks = resp["output"]["message"]["content"]
        return "".join(b.get("text", "") for b in blocks)
