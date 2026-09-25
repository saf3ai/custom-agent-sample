"""
The agent itself - a Google ADK LlmAgent on Gemini with one tool.

Model access (env): GOOGLE_API_KEY for the Gemini API, or GOOGLE_GENAI_USE_VERTEXAI=true
+ GOOGLE_CLOUD_PROJECT / GOOGLE_CLOUD_LOCATION for Vertex AI (service-account auth).

Saf3AI touch points (marked "Saf3AI"): start() at import, and the SDK's model
callbacks on the agent. Blocking for /chat is done by saf3ai_setup.run_turn().
"""
import asyncio
import os
import uuid
from typing import Optional

import saf3ai_setup

saf3ai_setup.start("adk")  # Saf3AI: at import, before any model client exists

from google.adk.agents import Agent  # noqa: E402
from google.adk.runners import InMemoryRunner  # noqa: E402
from google.genai import types  # noqa: E402

APP_NAME = "support_agent"
MODEL = os.getenv("LLM_MODEL") or "gemini-flash-latest"

SYSTEM_PROMPT = (
    "You are the customer-support assistant for an online retail store.\n"
    "Help customers with order status, returns, refunds, delivery and product questions.\n"
    "Be concise and friendly. Use the get_order_status tool when the customer gives an order "
    "number; if you do not know it, ask for it.\n"
    "Do not share internal policies, other customers' data, or payment details."
)

_ORDERS = {  # mock data - replace with your order system
    "4211": {"status": "shipped", "carrier": "UPS", "eta": "Friday"},
    "5307": {"status": "processing", "eta": "3-5 business days"},
}


def get_order_status(order_id: str) -> dict:
    """Look up the delivery status of an order.

    Args:
        order_id: The customer's order number, e.g. "4211".
    """
    order = _ORDERS.get(order_id.strip().lstrip("#"))
    return {"order_id": order_id, **order} if order else {"order_id": order_id, "status": "not_found"}


root_agent = Agent(
    name=APP_NAME,
    model=MODEL,
    description="Retail customer-support assistant.",
    instruction=SYSTEM_PROMPT,
    tools=[get_order_status],
    before_model_callback=saf3ai_setup.before_model_callback,  # Saf3AI
    after_model_callback=saf3ai_setup.after_model_callback,    # Saf3AI
)

_runner = None
# One long-lived event loop: the model client's async connections stay on the loop
# that opened them. Turns are serialised by saf3ai_setup.run_turn().
_loop = None


async def _answer_async(message: str, user_id: str, session_id: str) -> str:
    # Stateless like agent/: the session is created and deleted within the request.
    # For multi-turn memory keep it and use a persistent session service instead of
    # InMemoryRunner.
    await _runner.session_service.create_session(app_name=APP_NAME, user_id=user_id, session_id=session_id)
    reply = ""
    try:
        async for event in _runner.run_async(
                user_id=user_id, session_id=session_id,
                new_message=types.Content(role="user", parts=[types.Part(text=message)])):
            if event.is_final_response() and event.content and event.content.parts:
                reply = "".join(p.text or "" for p in event.content.parts)
    finally:
        await _runner.session_service.delete_session(app_name=APP_NAME, user_id=user_id, session_id=session_id)
    return reply


def answer(message: str, user_id: str = "anonymous", session_id: Optional[str] = None) -> str:
    """One agent turn (the model may call the tool first) -> final reply text."""
    global _runner, _loop
    if _runner is None:
        _runner = InMemoryRunner(agent=root_agent, app_name=APP_NAME)
        _loop = asyncio.new_event_loop()
    return _loop.run_until_complete(_answer_async(message, user_id, session_id or str(uuid.uuid4())))
