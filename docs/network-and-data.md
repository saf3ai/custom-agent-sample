# Network, data flow and cost

## Two separate flows

| Flow | Path | Saf3AI in the path? |
|---|---|---|
| **Model call** | Your agent → your LLM provider, directly | **No** — Saf3AI is not a proxy for the model call |
| **Security + telemetry** | Your agent → Saf3AI Scanner (analysis) and Saf3AI Collector (traces), over HTTPS | Yes — this is how detection and blocking work |

- Blocking happens **inside your agent**: the scan verdict comes back and your agent stops the turn before the model is called.
- The model provider's credentials never leave your environment.

```
 user ──▶ your agent ──────────────────────────────▶ LLM provider (direct)
              │  ▲
              │  └── verdict (allow / block)
              ├──▶ scanner.saf3ai.com   (prompt + reply text for analysis)
              └──▶ analyzer.saf3ai.com  (traces: metadata + verdicts)
```

## Egress allow-list

| Destination | Port | Why |
|---|---|---|
| `scanner.saf3ai.com` | 443 | Scan prompts and replies |
| `analyzer.saf3ai.com` | 443 | Send traces (OpenTelemetry over HTTP) |
| Your LLM provider (below) | 443 | The model call |

| `LLM_PROVIDER` | Host |
|---|---|
| gemini | `generativelanguage.googleapis.com` |
| vertex | `aiplatform.googleapis.com` / `<region>-aiplatform.googleapis.com` |
| anthropic | `api.anthropic.com` |
| openai | `api.openai.com` |
| azure-openai | `<your-resource>.openai.azure.com` |
| bedrock | `bedrock-runtime.<region>.amazonaws.com` |
| huggingface | `router.huggingface.co` |
| openai-compatible | your endpoint |

- No inbound connections from Saf3AI to your environment.
- Corporate proxy: set `HTTPS_PROXY` — the Saf3AI calls honour it.
- Both Saf3AI calls authenticate with your organization API key (`SAF3AI_API_KEY`).

## What is sent to Saf3AI (this agent)

| Data | Sent to | Stored in traces | Switch |
|---|---|---|---|
| User message text | Scanner + Collector | Yes | — |
| Model reply text | Scanner | No (verdict only) | — |
| Scan verdict (threat categories) | Collector | Yes | — |
| Agent id, service name, environment, conversation id, user id (if you pass one), timings | Collector | Yes | — |
| Name and source-file path of the traced entry-point function | Collector | Yes | — |
| Caller IP and user agent of the HTTP request | Collector | Yes | `SAF3AI_CLIENT_DATA_CAPTURE=false` |

- Not sent: model provider keys, your system prompt, environment variables, files.
- At rest in Saf3AI, prompt/response content can be stored encrypted per your tenant's **Data Policy** (Admin → Data Policy).
- **Content must not leave your network?** Saf3AI can also be deployed inside your environment. Point `SAF3AI_SCANNER_ENDPOINT` and `SAF3AI_COLLECTOR_AGENT` at the in-environment URLs — no agent code change. Your Saf3AI solution architect will scope it.

## Enforcement settings

| Variable | Values | Effect |
|---|---|---|
| `SAF3AI_ENFORCEMENT` | `block` (default) / `monitor` | Stop unsafe prompts (HTTP 403) vs. allow and record |
| `SAF3AI_FAIL_MODE` | `open` (default) / `closed` | If the scanner is unreachable: allow vs. block |
| `SAF3AI_BLOCK_RESPONSES` | `false` (default) / `true` | Also block unsafe model replies (one extra scan call per turn) |

## What this adds to your cloud bill

| Item | Driver |
|---|---|
| Agent compute | The container you run (VM, Cloud Run, ECS, AKS, …) — same as without Saf3AI |
| Outbound data transfer | Per turn: the prompt and reply text plus small trace metadata, sent over HTTPS. Priced per GB by your cloud |
| LLM usage | Billed by your model provider, unchanged by Saf3AI |
| Saf3AI components in your account | None for this SaaS setup |

- Each scan adds a network hop to the turn — benchmark in your environment.
