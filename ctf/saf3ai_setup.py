"""
Everything Saf3AI-specific in the CTF lives in this one file.

  check()        - stop early, with a clear message, when the key or the network is wrong.
  start()        - call once at process start, BEFORE any LLM client is created.
  run_turn()     - wraps one agent turn: traces it, scans the player's message and
                   enforces the verdict before the LLM is called.
  traced_tool()  - decorator that records each tool call as a span.

Differs from agent-variants/langchain/saf3ai_setup.py:
  - enforcement is chosen per turn, because each CTF level sets its own
    ("monitor" = detect and record, "block" = stop the turn);
  - run_turn() also returns what Saf3AI flagged, so the player page can show it;
  - check() tests the API key against the collector and exits with a clear message.

Tested with saf3ai-sdk 0.2.4 (PyPI) and langchain 1.4.
"""
import functools
import json
import logging
import os
import threading
import urllib.error
import urllib.request
from typing import Callable, Optional, Tuple

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

log = logging.getLogger("ctf.saf3ai")


class _HideBlockNotices(logging.Filter):
    """The SDK logs every blocked or failed turn as an error; app.py already records both."""

    def filter(self, record):
        return not record.getMessage().startswith("Error in agent_turn")


# Keep SDK logging quiet unless debugging (SAF3AI_LOG_LEVEL=INFO for detail).
_sdk_log = logging.getLogger("saf3ai_sdk")
_sdk_log.setLevel(os.getenv("SAF3AI_LOG_LEVEL", "ERROR").upper())
_sdk_log.addFilter(_HideBlockNotices())


def setting(name: str, default: str = "") -> str:
    """An environment variable, cleaned of what copy-paste and Windows editors add:
    surrounding spaces and quotes, carriage returns and other control characters."""
    value = "".join(ch for ch in os.getenv(name, "") if ch.isprintable()).strip().strip("'\"").strip()
    return value or default


AGENT_ID = setting("SAF3AI_AGENT_ID", "saf3ai-ctf-shopbot")
API_KEY = setting("SAF3AI_API_KEY")
COLLECTOR = setting("SAF3AI_COLLECTOR_AGENT", "https://analyzer.saf3ai.com/v1/traces")
SCANNER = setting("SAF3AI_SCANNER_ENDPOINT", "https://scanner.saf3ai.com")
FAIL_MODE = setting("SAF3AI_FAIL_MODE", "open").lower()           # open | closed

_SCAN_FAILED = {"error", "timeout", "auth_error"}

# One turn at a time per process keeps each turn's conversation and user
# attribution exact. turns.py scales out by running a pool of processes.
_turn_lock = threading.Lock()


class PolicyBlocked(Exception):
    """Raised when the Saf3AI verdict blocks a prompt or a response."""

    def __init__(self, stage: str, reasons: list):
        super().__init__(f"Blocked by Saf3AI policy at {stage}: {', '.join(reasons)}")
        self.stage = stage
        self.reasons = reasons


def _check_key() -> Optional[int]:
    """HTTP status from the Saf3AI collector for this key (None = no connection).
    The collector authenticates the key; an empty batch writes nothing."""
    req = urllib.request.Request(COLLECTOR, data=b"", method="POST", headers={
        "Content-Type": "application/x-protobuf", "User-Agent": "saf3ai-ctf/1.0",
        "X-API-Key": API_KEY, "Authorization": f"Bearer {API_KEY}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except (urllib.error.URLError, OSError):
        return None


def check() -> None:
    """Stop with a clear message if the API key is missing or rejected, or the
    collector cannot be reached. Does not initialise the SDK."""
    if not API_KEY:
        raise SystemExit("Saf3AI: SAF3AI_API_KEY is empty (e.g. docker run -e SAF3AI_API_KEY=...). "
                         "Get the key in the Saf3AI console > Integrations > SDK > Custom Agent SDK.")
    status = _check_key()
    if status in (401, 403):
        raise SystemExit(f"Saf3AI: the SAF3AI_API_KEY was rejected (HTTP {status}). Copy the key again "
                         "from the Saf3AI console and paste it with no spaces or quotes.")
    if status is None:
        raise SystemExit(f"Saf3AI: cannot reach {COLLECTOR}. This host needs outbound HTTPS "
                         "(port 443) to the Saf3AI collector and scanner.")


def start(expected_framework: str = "langchain") -> None:
    """Initialise the Saf3AI SDK. Call once per process, before creating any LLM client."""
    check()
    init(
        agent_id=AGENT_ID,
        api_key=API_KEY,
        safeai_collector_agent=COLLECTOR,
        service_name=setting("SAF3AI_SERVICE_NAME", AGENT_ID),
        environment=setting("SAF3AI_ENVIRONMENT", "production"),
        scanner_endpoint=SCANNER or None,
    )
    framework = get_detected_framework()
    if framework != expected_framework:
        # Detection is by installed package (google-adk -> crewai -> langchain-core).
        log.warning("Saf3AI detected framework '%s' but this agent expects '%s' - check the "
                    "packages installed in this image.", framework, expected_framework)
    log.info("Saf3AI ready: agent=%s framework=%s fail_mode=%s", AGENT_ID, framework, FAIL_MODE)


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


_SCAN_KEYS = ("status", "detection_results", "custom_rule_matches", "OutofScopeAnalysis",
              "threats", "categories", "scan_metadata")


def _record_scan(stage: str, scan: dict, span) -> None:
    """Attach the scan result to the span: the Saf3AI console reads it for the matched
    rules, threat category, severity and scan time."""
    if span is None or not span.is_recording():
        return
    key = "security.scan" if stage == "prompt" else "security.response_scan"
    payload = json.dumps(scan, default=str)
    if len(payload) > 16000:  # keep valid JSON: drop bulky extras rather than truncate
        payload = json.dumps({k: scan[k] for k in _SCAN_KEYS if k in scan}, default=str)
    span.set_attribute(f"{key}.full_results", payload)
    duration = (scan.get("scan_metadata") or {}).get("duration_ms")
    if isinstance(duration, (int, float)):
        span.set_attribute(f"{key}.duration_ms", float(duration))


def _enforce(stage: str, scan: Optional[dict], span, enforcement: str) -> list:
    """Apply the verdict. Returns what was flagged; raises PolicyBlocked in block mode."""
    if not SCANNER:
        return []
    if scan is None or scan.get("status") in _SCAN_FAILED:
        if FAIL_MODE == "closed" and enforcement == "block":
            raise PolicyBlocked(stage, ["scanner_unavailable"])
        log.warning("Saf3AI scan unavailable at %s - allowed (SAF3AI_FAIL_MODE=open)", stage)
        return []
    _record_scan(stage, scan, span)
    hits = findings(scan)
    if not hits:
        return []
    if span is not None and span.is_recording():
        span.set_attribute("security.user_decision", "block" if enforcement == "block" else "allow")
        span.set_attribute(f"security.{stage}_threat_types", ",".join(hits))
    if enforcement == "block":
        if span is not None and span.is_recording():
            span.set_attribute("security.blocked_by", "saf3ai_policy")
            span.set_attribute("security.blocked_before_llm", stage == "prompt")
        raise PolicyBlocked(stage, hits)
    return hits


@traceable(name="agent_turn")
def _traced_turn(message: str, handler: Callable[[str], str], enforcement: str,
                 block_responses: bool, flagged: list) -> str:
    # @traceable has already scanned `message` (the player's text only - never the
    # system prompt) and recorded the verdict on this span. Enforce it BEFORE the
    # LLM is called.
    ctx = get_traceable_context() or {}
    span = ctx.get("span")
    flagged.extend(_enforce("prompt", ctx.get("scan_result"), span, enforcement))

    reply = handler(message)

    # @traceable scans the returned reply and records it for the console. Blocking
    # on the reply needs its own scan first (one extra call).
    if block_responses and SCANNER and reply:
        try:
            result = scan_response(reply, api_endpoint=SCANNER, api_key=API_KEY,
                                   conversation_id=ctx.get("conversation_id"),
                                   metadata={"agent_identifier": AGENT_ID})
        except Exception as exc:  # non-200 from the scanner raises
            log.warning("Saf3AI response scan failed: %s", exc)
            result = None
        _enforce("response", result, span, enforcement)
    return reply


def run_turn(handler: Callable[[str], str], message: str, conversation_id: str,
             user_id: Optional[str] = None, enforcement: str = "block",
             block_responses: bool = False) -> Tuple[str, list]:
    """Run one traced + scanned agent turn -> (reply, what Saf3AI flagged on the prompt).

    enforcement="block":   a flagged prompt raises PolicyBlocked before the LLM is called.
    enforcement="monitor": the turn runs; detections are recorded and returned.
    block_responses=True:  the reply is scanned too, and blocked if flagged (block mode).
    """
    flagged: list = []
    with _turn_lock:
        reset_conversation()
        set_conversation_id_unified(conversation_id, source="agent", force=True)
        set_custom_attributes({"gen_ai.user.id": user_id or "anonymous"})
        reply = _traced_turn(message, handler=handler, enforcement=enforcement,
                             block_responses=block_responses, flagged=flagged)
    return reply, flagged


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
