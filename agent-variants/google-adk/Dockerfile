FROM python:3.12-slim

LABEL org.opencontainers.image.source="https://github.com/saf3ai/custom-agent-sample" \
      org.opencontainers.image.description="Saf3AI sample agent (Google ADK). Set SAF3AI_API_KEY (+ LLM_PROVIDER and its key); serves POST /chat on $PORT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080 \
    SAF3AI_COLLECTOR_AGENT=https://analyzer.saf3ai.com/v1/traces \
    SAF3AI_SCANNER_ENDPOINT=https://scanner.saf3ai.com \
    SAF3AI_ENVIRONMENT=production \
    SAF3AI_ENFORCEMENT=block \
    SAF3AI_FAIL_MODE=open

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

# Run as a non-root user
RUN useradd --create-home --uid 10001 agent && chown -R agent /app
USER 10001

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.getenv('PORT','8080'), timeout=4)"

# PORT is set by the platform where it differs (Cloud Run, App Service, Spaces)
CMD ["sh", "-c", "exec uvicorn app:app --host 0.0.0.0 --port ${PORT} --workers ${WEB_CONCURRENCY:-1}"]
