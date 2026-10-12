FROM python:3.12-slim

LABEL org.opencontainers.image.source="https://github.com/saf3ai/custom-agent-sample" \
      org.opencontainers.image.description="Saf3AI CTF (LangChain). Set SAF3AI_API_KEY, CTF_ADMIN_TOKEN and LLM_PROVIDER with its key; serves the game on $PORT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_PROGRESS_BAR=off \
    PORT=8080 \
    CTF_WORKERS=4 \
    CTF_DATA_DIR=/data \
    SAF3AI_COLLECTOR_AGENT=https://analyzer.saf3ai.com/v1/traces \
    SAF3AI_SCANNER_ENDPOINT=https://scanner.saf3ai.com \
    SAF3AI_ENVIRONMENT=production \
    SAF3AI_FAIL_MODE=open

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

# Run as a non-root user; /data holds the scores (mount a volume to keep them)
RUN useradd --create-home --uid 10001 agent && mkdir -p /data && chown -R agent /app /data
USER 10001
VOLUME /data

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.getenv('PORT','8080'), timeout=4)"

# One web process; it starts CTF_WORKERS worker processes for the agent turns
CMD ["sh", "-c", "exec uvicorn app:app --host 0.0.0.0 --port ${PORT} --workers 1"]
