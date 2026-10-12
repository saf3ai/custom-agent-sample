"""
Saf3AI CTF - a one-hour capture-the-flag on a LangChain agent protected by Saf3AI.

Players
  GET  /                  player page
  POST /api/join          {"name", "join_code"} or {"team_code"} -> {"team", "team_code"}
  GET  /api/state         event clock, levels, your solves, scoreboard
  POST /api/chat          {"level", "message"}   200 reply | 403 blocked | 429 rate limited
  POST /api/flag          {"level", "flag"}      -> {"correct", ...}
Organiser (header X-Admin-Token)
  GET  /admin             organiser page
  POST /api/admin/start   {"minutes": 60}        POST /api/admin/stop | /api/admin/reset
  GET  /api/admin/flags   the answer key         GET  /api/admin/report   numbers for the debrief
Probe
  GET  /healthz

Run locally:  uvicorn app:app --port 8080 --workers 1
"""
import asyncio
import hmac
import logging
import os
import re
import threading
from concurrent.futures import ProcessPoolExecutor
from concurrent.futures.process import BrokenProcessPool
from contextlib import asynccontextmanager
from multiprocessing import get_context
from typing import Optional

from dotenv import load_dotenv

load_dotenv()  # no-op in the cloud, where env vars / secrets are injected

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("ctf")

import saf3ai_setup  # noqa: E402
from saf3ai_setup import setting  # noqa: E402

ADMIN_TOKEN = setting("CTF_ADMIN_TOKEN")
if len(ADMIN_TOKEN) < 12:
    raise SystemExit("CTF: set CTF_ADMIN_TOKEN to a long random value (12+ characters). "
                     "The organiser page and the answer key are protected by it.")

saf3ai_setup.check()  # stop now if the key or the network is wrong; turns.py starts the SDK

from fastapi import FastAPI, Header  # noqa: E402
from fastapi.concurrency import run_in_threadpool  # noqa: E402
from fastapi.responses import FileResponse, JSONResponse  # noqa: E402
from pydantic import BaseModel  # noqa: E402

import levels  # noqa: E402
import store  # noqa: E402
import turns  # noqa: E402

JOIN_CODE = setting("CTF_JOIN_CODE")                         # empty = anyone with the link can join
MINUTES = float(setting("CTF_MINUTES", "60"))
MIN_GAP = float(setting("CTF_MIN_GAP_SECONDS", "3"))         # per team, between messages
MAX_MESSAGES = int(setting("CTF_MAX_MESSAGES", "200"))       # per team, whole event
MAX_CHARS = int(setting("CTF_MAX_CHARS", "800"))             # per message
FLAG_GAP = 2.0                                               # per team, between flag attempts
WORKERS = max(1, int(setting("CTF_WORKERS", "4")))           # agent turns that run at the same time

store.init()
FLAGS = levels.make_flags(store.flag_seed())

# Agent turns run in a pool of worker processes fed from one queue (turns.py): any free
# worker takes the next turn, whichever player sent it. This process serves the pages.
_pool: Optional[ProcessPoolExecutor] = None
_pool_lock = threading.Lock()


def _turn_pool(replace: Optional[ProcessPoolExecutor] = None) -> ProcessPoolExecutor:
    """The worker pool, created on first use. Pass a broken pool to get a new one."""
    global _pool
    with _pool_lock:
        if _pool is None or _pool is replace:
            _pool = ProcessPoolExecutor(max_workers=WORKERS, mp_context=get_context("spawn"),
                                        initializer=turns.init, initargs=(FLAGS,))
        return _pool


@asynccontextmanager
async def _lifespan(_app):
    # Start every worker before the first player arrives: one warm-up call per worker.
    pool = _turn_pool()
    loop = asyncio.get_running_loop()
    await asyncio.gather(*[loop.run_in_executor(pool, turns.ready) for _ in range(WORKERS)])
    log.info("CTF ready: %d workers, model %s", WORKERS, levels.MODEL)
    yield
    pool.shutdown(wait=False, cancel_futures=True)


_STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9 _.\-]{1,23}")

# FastAPI's own request tracing is off: only agent turns are traced to Saf3AI, not
# every page load and scoreboard refresh. (Older FastAPI versions ignore the option.)
app = FastAPI(title="Saf3AI CTF", docs_url=None, redoc_url=None, openapi_url=None,
              lifespan=_lifespan, telemetry={"tracing": False, "metrics": False, "logs": False})


class JoinRequest(BaseModel):
    name: Optional[str] = None
    join_code: Optional[str] = None
    team_code: Optional[str] = None


class ChatRequest(BaseModel):
    level: int
    message: str


class FlagRequest(BaseModel):
    level: int
    flag: str


class StartRequest(BaseModel):
    minutes: Optional[float] = None


def _error(status: int, error: str, **extra) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": error, **extra})


def _same(given: Optional[str], expected: str) -> bool:
    return hmac.compare_digest((given or "").encode(), expected.encode())


# ---------------------------------------------------------------- pages + probe

@app.get("/", include_in_schema=False)
def player_page():
    return FileResponse(os.path.join(_STATIC, "index.html"), headers={"Cache-Control": "no-store"})


@app.get("/admin", include_in_schema=False)
def organiser_page():
    return FileResponse(os.path.join(_STATIC, "admin.html"), headers={"Cache-Control": "no-store"})


@app.get("/healthz")
def healthz():
    return {"status": "ok", "framework": "langchain", "provider": levels.PROVIDER,
            "model": levels.MODEL, "levels": len(levels.LEVELS), "workers": WORKERS,
            "event": store.event()["status"]}


# ---------------------------------------------------------------- players

@app.post("/api/join")
def join(req: JoinRequest):
    if req.team_code:  # a team-mate, or the same player on another device
        team = store.team_by_code(req.team_code.strip())
        if not team:
            return _error(404, "unknown_team_code")
        return {"team": team["name"], "team_code": team["code"]}
    if JOIN_CODE and not _same((req.join_code or "").strip(), JOIN_CODE):
        return _error(403, "wrong_join_code")
    name = " ".join((req.name or "").split())
    if not _NAME.fullmatch(name):
        return _error(400, "bad_name", detail="2-24 characters: letters, digits, space, _ . -")
    team = store.join(name)
    if not team:
        return _error(409, "name_taken")
    return {"team": team["name"], "team_code": team["code"]}


@app.get("/api/state")
def state(x_team_code: Optional[str] = Header(default=None)):
    team = store.team_by_code(x_team_code or "")
    solved = store.solved_levels(team["id"]) if team else []
    return {
        "event": {k: v for k, v in store.event().items() if k in ("status", "seconds_left")},
        "join_code_required": bool(JOIN_CODE),
        "limits": {"min_gap_seconds": MIN_GAP, "max_messages": MAX_MESSAGES, "max_chars": MAX_CHARS},
        "max_points": levels.MAX_POINTS,
        "levels": [{"id": lv.id, "title": lv.title, "points": lv.points, "brief": lv.brief,
                    "defences": list(lv.defences), "saf3ai": lv.saf3ai, "solved": lv.id in solved}
                   for lv in levels.LEVELS],
        "me": {"team": team["name"], "messages": team["messages"],
               "points": sum(levels.BY_ID[n].points for n in solved)} if team else None,
        "scoreboard": store.scoreboard(),
    }


def _player(team_code: Optional[str], level_id: int):
    """-> (team, level, event, None) or (None, None, None, error response)."""
    team = store.team_by_code(team_code or "")
    if not team:
        return None, None, None, _error(401, "join_first")
    level = levels.BY_ID.get(level_id)
    if not level:
        return None, None, None, _error(404, "unknown_level")
    event = store.event()
    if event["status"] != "running":
        return None, None, None, _error(409, "event_" + event["status"])
    return team, level, event, None


@app.post("/api/chat")
async def chat(req: ChatRequest, x_team_code: Optional[str] = Header(default=None)):
    team, level, event, problem = await run_in_threadpool(_player, x_team_code, req.level)
    if problem:
        return problem
    message = req.message.strip()
    if not message or len(message) > MAX_CHARS:
        return _error(400, "bad_message", detail=f"1-{MAX_CHARS} characters")
    refused = await run_in_threadpool(store.claim_message, team["id"], MIN_GAP, MAX_MESSAGES)
    if refused:
        return JSONResponse(status_code=429, content=refused)

    async def record(outcome: str, detail: str = "") -> None:
        await run_in_threadpool(store.record_attempt, team["id"], level.id, outcome, detail, message)

    # One conversation per team and level, so the console groups a team's attempts.
    conversation_id = f"ctf-{event['event_id']}-{team['id']}-L{level.id}"
    pool = _turn_pool()
    try:
        turn = await asyncio.get_running_loop().run_in_executor(
            pool, turns.run, level.id, message, conversation_id, team["name"])
    except BrokenProcessPool:  # a worker died: start a new pool for the next turn
        log.error("A worker process stopped; starting a new pool")
        _turn_pool(replace=pool)
        turn = {"error": "worker stopped"}

    if "blocked" in turn:
        stage, reasons = turn["blocked"]["stage"], turn["blocked"]["reasons"]
        await record("blocked", f"saf3ai:{stage}:{','.join(reasons)}")
        return JSONResponse(status_code=403, content={
            "blocked": True, "by": "saf3ai", "stage": stage, "reasons": reasons})
    if "error" in turn:  # the LLM provider (or a tool) failed; the Saf3AI scan already ran
        await record("error", turn["error"][:200])
        return _error(502, "llm_unavailable")

    reply, flagged = turn["reply"], turn["flagged"]
    leaked = levels.leaks(reply, FLAGS[level.id])
    if leaked and level.output_check:
        await record("blocked", "reply_check")
        return JSONResponse(status_code=403, content={
            "blocked": True, "by": "reply_check", "stage": "response", "reasons": ["code_in_reply"]})
    await record("leaked" if leaked else "flagged" if flagged else "allowed", ",".join(flagged))
    return {"reply": reply, "flagged": flagged, "saf3ai": level.saf3ai}


@app.post("/api/flag")
def flag(req: FlagRequest, x_team_code: Optional[str] = Header(default=None)):
    team, level, _, problem = _player(x_team_code, req.level)
    if problem:
        return problem
    refused = store.claim_flag(team["id"], FLAG_GAP)
    if refused:
        return JSONResponse(status_code=429, content=refused)
    if not levels.same_flag(req.flag[:200], FLAGS[level.id]):
        return {"correct": False}
    first_time = store.solve(team["id"], level.id, level.points)
    solved = store.solved_levels(team["id"])
    return {"correct": True, "already_solved": not first_time, "points": level.points,
            "total": sum(levels.BY_ID[n].points for n in solved)}


# ---------------------------------------------------------------- organiser

def _is_admin(token: Optional[str]) -> bool:
    return _same(token, ADMIN_TOKEN)


@app.post("/api/admin/start")
def admin_start(req: StartRequest, x_admin_token: Optional[str] = Header(default=None)):
    if not _is_admin(x_admin_token):
        return _error(401, "admin_token_required")
    minutes = req.minutes or MINUTES
    if not 1 <= minutes <= 600:
        return _error(400, "bad_minutes", detail="1-600")
    return store.start(minutes)


@app.post("/api/admin/stop")
def admin_stop(x_admin_token: Optional[str] = Header(default=None)):
    if not _is_admin(x_admin_token):
        return _error(401, "admin_token_required")
    return store.stop()


@app.post("/api/admin/reset")
def admin_reset(x_admin_token: Optional[str] = Header(default=None)):
    if not _is_admin(x_admin_token):
        return _error(401, "admin_token_required")
    return store.reset()


@app.get("/api/admin/flags")
def admin_flags(x_admin_token: Optional[str] = Header(default=None)):
    if not _is_admin(x_admin_token):
        return _error(401, "admin_token_required")
    return {"flags": [{"level": lv.id, "title": lv.title, "points": lv.points, "flag": FLAGS[lv.id]}
                      for lv in levels.LEVELS]}


@app.get("/api/admin/report")
def admin_report(x_admin_token: Optional[str] = Header(default=None)):
    if not _is_admin(x_admin_token):
        return _error(401, "admin_token_required")
    return {"event": store.event(), "agent_id": saf3ai_setup.AGENT_ID, "model": levels.MODEL,
            "scoreboard": store.scoreboard(), **store.report()}
