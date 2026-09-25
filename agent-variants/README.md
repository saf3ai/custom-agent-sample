# Agent variants

The same retail support agent and HTTP contract as `agent/`, built on four agent frameworks. Each folder is self-contained (`app.py`, `agent.py`, `saf3ai_setup.py`, `requirements.txt`, `Dockerfile`, `.env.example`) with one tool, `get_order_status`, on mock data.

| Framework | How Saf3AI hooks in | What blocks | Deploy with |
|---|---|---|---|
| [Google ADK](google-adk/) | `start("adk")`: agent runs and Gemini calls traced. SDK model callbacks on the agent | `/chat`: `run_turn()` gate, 403 before ADK runs. Agent Engine: `before_model_callback`, refusal reply | Any `../deploy/` target, or `../deploy/gcp-vertex-agent-engine/` |
| [LangChain](langchain/) | `start("langchain")`: chat-model calls traced. SDK callback handler (detection only) + tool spans | `run_turn()` gate, 403 before the agent runs | Any `../deploy/` target |
| [CrewAI](crewai/) | `start("crewai")`: a span per crew run + tool spans | `run_turn()` gate, 403 before the crew starts | Any `../deploy/` target |
| [OpenAI Agents SDK](openai-agents/) | `start("custom")`: turn trace + tool spans | `run_turn()` gate, 403 before the agent runs | Any `../deploy/` target |

## Same in every variant

- `POST /chat` `{"message", "conversation_id?", "user_id?"}` → `200 {"reply", "conversation_id"}` or `403 {"blocked": true, "stage", "reasons"}`; `GET /healthz`; port `$PORT` (8080).
- `SAF3AI_*` settings as in `agent/.env.example`: `SAF3AI_ENFORCEMENT` (block / monitor), `SAF3AI_FAIL_MODE` (open / closed), `SAF3AI_BLOCK_RESPONSES`.
- A blocked prompt never reaches the model.
- Pinned to `saf3ai-sdk==0.2.4`.

## Pick the right folder

- The SDK chooses its integration from the installed packages, in this order: Google ADK → CrewAI → LangChain → custom. Keep one framework per image.
- Framework not listed: use `agent/` and wrap your turn with `run_turn()`.
