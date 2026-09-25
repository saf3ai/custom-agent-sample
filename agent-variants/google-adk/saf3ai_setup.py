"""
Everything Saf3AI-specific in this agent lives in this one file.

  start()                - call once, BEFORE any LLM client is created (agent.py does it at import).
  run_turn()             - wraps one agent turn: traces it, scans the user message,
                           enforces the verdict before the LLM is called, returns the reply.
  before_model_callback / after_model_callback
                         - the SDK's ADK model callbacks, for the LlmAgent.

Differs from agent/saf3ai_setup.py (Google ADK only):
  - start() is idempotent: agent.py calls it at import time, so Saf3AI is also
    initialised where only the agent module is imported (Vertex AI Agent Engine).
  - run_turn() records the conversation as adk_session_id(conversation_id), i.e.
    "adk_session_<id>", the id format the SDK's ADK integration uses, so each
    session maps to its own conversation in the console.
    app.py uses the same id as the ADK session id, so ADK's own spans match.
    /chat still returns the caller's id unchanged.
  - The model callbacks are new. Inside run_turn() they only record a verdict
    on each model-call span (run_turn has already enforced). Outside run_turn (Agent
    Engine, `adk web`, your own Runner) they enforce SAF3AI_ENFORCEMENT and
    SAF3AI_BLOCK_RESPONSES: a blocked prompt never reaches the model and the agent
    replies with a refusal message instead of an HTTP 403.

Tested with saf3ai-sdk 0.2.4 (PyPI) and google-adk 2.9.
"""
import contextvars
import logging
import os
import threading
from typing import Callable, Optional

from saf3ai_sdk import (
    create_security_callback,
    get_detected_framework,
    init,
    reset_conversation,
    scan_response,
    set_custom_attributes,
    traceable,
)
from saf3ai_sdk.core.traceable import get_traceable_context
from saf3ai_sdk.core.tracer import set_conversation_id_unified

log = logging.getLogger("agent.saf3ai")

# Keep SDK logging quiet unless debugging (SAF3AI_LOG_LEVEL=INFO for detail).
logging.getLogger("saf3ai_sdk").setLevel(os.getenv("SAF3AI_LOG_LEVEL", "WARNING").upper())
# Silence a harmless OpenTelemetry warning about re-ending the ADK agent span.
logging.getLogger("opentelemetry.sdk.trace").setLevel(logging.ERROR)

AGENT_ID = os.getenv("SAF3AI_AGENT_ID", "sample-support-agent")
API_KEY = os.getenv("SAF3AI_API_KEY", "")
SCANNER = os.getenv("SAF3AI_SCANNER_ENDPOINT", "").strip()

ENFORCEMENT = os.getenv("SAF3AI_ENFORCEMENT", "block").lower()      # block | monitor
FAIL_MODE = os.getenv("SAF3AI_FAIL_MODE", "open").lower()           # open | closed
BLOCK_RESPONSES = os.getenv("SAF3AI_BLOCK_RESPONSES", "false").lower() == "true"

_SCAN_FAILED = {"error", "timeout", "auth_error"}
_ADK_PREFIX = "adk_session_"

# One turn at a time per process keeps each turn's conversation and user
# attribution exact. Scale out with more processes (uvicorn --workers N) or
# more replicas.
_turn_lock = threading.Lock()
_started = False
_in_turn = contextvars.ContextVar("saf3ai_in_turn", default=False)


class PolicyBlocked(Exception):
    """Raised when the Saf3AI verdict blocks a prompt or a response."""

    def __init__(self, stage: str, reasons: list):
        super().__init__(f"Blocked by Saf3AI policy at {stage}: {', '.join(reasons)}")
        self.stage = stage
        self.reasons = reasons


def start(expected_framework: str = "adk") -> None:
    """Initialise the Saf3AI SDK once per process. Call before creating any LLM client."""
    global _started
    if _started:
        return
    init(
        agent_id=AGENT_ID,
        api_key=API_KEY,
        safeai_collector_agent=os.environ["SAF3AI_COLLECTOR_AGENT"],
        service_name=os.getenv("SAF3AI_SERVICE_NAME", AGENT_ID),
        environment=os.getenv("SAF3AI_ENVIRONMENT", "production"),
        scanner_endpoint=SCANNER or None,
    )
    _started = True
    framework = get_detected_framework()
    if framework != expected_framework:
        # Detection is by installed package (google-adk -> crewai -> langchain-core),
        # e.g. a stray langchain-core dependency flips a custom agent to "langchain".
        log.warning("Saf3AI detected framework '%s' but this agent expects '%s' - check the "
                    "packages installed in this image.", framework, expected_framework)
    if not SCANNER:
        log.warning("SAF3AI_SCANNER_ENDPOINT is not set - traces only, no scanning or blocking.")
    log.info("Saf3AI ready: agent=%s framework=%s enforcement=%s fail_mode=%s",
             AGENT_ID, framework, ENFORCEMENT, FAIL_MODE)


def findings(scan: Optional[dict]) -> list:
    """Threat names in a scan result (empty list = clean)."""
    if not isinstance(scan, dict):
        return []
    hits = [name for name, r in (scan.get("detection_results") or {}).items()
            if isinstance(r, dict) and r.get("result") == "MATCH_FOUND"]
    threats = scan.get("threats") or {}
    if isinstance(threats, dict):
        hits += [t.get("type") for t in threats.get("items") or []
                 if isinstance(t, dict) and t.get("type")]
    if scan.get("custom_rule_matches"):
        hits.append("custom_guardrail")
    return list(dict.fromkeys(hits))


def _enforce(stage: str, scan: Optional[dict], span) -> None:
    if not SCANNER:
        return
    if scan is None or scan.get("status") in _SCAN_FAILED:
        if FAIL_MODE == "closed":
            raise PolicyBlocked(stage, ["scanner_unavailable"])
        log.warning("Saf3AI scan unavailable at %s - allowed (SAF3AI_FAIL_MODE=open)", stage)
        return
    hits = findings(scan)
    if not hits:
        return
    if span is not None and span.is_recording():
        span.set_attribute("security.user_decision", "block" if ENFORCEMENT == "block" else "allow")
        span.set_attribute(f"security.{stage}_threat_types", ",".join(hits))
    if ENFORCEMENT == "block":
        if span is not None and span.is_recording():
            span.set_attribute("security.blocked_by", "saf3ai_policy")
        raise PolicyBlocked(stage, hits)
    log.warning("Saf3AI flagged %s (%s) - allowed (SAF3AI_ENFORCEMENT=monitor)", stage, ",".join(hits))


@traceable(name="agent_turn")
def _traced_turn(message: str, handler: Callable[[str], str]) -> str:
    # @traceable has already scanned `message` (the user's text only - never the
    # system prompt) and recorded the verdict on this span. Enforce it BEFORE the
    # LLM is called.
    ctx = get_traceable_context() or {}
    span = ctx.get("span")
    _enforce("prompt", ctx.get("scan_result"), span)

    reply = handler(message)

    # @traceable scans the returned reply and records it for the console. Blocking
    # on the reply needs its own scan first (one extra call) - opt in with
    # SAF3AI_BLOCK_RESPONSES=true.
    if BLOCK_RESPONSES and SCANNER and reply:
        try:
            result = scan_response(reply, api_endpoint=SCANNER, api_key=API_KEY,
                                   conversation_id=ctx.get("conversation_id"),
                                   metadata={"agent_identifier": AGENT_ID})
        except Exception as exc:  # non-200 from the scanner raises
            log.warning("Saf3AI response scan failed: %s", exc)
            result = None
        _enforce("response", result, span)
    return reply


def adk_session_id(conversation_id: str) -> str:
    """The id Saf3AI and ADK both record for this conversation ("adk_session_<id>")."""
    return conversation_id if conversation_id.startswith(_ADK_PREFIX) else _ADK_PREFIX + conversation_id


def run_turn(handler: Callable[[str], str], message: str, conversation_id: str,
             user_id: Optional[str] = None) -> str:
    """Run one traced + scanned agent turn. Raises PolicyBlocked when blocked."""
    with _turn_lock:
        reset_conversation()
        set_conversation_id_unified(adk_session_id(conversation_id), source="agent", force=True)
        set_custom_attributes({"gen_ai.user.id": user_id or "anonymous"})
        token = _in_turn.set(True)
        try:
            return _traced_turn(message, handler=handler)
        finally:
            _in_turn.reset(token)


# ------------------------------------------------------------------ ADK model callbacks
def _adk_policy(text: str, scan: dict, stage: str) -> bool:
    """on_scan_complete for the SDK's ADK callbacks. True = let the model call / reply through."""
    if _in_turn.get():
        return True  # run_turn() enforces and answers 403; the callback only records
    if stage == "response" and not BLOCK_RESPONSES:
        return True
    hits = findings(scan)
    if hits and ENFORCEMENT == "block":
        log.warning("Saf3AI blocked %s in model callback: %s", stage, ",".join(hits))
        return False
    return True


_sdk_callbacks = None


def _callbacks():
    # Built on first use, after start(). Module-level wrappers (below) keep the agent
    # picklable by reference for Agent Engine.
    global _sdk_callbacks
    if _sdk_callbacks is None:
        _sdk_callbacks = create_security_callback(
            api_endpoint=SCANNER, api_key=API_KEY, agent_identifier=AGENT_ID,
            on_scan_complete=_adk_policy, scan_responses=True)
    return _sdk_callbacks


def before_model_callback(callback_context, llm_request):
    """ADK before_model_callback: scans the latest user message before each model call."""
    if not SCANNER:
        return None
    if not _in_turn.get():
        # Outside run_turn (e.g. Agent Engine): attribute this invocation to its ADK
        # session and user.
        session = getattr(callback_context, "session", None)
        if session is not None and getattr(session, "id", None):
            set_conversation_id_unified(adk_session_id(session.id), source="adk_session", force=True)
            set_custom_attributes({"gen_ai.user.id": getattr(callback_context, "user_id", None) or "anonymous"})
    return _callbacks()[0](callback_context=callback_context, llm_request=llm_request)


def after_model_callback(callback_context, llm_response):
    """ADK after_model_callback: scans each model reply that contains text."""
    if not SCANNER:
        return None
    content = getattr(llm_response, "content", None)
    if not content or not any(getattr(p, "text", None) for p in content.parts or []):
        return None  # tool-call-only reply: nothing to scan
    return _callbacks()[1](callback_context=callback_context, llm_response=llm_response)
