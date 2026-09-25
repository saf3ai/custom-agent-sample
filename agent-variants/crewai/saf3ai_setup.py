"""
Everything Saf3AI-specific in this agent lives in this one file.

  start()        - call once at process start, BEFORE any LLM client is created.
  run_turn()     - wraps one agent turn: traces it, scans the user message,
                   enforces the verdict before the LLM is called, returns the reply.
  traced_tool()  - decorator that records each tool call as a span.

Differs from agent/saf3ai_setup.py (CrewAI only): adds traced_tool(), which gives
each tool call its own span. start("crewai") turns on the SDK's CrewAI tracing
(a span per crew run). Blocking is done by run_turn(), before the crew starts.

Tested with saf3ai-sdk 0.2.4 (PyPI) and crewai 1.15.
"""
import functools
import json
import logging
import os
import threading
from typing import Callable, Optional

from saf3ai_sdk import (
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

AGENT_ID = os.getenv("SAF3AI_AGENT_ID", "sample-support-agent")
API_KEY = os.getenv("SAF3AI_API_KEY", "")
SCANNER = os.getenv("SAF3AI_SCANNER_ENDPOINT", "").strip()

ENFORCEMENT = os.getenv("SAF3AI_ENFORCEMENT", "block").lower()      # block | monitor
FAIL_MODE = os.getenv("SAF3AI_FAIL_MODE", "open").lower()           # open | closed
BLOCK_RESPONSES = os.getenv("SAF3AI_BLOCK_RESPONSES", "false").lower() == "true"

_SCAN_FAILED = {"error", "timeout", "auth_error"}

# One turn at a time per process keeps each turn's conversation and user
# attribution exact. Scale out with more processes (uvicorn --workers N) or
# more replicas.
_turn_lock = threading.Lock()


class PolicyBlocked(Exception):
    """Raised when the Saf3AI verdict blocks a prompt or a response."""

    def __init__(self, stage: str, reasons: list):
        super().__init__(f"Blocked by Saf3AI policy at {stage}: {', '.join(reasons)}")
        self.stage = stage
        self.reasons = reasons


def start(expected_framework: str = "custom") -> None:
    """Initialise the Saf3AI SDK. Call once, before creating any LLM client.

    expected_framework: "custom" for this agent; the agent-variants pass
    "adk", "langchain" or "crewai".
    """
    init(
        agent_id=AGENT_ID,
        api_key=API_KEY,
        safeai_collector_agent=os.environ["SAF3AI_COLLECTOR_AGENT"],
        service_name=os.getenv("SAF3AI_SERVICE_NAME", AGENT_ID),
        environment=os.getenv("SAF3AI_ENVIRONMENT", "production"),
        scanner_endpoint=SCANNER or None,
    )
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


def run_turn(handler: Callable[[str], str], message: str, conversation_id: str,
             user_id: Optional[str] = None) -> str:
    """Run one traced + scanned agent turn. Raises PolicyBlocked when blocked."""
    with _turn_lock:
        reset_conversation()
        set_conversation_id_unified(conversation_id, source="agent", force=True)
        set_custom_attributes({"gen_ai.user.id": user_id or "anonymous"})
        return _traced_turn(message, handler=handler)


def traced_tool(fn):
    """Decorator for a tool function: records each call as a "tool.<name>" span in the
    current turn. Arguments are recorded; the tool's result is not."""
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        from saf3ai_sdk import get_custom_attributes, get_tracer, tracer
        if not tracer.initialized:
            return fn(*args, **kwargs)
        with get_tracer("saf3ai-tools").start_as_current_span(f"tool.{fn.__name__}") as span:
            for key, value in get_custom_attributes().items():
                if not key.startswith(("client.", "http.")):
                    span.set_attribute(key, value)
            span.set_attribute("tool.name", fn.__name__)
            span.set_attribute("tool.type", "function_call")
            span.set_attribute("tool.args", json.dumps({"args": args, "kwargs": kwargs}, default=str)[:500])
            return fn(*args, **kwargs)
    return wrapper
