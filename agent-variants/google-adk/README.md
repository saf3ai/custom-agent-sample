# Google ADK variant

Retail support agent built with Google ADK on Gemini, with one tool (`get_order_status`, mock data).

| File | Role | Saf3AI code? |
|---|---|---|
| `saf3ai_setup.py` | Init, scan, enforce, ADK model callbacks | **All of it** |
| `agent.py` | ADK `LlmAgent` + tool + Runner | `start("adk")` + 2 callbacks |
| `app.py` | HTTP API: `POST /chat`, `GET /healthz` | `run_turn()` |

## How Saf3AI hooks in

| Layer | What it does |
|---|---|
| `start("adk")` at import of `agent.py` | SDK detects ADK and traces agent runs and Gemini model calls |
| `run_turn()` in `/chat` | Scans the user message; a blocked prompt returns **403 before ADK runs** |
| `before_model_callback` / `after_model_callback` | Verdict on every model call. Outside `/chat` (Agent Engine, `adk web`, your own Runner) they **block**: the model is not called and the agent replies with a refusal |

## Run locally

```bash
pip install -r requirements.txt
cp .env.example .env          # SAF3AI_* + GOOGLE_API_KEY (or the Vertex AI lines)
uvicorn app:app --port 8080
curl -s localhost:8080/chat -H "Content-Type: application/json" -d '{"message":"Where is my order 4211?"}'
```

## Deploy

- Any container target in `../../deploy/` (same image contract as `agent/`: `$PORT`, `/healthz`).
- Vertex AI Agent Engine: `../../deploy/gcp-vertex-agent-engine/`.

## Notes

- Stateless per request, like `agent/`. For memory, keep the ADK session and use a persistent session service.
- Conversations appear in the console as `adk_session_<conversation_id>`. `/chat` returns your id unchanged.
- `SAF3AI_FAIL_MODE=closed` applies to `/chat`. The model callbacks allow the call if the scanner is unreachable.
- Tested with `google-adk` 2.9.2 and `saf3ai-sdk` 0.2.4.
