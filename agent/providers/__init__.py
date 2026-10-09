"""
LLM provider switch. Pick one with LLM_PROVIDER; each provider reads its own
credentials from the environment (see .env.example).

Every provider exposes the same interface:
    provider.name            -> str
    provider.model           -> str
    provider.generate(system, user) -> str   (plain text, non-streaming)
"""
import importlib
import os

PROVIDERS = {
    "gemini": "providers.gemini",                        # Google AI Studio key (Gemini API)
    "vertex": "providers.vertex",                        # Gemini on Google Cloud Vertex AI
    "anthropic": "providers.anthropic_claude",           # Claude API key
    "openai": "providers.openai_chat",                   # OpenAI API key
    "azure-openai": "providers.azure_openai",            # Azure OpenAI deployment
    "bedrock": "providers.bedrock",                      # Amazon Bedrock (any Converse model)
    "huggingface": "providers.huggingface",              # Hugging Face Inference Providers
    "openai-compatible": "providers.openai_compatible",  # vLLM, Ollama, Groq, Together, ...
    "mock": "providers.mock",                            # no key - for smoke tests
}


def get_provider():
    name = os.getenv("LLM_PROVIDER", "mock").strip().lower()
    if name not in PROVIDERS:
        raise ValueError(f"LLM_PROVIDER='{name}' is not one of: {', '.join(PROVIDERS)}")
    return importlib.import_module(PROVIDERS[name]).Provider()


def required(var: str) -> str:
    value = os.getenv(var, "").strip()
    if not value:
        raise ValueError(f"{var} is required for LLM_PROVIDER={os.getenv('LLM_PROVIDER')}")
    return value
