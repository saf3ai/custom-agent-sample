# Vertex AI Agent Engine

Deploys the Google ADK variant (`agent-variants/google-adk`) as a managed Agent Engine agent. No Dockerfile and no `/chat` endpoint: clients call the Agent Engine API (sessions, `stream_query`).

## Prerequisites

| Item | Detail |
|---|---|
| Google Cloud project + region | Vertex AI API enabled |
| Staging bucket | `gs://...`, same region |
| Saf3AI API key in Secret Manager | e.g. secret `saf3ai-api-key` |
| Secret access | Grant `roles/secretmanager.secretAccessor` on that secret to `service-PROJECT_NUMBER@gcp-sa-aiplatform-re.iam.gserviceaccount.com` |
| `agent-variants/google-adk/.env` | `SAF3AI_*` settings, and `LLM_MODEL` = a Gemini model id available on Vertex AI in your region |

## Deploy, test, delete

```bash
pip install -r requirements.txt
python deploy.py create --project MY_PROJECT --location us-central1 \
    --staging-bucket gs://MY_STAGING_BUCKET --api-key-secret saf3ai-api-key
python deploy.py query  --project MY_PROJECT --location us-central1 \
    --resource RESOURCE_NAME --message "Where is my order 4211?"
python deploy.py delete --project MY_PROJECT --location us-central1 --resource RESOURCE_NAME
```

`create` prints `RESOURCE_NAME` (`projects/.../reasoningEngines/ID`).

## How Saf3AI runs inside Agent Engine

| Step | What happens |
|---|---|
| Upload | `deploy.py` pickles `AdkApp(agent=root_agent)` and uploads `agent.py` + `saf3ai_setup.py` as `extra_packages` |
| Start-up | Loading the agent imports `agent.py`, whose first step is `saf3ai_setup.start("adk")`: **Saf3AI initialises at import time**, before any model client exists |
| Settings | `SAF3AI_*` and `LLM_MODEL` go in the `env_vars` option. `SAF3AI_API_KEY` is a Secret Manager reference: `{"secret": NAME, "version": VERSION}` |
| Every model call | `before_model_callback` scans the user's latest message. Blocked: Gemini is not called and the agent replies with a refusal |
| Model replies | `after_model_callback` scans reply text; blocks only with `SAF3AI_BLOCK_RESPONSES=true` |
| Conversations | Recorded per ADK session as `adk_session_<session id>` |

## Differences from the container (`/chat`) deployment

- A blocked turn is a refusal reply, not an HTTP 403.
- `SAF3AI_FAIL_MODE=closed` is not applied: if the scanner is unreachable, the model call goes ahead.
- Traces are per agent run and model call; there is no turn span.
- For exact per-conversation attribution under load, add `"container_concurrency": 1` to the `create` config.

## Notes

- Keep Google's Agent Engine telemetry off (`GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY` unset or `false`, the default). When on, the ADK template replaces the span processors Saf3AI registers and Saf3AI traces stop.
- The platform sets `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION` and `PORT` (reserved). Gemini runs through Vertex AI under the agent's service identity; no `GOOGLE_API_KEY`.
- Cost: Agent Engine bills for the compute and memory the deployed agent uses; check Google's current Agent Engine pricing, including minimum instances, before leaving an agent deployed. Cloud Run (`../gcp-cloud-run`) scales to zero. Delete test deployments with `deploy.py delete`.
- On `google-cloud-aiplatform` 2.x, `vertexai.Client` prints a deprecation notice (renamed `agentplatform.Client`, `.runtimes.create`). The call used here works on 1.112+ and 2.x.
