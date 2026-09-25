---
title: Saf3AI Sample Agent
colorFrom: blue
colorTo: gray
sdk: docker
app_port: 8080
pinned: false
short_description: Sample agent instrumented with the Saf3AI SDK
---

# Saf3AI Sample Agent

An HTTP agent instrumented with the Saf3AI SDK. Every turn is traced, and the user message is scanned before the LLM is called.

| Endpoint | Request | Response |
|---|---|---|
| `POST /chat` | `{"message": "...", "conversation_id": "optional", "user_id": "optional"}` | `200 {"reply", "conversation_id"}` or `403 {"blocked": true, "stage", "reasons"}` |
| `GET /healthz` | none | `200` |

Configuration is set in this Space's **Settings → Variables and secrets**. No keys are stored in this repository.
