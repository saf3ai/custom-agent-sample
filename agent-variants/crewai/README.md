# CrewAI variant

Retail support agent as a single-agent CrewAI crew, with one tool (`get_order_status`, mock data).

| File | Role | Saf3AI code? |
|---|---|---|
| `saf3ai_setup.py` | Init, scan, enforce, tool tracing | **All of it** |
| `agent.py` | Agent + task + crew | 1 decorator on the tool |
| `app.py` | HTTP API: `POST /chat`, `GET /healthz` | `start("crewai")`, `run_turn()` |

## How Saf3AI hooks in

| Layer | What it does |
|---|---|
| `start("crewai")` | SDK detects CrewAI and adds a span per crew run |
| `run_turn()` in `/chat` | Traces the turn, scans the user message and the reply; a blocked prompt returns **403 before the crew starts** |
| `@saf3ai_setup.traced_tool` | A span per tool call, inside the turn |


## Run locally

```bash
pip install -r requirements.txt
cp .env.example .env          # SAF3AI_* + OPENAI_API_KEY (or another CrewAI model)
uvicorn app:app --port 8080
curl -s localhost:8080/chat -H "Content-Type: application/json" -d '{"message":"Where is my order 4211?"}'
```

## Deploy

Any container target in `../../deploy/` (same image contract as `agent/`: `$PORT`, `/healthz`).

## Notes

- Keep `OTEL_SDK_DISABLED` unset: it switches off OpenTelemetry, and with it Saf3AI tracing. Use `CREWAI_DISABLE_TELEMETRY` / `CREWAI_TRACING_ENABLED` (in `.env.example`) for CrewAI's own telemetry.
- Stateless per request, like `agent/`.
- Tested with `crewai` 1.15.22 and `saf3ai-sdk` 0.2.4.
