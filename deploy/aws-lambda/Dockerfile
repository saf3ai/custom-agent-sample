# syntax=docker/dockerfile:1
#
# Lambda image = the unchanged agent image + AWS Lambda Web Adapter (LWA).
# LWA runs as a Lambda extension and forwards Function URL requests to the
# agent's HTTP server on port 8080. The agent code is not modified.
#
# Built by build-and-push.sh, which builds ../../agent first. Needs no build
# context: it is piped in on stdin.

ARG AGENT_IMAGE=saf3ai-sample-agent:latest
FROM ${AGENT_IMAGE}

# Pinned release: https://github.com/aws/aws-lambda-web-adapter/releases/tag/v1.1.0
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter

ENV PORT=8080 \
    AWS_LWA_PORT=8080 \
    AWS_LWA_READINESS_CHECK_PATH=/healthz

# Cold-start launcher: loads the Secrets Manager JSON named by SAF3AI_SECRET_ID
# into the environment, then starts the agent as the base image does.
COPY <<"EOF" /app/lambda_start.py
import json
import os

import boto3
import uvicorn

secret_id = os.environ.get("SAF3AI_SECRET_ID")
if secret_id:
    secret = boto3.client("secretsmanager").get_secret_value(SecretId=secret_id)
    os.environ.update({k: str(v) for k, v in json.loads(secret["SecretString"]).items()})

uvicorn.run("app:app", host="127.0.0.1", port=int(os.environ["PORT"]))
EOF

CMD ["python", "/app/lambda_start.py"]
