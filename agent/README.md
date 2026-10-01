# Sample agent

| File | Role | Saf3AI code? |
|---|---|---|
| `saf3ai_setup.py` | Init, scan, enforce | **All of it** |
| `app.py` | HTTP API: `POST /chat`, `GET /healthz` | 2 calls |
| `cli.py` | Terminal chat | 2 calls |
| `agent.py` + `prompts/` | Agent logic + system prompt | None |
| `providers/` | One adapter per LLM | None |

## Add Saf3AI to your own agent

1. `pip install saf3ai-sdk==0.2.4` and copy `saf3ai_setup.py` into your project.
2. At startup, **before** creating any LLM client:
   ```python
   import saf3ai_setup
   saf3ai_setup.start()
   ```
3. Wrap each turn. `your_handler(message) -> str` is your existing code:
   ```python
   try:
       reply = saf3ai_setup.run_turn(your_handler, message, conversation_id, user_id)
   except saf3ai_setup.PolicyBlocked as blocked:
       ...  # return a refusal; blocked.stage / blocked.reasons say why
   ```
4. Set the `SAF3AI_*` variables from `.env.example`.

- Scanning covers the user's message only, never your system prompt.
- If your code imports Google ADK, LangChain or CrewAI, use the matching folder in `../agent-variants/`.

## API

| Request | Response |
|---|---|
| `POST /chat` `{"message": "...", "conversation_id": "optional", "user_id": "optional"}` | `200 {"reply", "conversation_id"}` |
| Blocked turn | `403 {"blocked": true, "stage": "prompt" or "response", "reasons": [...]}` |
| `GET /healthz` | `200 {"status": "ok", "provider", "model"}` |

- Port: `$PORT` (default 8080).
- Concurrency: one turn at a time per process. Scale with `WEB_CONCURRENCY` workers or replicas.
