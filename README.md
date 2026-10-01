# Saf3AI Custom Agent Deployment Kit

A working sample agent, secured with the Saf3AI SDK, plus ready-to-use deployment for every major platform.
Pick **one LLM** and **one target** — any combination works with the same image.

## What you get

| Folder | Contents |
|---|---|
| `deploy.py` | **Guided deploy**: step-by-step choice of cloud, service, framework and LLM, then build, deploy and verify |
| `agent/` | The sample agent (Python, FastAPI). All Saf3AI code is in one file: `saf3ai_setup.py` |
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

## Guided deploy (recommended)

```bash
python deploy.py              # step-by-step: pick, review, deploy, verify
python deploy.py --dry-run    # preview every command; nothing is changed
python deploy.py --destroy    # remove it again
```

| Step | You choose / it does |
|---|---|
| 1 | Checks your tools (docker, terraform, aws, az, gcloud, kubectl, git, bash) and which accounts you're signed in to |
| 2 | Saf3AI API key (pasted) + agent id + enforcement. One test scan confirms the key and network |
| 3 | Cloud → service: this machine (plain Python, no Docker / Docker / Linux VM service), AWS, Azure, Google Cloud, Hugging Face, any Kubernetes |
| 4 | Framework → LLM (only valid combinations are offered) → model → LLM key |
| 5 | Target details (region, project, network, names) with defaults |
| 6 | Review. Nothing happens until you confirm |
| 7 | Builds and pushes the image, stores keys in the platform's secret store, deploys |
| 8 | Sends a normal and an injection message: expects 200 and 403 |

- Fastest first test: **This machine → Plain Python** with **LLM = Mock**. It sets up a virtual env, starts the agent on localhost, and runs the two checks. It can also run as a chat in your terminal.
- Python 3.9+ only, no packages to install. On Windows, run the wizard from Git Bash or PowerShell; it uses Git Bash for the shell scripts.
- Keys go straight to the platform's secret store. They're never written into the kit or the answers file; the AWS and Kubernetes steps read them from a short-lived owner-only temp file that's deleted right after. Your other answers are saved to `saf3ai-deploy.json` for re-runs and `--destroy`.
- Azure targets use Terraform, and Terraform keeps the key values in its state file. Keep that file private.

## Run as a container (env vars only)

The image starts the API on `$PORT` (8080) with the Saf3AI SaaS endpoints built in. Pass keys as environment variables; nothing else is needed.

```bash
docker build -t saf3ai-sample-agent ./agent        # or agent-variants/<framework>
docker run -p 8080:8080 -e SAF3AI_API_KEY=<key> -e LLM_PROVIDER=gemini -e GEMINI_API_KEY=<key> saf3ai-sample-agent
```

| Variable | Needed | Default in the image |
|---|---|---|
| `SAF3AI_API_KEY` | **Yes** | none. The agent exits with a clear message if it's missing |
| `LLM_PROVIDER` + that provider's key | For a real LLM | `mock` (no key; proves the Saf3AI wiring) |
| `SAF3AI_AGENT_ID`, `LLM_MODEL` | Optional | `sample-support-agent`, provider default |
| `SAF3AI_COLLECTOR_AGENT`, `SAF3AI_SCANNER_ENDPOINT` | Optional | Saf3AI SaaS endpoints |
| `SAF3AI_ENFORCEMENT`, `SAF3AI_FAIL_MODE`, `SAF3AI_ENVIRONMENT` | Optional | `block`, `open`, `production` |

- In the cloud, keep the keys in the platform's secret store; each `deploy/` folder shows how.

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
