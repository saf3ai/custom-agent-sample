"""
Deploy the Google ADK variant (agent-variants/google-adk) to Vertex AI Agent Engine.

  pip install -r requirements.txt
  python deploy.py create --project MY_PROJECT --location us-central1 \
      --staging-bucket gs://MY_STAGING_BUCKET --api-key-secret saf3ai-api-key
  python deploy.py query  --project MY_PROJECT --location us-central1 \
      --resource RESOURCE_NAME --message "Where is my order 4211?"
  python deploy.py delete --project MY_PROJECT --location us-central1 --resource RESOURCE_NAME

Settings (SAF3AI_*, LLM_MODEL) come from the environment or agent-variants/google-adk/.env.
The Saf3AI API key is passed as a Secret Manager reference, never as plain text.
"""
import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
AGENT_DIR = HERE.parents[1] / "agent-variants" / "google-adk"

# Passed to the deployed runtime as env vars when set locally (non-secret values only)
SETTINGS = [
    "SAF3AI_COLLECTOR_AGENT", "SAF3AI_SCANNER_ENDPOINT", "SAF3AI_AGENT_ID", "SAF3AI_SERVICE_NAME",
    "SAF3AI_ENVIRONMENT", "SAF3AI_ENFORCEMENT", "SAF3AI_BLOCK_RESPONSES", "SAF3AI_FAIL_MODE",
    "SAF3AI_CAPTURE_RESPONSES", "SAF3AI_CLIENT_DATA_CAPTURE", "SAF3AI_LOG_LEVEL", "LLM_MODEL",
]


def _client(args):
    import vertexai
    return vertexai.Client(project=args.project, location=args.location)


def _requirements() -> list:
    lines = (HERE / "requirements.txt").read_text(encoding="utf-8").splitlines()
    return [ln.split("#")[0].strip() for ln in lines if ln.split("#")[0].strip()]


def create(args) -> None:
    from dotenv import load_dotenv
    load_dotenv(AGENT_DIR / ".env")
    for var in ("SAF3AI_COLLECTOR_AGENT", "SAF3AI_SCANNER_ENDPOINT", "LLM_MODEL"):
        if not os.getenv(var):
            sys.exit(f"{var} is not set (LLM_MODEL = a Gemini model id available on Vertex AI "
                     f"in {args.location}).")

    env_vars = {k: os.environ[k] for k in SETTINGS if os.getenv(k)}
    secret, _, version = args.api_key_secret.partition(":")
    env_vars["SAF3AI_API_KEY"] = {"secret": secret, "version": version or "latest"}

    # agent.py initialises Saf3AI at import time - the same happens inside Agent Engine
    # when the runtime loads the agent. Locally the import only builds the agent object,
    # so a placeholder key is enough; the runtime reads the real key from Secret Manager.
    os.environ.setdefault("SAF3AI_API_KEY", "placeholder-for-local-import")
    os.chdir(AGENT_DIR)  # extra_packages are uploaded under the paths given
    sys.path.insert(0, str(AGENT_DIR))
    import agent
    import vertexai
    from vertexai import agent_engines

    vertexai.init(project=args.project, location=args.location, staging_bucket=args.staging_bucket)
    # Leave Google's Agent Engine telemetry off (the default): when it is on, the ADK
    # template replaces the span processors that Saf3AI registers.
    app = agent_engines.AdkApp(agent=agent.root_agent)
    remote = _client(args).agent_engines.create(agent=app, config={
        "display_name": args.display_name,
        "staging_bucket": args.staging_bucket,
        "requirements": _requirements(),
        "extra_packages": ["agent.py", "saf3ai_setup.py"],
        "env_vars": env_vars,
    })
    print(f"Deployed: {remote.api_resource.name}")


def query(args) -> None:
    remote = _client(args).agent_engines.get(name=args.resource)
    for event in remote.stream_query(user_id=args.user_id, message=args.message):
        for part in (event.get("content") or {}).get("parts") or []:
            if part.get("text"):
                print(part["text"])


def delete(args) -> None:
    _client(args).agent_engines.delete(name=args.resource, force=True)
    print(f"Deleted: {args.resource}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("create", "query", "delete"):
        p = sub.add_parser(name)
        p.add_argument("--project", required=True)
        p.add_argument("--location", required=True, help="e.g. us-central1")
        if name == "create":
            p.add_argument("--staging-bucket", required=True, help="gs://... bucket for the upload")
            p.add_argument("--api-key-secret", required=True,
                           help="Secret Manager secret holding the Saf3AI API key: NAME or NAME:VERSION")
            p.add_argument("--display-name", default="saf3ai-support-agent-adk")
        else:
            p.add_argument("--resource", required=True,
                           help="projects/.../locations/.../reasoningEngines/ID (printed by create)")
        if name == "query":
            p.add_argument("--message", required=True)
            p.add_argument("--user-id", default="test-user")
    args = parser.parse_args()
    {"create": create, "query": query, "delete": delete}[args.command](args)


if __name__ == "__main__":
    main()
