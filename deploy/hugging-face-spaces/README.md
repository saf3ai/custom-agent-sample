# Hugging Face Spaces (Docker)

Runs the agent as a private Docker Space. Suited to demos and PoCs. Run commands from `deploy/hugging-face-spaces/`.

## Before you start

| Need | Note |
|---|---|
| A Hugging Face plan that allows Docker Spaces | Per Hugging Face: PRO (personal) or Team / Enterprise (organisation) |
| HF access token, **write** | For `git push` to the Space |
| HF access token, **read** | To call the private Space with curl |
| Saf3AI API key | Saf3AI console > Integrations > SDK > Custom Agent SDK |
| LLM access | Natural fit: `LLM_PROVIDER=huggingface` + `HF_TOKEN` (a token with Inference Providers permission). Any provider in `agent/.env.example` works |

## What's here

| File | Purpose |
|---|---|
| `space/README.md` | Space card. Its YAML front-matter **is** the Space config (`sdk: docker`, `app_port: 8080`) |
| `space/Dockerfile` | Spaces variant of `agent/Dockerfile`: runs as uid 1000 (Spaces requirement) with a writable `HOME` |
| `prepare-space.sh` | Copies `agent/` + the two files above into your Space clone. Skips `.env` files and refuses to run if one is present |

## Steps

1. **Create the Space:** [huggingface.co/new-space](https://huggingface.co/new-space) → SDK **Docker** → **Blank** → visibility **Private**.
2. **Settings → Variables and secrets.** Both reach the container as environment variables at runtime.

   | Type | Name | Value |
   |---|---|---|
   | Secret | `SAF3AI_API_KEY` | Your Saf3AI API key |
   | Secret | `HF_TOKEN` | LLM token (or the key var for your provider, e.g. `OPENAI_API_KEY`) |
   | Variable | `SAF3AI_COLLECTOR_AGENT` | `https://analyzer.saf3ai.com/v1/traces` |
   | Variable | `SAF3AI_SCANNER_ENDPOINT` | `https://scanner.saf3ai.com` |
   | Variable | `SAF3AI_AGENT_ID`, `SAF3AI_SERVICE_NAME` | e.g. `sample-support-agent` |
   | Variable | `SAF3AI_ENVIRONMENT` | e.g. `production` |
   | Variable | `SAF3AI_ENFORCEMENT` | `block` or `monitor` |
   | Variable | `SAF3AI_FAIL_MODE` | `open` or `closed` |
   | Variable | `LLM_PROVIDER` | `huggingface` |
   | Variable | `LLM_MODEL` | A Hub model id whose model page lists an inference provider |

   - Put every key or token in **Secrets**. Variables are visible to anyone who can see the Space.
   - Don't create a variable with an empty value. It overrides the agent's defaults.
3. **Stage and push**
   ```bash
   git clone https://huggingface.co/spaces/<HF_USER>/<SPACE_NAME> ~/<SPACE_NAME>    # password = HF write token
   bash prepare-space.sh ~/<SPACE_NAME>
   cd ~/<SPACE_NAME> && git add -A && git commit -m "Deploy Saf3AI sample agent" && git push
   ```
   Run `bash prepare-space.sh` with no argument to stage into `build/space/` and inspect first.
4. **Watch the build:** Space page → **Logs**. Look for `Saf3AI ready`.
5. **Test.** The Space is private, so every call needs your HF read token.
   ```bash
   export HF_READ_TOKEN=<HF_READ_TOKEN>
   curl -s https://<HF_USER>-<SPACE_NAME>.hf.space/healthz -H "Authorization: Bearer $HF_READ_TOKEN"
   curl -s https://<HF_USER>-<SPACE_NAME>.hf.space/chat \
     -H "Authorization: Bearer $HF_READ_TOKEN" -H "Content-Type: application/json" \
     -d '{"message":"Where is my order?"}'
   ```
   - Exact host: Space page **⋮ → Embed this Space**.
   - `200 {"reply", "conversation_id"}` = allowed. `403 {"blocked": true, ...}` = blocked by your Saf3AI policy.

## Notes

| Topic | Note |
|---|---|
| Visibility | Keep the Space **Private**. A public Space exposes `/chat`, and your LLM usage, to anyone |
| Idle sleep | Free CPU hardware sleeps when unused. The first request after that waits for a restart |
| Concurrency | One agent turn at a time per process. Add Variable `WEB_CONCURRENCY=2` to use both CPU Basic vCPUs |
| Egress | Spaces allow outbound 80 / 443 / 8080. The agent needs only 443 (Saf3AI + LLM API) |
| Network hop | Saf3AI scanning adds a network hop per turn. Benchmark in your environment |
| Updates | Re-run `prepare-space.sh`, commit, push. The Space rebuilds. Secret/Variable changes apply on the next restart |

## Teardown

- Space **Settings → Pause** stops compute. **Delete this Space** removes it.
- Revoke the HF tokens you created for this Space.
