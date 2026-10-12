"""
Agent turns run here, in worker processes.

app.py keeps a pool of these processes fed from one queue, so whichever worker is
free takes the next turn. Each worker starts the Saf3AI SDK and builds the five
agents once; after that it runs one turn at a time.
"""
import logging
import os
import time
from typing import Callable, Dict, Optional

import saf3ai_setup

log = logging.getLogger("ctf.turns")
_agents: Optional[Dict[int, Callable[[str], str]]] = None


def init(flags: Dict[int, str]) -> None:
    """Runs once in each worker process, before its first turn."""
    global _agents
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper(),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    saf3ai_setup.start("langchain")  # must run before any LLM client is created

    import levels  # creates the chat model, so it comes after start()
    _agents = levels.build_agents(flags)


def ready() -> int:
    """Warm-up call: keeps this worker busy for a moment so the pool starts the next one."""
    time.sleep(1)
    return os.getpid()


def run(level_id: int, message: str, conversation_id: str, user: str) -> dict:
    """One scanned and traced agent turn -> {"reply", "flagged"}, {"blocked"} or {"error"}."""
    import levels
    level = levels.BY_ID[level_id]
    try:
        reply, flagged = saf3ai_setup.run_turn(
            _agents[level_id], message, conversation_id, user_id=user,
            enforcement=level.saf3ai, block_responses=level.block_responses)
    except saf3ai_setup.PolicyBlocked as blocked:
        return {"blocked": {"stage": blocked.stage, "reasons": blocked.reasons}}
    except Exception as exc:
        log.warning("LLM call failed: %s", str(exc)[:300])
        return {"error": str(exc)[:300]}
    return {"reply": reply, "flagged": flagged}
