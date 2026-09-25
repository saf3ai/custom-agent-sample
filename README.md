# Saf3AI Custom Agent Deployment Kit

A working sample agent, secured with the Saf3AI SDK, plus ready-to-use deployment for every major platform.
Pick **one LLM** and **one target** — any combination works with the same image.

## What you get

| Folder | Contents |
|---|---|
| `agent/` | The sample agent (Python, FastAPI) — **start here**. All Saf3AI code is in one file: `saf3ai_setup.py` |
| `agent-variants/` | The same agent built on Google ADK, LangChain, CrewAI, OpenAI Agents SDK |
| `deploy/` | One folder per target — Terraform / manifests / scripts + README |
| `docs/` | Provider matrix · target matrix · network & data flow · verify & troubleshoot |
| `docker-compose.yml` | Build and run locally in one command |

## How Saf3AI is wired in (3 steps, one file)

| Step | Code | Effect |
|---|---|---|
| 1 | `saf3ai_setup.start()` at startup | SDK initialised: traces to your Saf3AI tenant |
| 2 | `run_turn(...)` around each agent turn | User message scanned; turn traced |
| 3 | Verdict enforced before the LLM call | Unsafe prompt → HTTP 403, model never called |

- Your agent calls the LLM **directly** — Saf3AI is not in the model path. See `docs/network-and-data.md`.
- Policies and guardrails are managed in the Saf3AI console — no redeploy to change them.
- SDK: `saf3ai-sdk==0.2.4` from PyPI.

## Quick start (local, 5 minutes)

```bash
cp agent/.env.example agent/.env     # set SAF3AI_API_KEY; keep LLM_PROVIDER=mock for the first run
docker compose up --build
```

Without Docker:

```bash
cd agent
python -m venv .venv && . .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
uvicorn app:app --port 8080                         # or: python cli.py
```

Then run the 3 checks in `docs/verify-and-troubleshoot.md`.

## Choose an LLM (`LLM_PROVIDER`)

`gemini` · `vertex` · `anthropic` (Claude) · `openai` · `azure-openai` · `bedrock` · `huggingface` · `openai-compatible` (vLLM, Ollama, Groq, …) · `mock`
→ credentials and models: `docs/provider-matrix.md`

## Choose a target (`deploy/`)

| Cloud | Targets |
|---|---|
| Any | `local-docker` (root `docker-compose.yml`) · `vm-any-cloud` · `kubernetes` |
| AWS | `aws-ec2` · `aws-ecs-fargate` · `aws-lambda` · `kubernetes/overlays/eks` |
| Azure | `azure-container-apps` · `azure-app-service` · `kubernetes/overlays/aks` |
| Google Cloud | `gcp-cloud-run` · `gcp-vertex-agent-engine` · `kubernetes/overlays/gke` |
| Hugging Face | `hugging-face-spaces` |

→ comparison: `docs/target-matrix.md`

## Getting your Saf3AI values

Saf3AI console → **Integrations → SDK → Custom Agent SDK → Set up SDK**: organization API key and endpoints, prefilled.

## Security notes

- Keep `SAF3AI_API_KEY` and model keys in your platform's secret store — every `deploy/` folder shows how.
- The container runs as a non-root user and needs outbound HTTPS only.
