"""
HTTP entrypoint - the same contract as agent/ and every other variant.

  POST /chat     {"message": "...", "conversation_id": "optional", "user_id": "optional"}
                 200 -> {"reply": "...", "conversation_id": "..."}
                 403 -> {"blocked": true, "stage": "prompt|response", "reasons": [...]}
  GET  /healthz  liveness/readiness probe

Run locally:  uvicorn app:app --port 8080
"""
import logging
import os
import uuid
from typing import Optional

from dotenv import load_dotenv

load_dotenv()  # no-op in the cloud, where env vars / secrets are injected

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")

import saf3ai_setup  # noqa: E402

saf3ai_setup.start("crewai")  # must run before the crew and its LLM are created

from fastapi import FastAPI  # noqa: E402
from fastapi.responses import JSONResponse  # noqa: E402
from pydantic import BaseModel  # noqa: E402

import agent  # noqa: E402  (builds the crew)

app = FastAPI(title="Saf3AI sample agent (CrewAI)")


class ChatRequest(BaseModel):
    message: str
    conversation_id: Optional[str] = None
    user_id: Optional[str] = None


@app.get("/healthz")
def healthz():
    return {"status": "ok", "framework": "crewai", "model": agent.MODEL}


@app.post("/chat")
def chat(req: ChatRequest):
    conversation_id = req.conversation_id or str(uuid.uuid4())
    try:
        reply = saf3ai_setup.run_turn(agent.answer, req.message, conversation_id, req.user_id)
    except saf3ai_setup.PolicyBlocked as blocked:
        return JSONResponse(status_code=403, content={
            "blocked": True,
            "stage": blocked.stage,
            "reasons": blocked.reasons,
            "conversation_id": conversation_id,
        })
    except Exception as exc:  # the LLM provider (or a tool) failed; the Saf3AI scan already ran
        logging.getLogger("agent").warning("LLM call failed: %s", str(exc)[:300])
        return JSONResponse(status_code=502, content={
            "error": "llm_unavailable",
            "detail": str(exc)[:300],
            "conversation_id": conversation_id,
        })
    return {"reply": reply, "conversation_id": conversation_id}
