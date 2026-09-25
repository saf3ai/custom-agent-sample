# OpenAI Agents SDK variant

Retail support agent built with the OpenAI Agents SDK (`Agent` + `Runner`), with one tool (`get_order_status`, mock data).

| File | Role | Saf3AI code? |
|---|---|---|
| `saf3ai_setup.py` | Init, scan, enforce, tool tracing | **All of it** |
| `agent.py` | Agent + tool + Runner | 1 decorator on the tool |
| `app.py` | HTTP API: `POST /chat`, `GET /healthz` | `start("custom")`, `run_turn()` |

## How Saf3AI hooks in

| Layer | What it does |
|---|---|
| `start("custom")` | Uses the SDK's framework-agnostic `custom` integration |
| `run_turn()` in `/chat` | Traces the turn, scans the user message and the reply; a blocked prompt returns **403 before the agent runs** |
| `@saf3ai_setup.traced_tool` | A span per tool call, inside the turn |

- Model calls are covered by the turn span (prompt in, reply out).

## Run locally

```bash
pip install -r requirements.txt
cp .env.example .env          # SAF3AI_* + OPENAI_API_KEY
uvicorn app:app --port 8080
curl -s localhost:8080/chat -H "Content-Type: application/json" -d '{"message":"Where is my order 4211?"}'
```

## Deploy

Any container target in `../../deploy/` (same image contract as `agent/`: `$PORT`, `/healthz`).

## Notes

- Stateless per request, like `agent/`. For memory, pass an Agents SDK session keyed on `conversation_id`.
- Keep `google-adk`, `crewai` and `langchain-core` out of this image, or the SDK stops treating it as `custom`.
- Tested with `openai-agents` 0.22.3 and `saf3ai-sdk` 0.2.4.
