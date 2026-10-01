# Hugging Face Spaces variant of agent/Dockerfile.
# Differences: Spaces runs the container as uid 1000, so the app is owned by a
# uid-1000 user with a writable HOME. prepare-space.sh copies this over
# agent/Dockerfile in the staging folder; agent/Dockerfile is unchanged.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080

RUN useradd --create-home --uid 1000 user
ENV HOME=/home/user
WORKDIR /home/user/app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY --chown=user . .
USER user

# Must match app_port in README.md
EXPOSE 8080

CMD ["sh", "-c", "exec uvicorn app:app --host 0.0.0.0 --port ${PORT} --workers ${WEB_CONCURRENCY:-1}"]
