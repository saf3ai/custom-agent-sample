# Saf3AI CTF (one hour)

A capture-the-flag built on the LangChain variant. Players attack **ShopBot**, a retail support agent, over five levels.
Each level protects a flag (`FLAG{...}`) with one more layer of defence. Saf3AI scans every level and blocks on the last two.

- **You host it**, in your own AWS account, with your own Saf3AI API key. One organiser, many players.
- **Players need only a browser**, the link and a join code.

## Guides

| Guide | For | What is in it |
|---|---|---|
| [ORGANISER-GUIDE.md](ORGANISER-GUIDE.md) | The person who sets up and runs the event | Prerequisites · setup in your AWS account, command by command · checks · the event script · hints · debrief · removal. Written so an AI assistant can carry it out |
| [PLAYER-GUIDE.md](PLAYER-GUIDE.md) | The players | What they need · how to join and play · what the notices mean · rules · scoring. Send it with the invitation |

## The five levels

| # | Level | Points | What protects the flag | Saf3AI |
|---|---|---|---|---|
| 1 | Unprotected secret | 100 | No control | Monitor |
| 2 | System prompt instruction | 200 | A confidentiality instruction in the system prompt | Monitor |
| 3 | Restricted tool | 300 | A system prompt instruction that restricts a tool to staff | Monitor |
| 4 | Input guardrail | 400 | Level 2, plus a Saf3AI guardrail on the prompt | **Block** |
| 5 | Input and output guardrails | 500 | Hardened system prompt, Saf3AI guardrails on the prompt and the response, and an output check | **Block** |

- **Monitor**: Saf3AI scans the message and records the result. The turn runs, and the player sees what was detected.
- **Block**: a flagged message is stopped before the model is called (HTTP 403).
- Levels 2 and 4 are the same agent. The only difference is the guardrail, so players see its effect directly.
- Levels are open from the start and may be played in any order. Each message is independent (no conversation history).

## What you get

| File | Role | Saf3AI code? |
|---|---|---|
| `saf3ai_setup.py` | Init, scan, enforce per turn, tool tracing | **All of it** |
| `levels.py` | The five levels: system prompts, tools, defences, flags, one agent per level | 1 decorator per tool |
| `app.py` | HTTP API: join, chat, flag, scoreboard, organiser endpoints. Hands each agent turn to a worker | `check()` |
| `turns.py` | The worker processes that run the agent turns, fed from one queue | `start("langchain")`, `run_turn()` |
| `store.py` | Teams, attempts, solves and the event clock (SQLite) | No |
| `static/index.html` | Player page: levels, chat, flag box, scoreboard, clock | No |
| `static/admin.html` | Organiser page: start, stop, reset, answer key, numbers for the debrief | No |
| `aws/start.sh` | On the EC2 instance: build the image, read the settings, start the game | No |
| `aws/preflight.sh` | On the EC2 instance: ten end-to-end checks, then reset | No |

## How Saf3AI hooks in

| Layer | What it does |
|---|---|
| `start("langchain")` | SDK detects LangChain and traces every chat-model call |
| `run_turn(..., enforcement=level.saf3ai)` | Scans the player's message. `block` stops it before the agent runs; `monitor` lets it run and returns what was detected |
| `run_turn(..., block_responses=True)` | Level 5: the response is also scanned, and blocked if flagged |
| `@saf3ai_setup.traced_tool` | A span per tool call, inside the turn |

Each turn is traced to your Saf3AI tenant (console: **Custom Agents → Monitoring → Log Tracer**, agent `SAF3AI_AGENT_ID`) with:

- a conversation id per team and level, so a team's attempts on a level sit together;
- the team name as the user;
- the scan verdict, the threat category, and whether the turn was blocked.

## Run for an event

Follow [ORGANISER-GUIDE.md](ORGANISER-GUIDE.md). It sets up the game on one EC2 instance in your AWS account and covers the event itself.

## Run locally

```bash
pip install -r requirements.txt
cp .env.example .env          # SAF3AI_API_KEY, CTF_ADMIN_TOKEN, LLM_PROVIDER and its key
uvicorn app:app --port 8080 --workers 1
```

Open `http://localhost:8080/admin`, enter the admin token and press **Start**. Players use `http://localhost:8080/`.

As a container, on any host with Docker:

```bash
docker build -t saf3ai-ctf .
docker run -d --name saf3ai-ctf --restart unless-stopped --env-file .env \
  -p 80:8080 -v saf3ai-ctf-data:/data saf3ai-ctf
curl -s localhost/healthz
```

- Scores live in the `saf3ai-ctf-data` volume and survive a restart or a rebuild.
- Run **one** container: the scores are in a local file, not a shared database. For more players, raise `CTF_WORKERS`.

## Settings

| Variable | Needed | Default |
|---|---|---|
| `SAF3AI_API_KEY` | **Yes** | none. The app exits with a clear message if it is missing or rejected |
| `CTF_ADMIN_TOKEN` | **Yes** | none. 12+ characters. Opens `/admin` and the answer key |
| `LLM_PROVIDER` + that provider's key | **Yes** | `google-genai` (`GOOGLE_API_KEY`). Also `openai`, `anthropic`, `bedrock` |
| `LLM_MODEL` | For `openai`, `anthropic`, `bedrock` | `gemini-flash-lite-latest` for `google-genai` |
| `CTF_JOIN_CODE` | Recommended | empty: anyone with the link can join |
| `CTF_FLAG_SEED` | Optional | empty: random flags, kept in the data volume |
| `CTF_MINUTES` | Optional | `60` |
| `CTF_MIN_GAP_SECONDS`, `CTF_MAX_MESSAGES`, `CTF_MAX_CHARS` | Optional | `3`, `200`, `800` (per team) |
| `CTF_MAX_REPLY_TOKENS` | Optional | `400` |
| `CTF_WORKERS` | Optional | `4`: agent turns that run at the same time. Plan one for every three teams |
| `SAF3AI_AGENT_ID`, `SAF3AI_FAIL_MODE` | Optional | `saf3ai-ctf-shopbot`, `open` |

On Bedrock there is no LLM key: the host's AWS role needs `bedrock:InvokeModel` on the model. In a container on EC2 the instance metadata hop limit must be 2 so the container can use the role.

## Notes

- **Flags.** One per level, different on every deployment. The answer key is on `/admin`. Flags are accepted with or without the `FLAG{}` wrapper.
- **Model.** How hard each level is depends on the model. The levels were tuned on Amazon Nova 2 Lite (Bedrock), where levels 1 to 3 are solvable with well-known techniques and levels 4 and 5 are difficult. Rehearse the levels on your model before the event.
- **Console access.** Traces include the system prompts, and so the flags. Keep console access to organisers until the event is over.
- **Stored data.** Each player message is kept in the data volume with its team and outcome, for the debrief. **Reset** deletes it.
- **Limits.** The per-team limits cap what the event can spend on the model. Keep a join code on any public address.
- **Room size.** Tested on EC2 with 20 teams playing at once on 8 workers. For a larger room, rehearse first.
- **Solutions** are not in this repository. The organiser guide has hints.
- Tested with `langchain` 1.4.3 and `saf3ai-sdk` 0.2.4, as a container on EC2 (Amazon Linux 2023) with `LLM_PROVIDER=bedrock`.
