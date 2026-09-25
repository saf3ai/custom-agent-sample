# LLM providers

Set `LLM_PROVIDER` and the provider's variables. Same image, same Saf3AI wiring for all of them.

| `LLM_PROVIDER` | Credentials | `LLM_MODEL` | Notes |
|---|---|---|---|
| `gemini` | `GEMINI_API_KEY` (Google AI Studio) | optional — default `gemini-flash-latest` | Gemini API |
| `vertex` | Workload service account (no key) · `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION` | optional — default `gemini-2.5-flash` (must be available to your project/region) | Grant the runtime SA `roles/aiplatform.user` |
| `anthropic` | `ANTHROPIC_API_KEY` | optional — default `claude-opus-5` | Refusal fallbacks on; `ANTHROPIC_FALLBACKS=off` to disable |
| `openai` | `OPENAI_API_KEY` | optional — default `gpt-4.1-mini` | Chat Completions |
| `azure-openai` | `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_API_VERSION` | required — your **deployment name** | |
| `bedrock` | Workload IAM role (no key) · `AWS_REGION` | optional — default `amazon.nova-lite-v1:0` (enable it in the Bedrock console; some regions need the inference-profile id) | Converse API: Claude, Nova, Llama, Mistral, … Role needs `bedrock:InvokeModel` |
| `huggingface` | `HF_TOKEN` (Inference Providers permission) | optional — default `openai/gpt-oss-20b` ([live list](https://router.huggingface.co/v1/models)) | OpenAI-compatible router |
| `openai-compatible` | `OPENAI_BASE_URL`, `OPENAI_API_KEY` | required | vLLM, Ollama, TGI, LiteLLM, Groq, Together, … |
| `mock` | none | — | Echo reply — proves the Saf3AI wiring with no model cost |

## Adding your own provider

1. Copy `agent/providers/mock.py` → `agent/providers/<name>.py`.
2. Implement `generate(system, user) -> str` (non-streaming, plain text).
3. Register it in `agent/providers/__init__.py`.

- Nothing in `saf3ai_setup.py` changes.
- Keep calls non-streaming: the reply is scanned as one piece of text.
