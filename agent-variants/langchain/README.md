# LangChain variant

Retail support agent built with LangChain (`create_agent`), with one tool (`get_order_status`, mock data).
`LLM_PROVIDER` = `google-genai`, `openai` or `anthropic`.

| File | Role | Saf3AI code? |
|---|---|---|
| `saf3ai_setup.py` | Init, scan, enforce, LangChain handler, tool tracing | **All of it** |
| `agent.py` | Chat model + tool-calling agent | 1 decorator on the tool |
| `app.py` | HTTP API: `POST /chat`, `GET /healthz` | `start("langchain")`, `run_turn()`, callbacks |

## How Saf3AI hooks in

| Layer | What it does |
|---|---|
| `start("langchain")` | SDK detects LangChain and traces every chat-model call |
| `run_turn()` in `/chat` | Scans the user message; a blocked prompt returns **403 before the agent runs** |
| `langchain_callbacks()` | SDK handler in the run config: a verdict on every model call, covering the full model input (incl. tool results), for visibility |
| `@saf3ai_setup.traced_tool` | A span per tool call, inside the turn |

## Run locally

```bash
pip install -r requirements.txt
cp .env.example .env          # SAF3AI_* + LLM_PROVIDER and its key
uvicorn app:app --port 8080
curl -s localhost:8080/chat -H "Content-Type: application/json" -d '{"message":"Where is my order 4211?"}'
```

## Deploy

Any container target in `../../deploy/` (same image contract as `agent/`: `$PORT`, `/healthz`).

## Notes

- Stateless per request, like `agent/`. For memory, add a LangGraph checkpointer keyed on `conversation_id`.
- Tested with `langchain` 1.4.2 and `saf3ai-sdk` 0.2.4.
