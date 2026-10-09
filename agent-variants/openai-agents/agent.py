"""
The agent itself - an OpenAI Agents SDK agent (Agent + Runner) with one tool.

Saf3AI touch point (marked "Saf3AI"): the tool is wrapped so each call is traced.
"""
import asyncio
import os

from agents import Agent, Runner, function_tool
from agents.models.default_models import get_default_model

import saf3ai_setup

MODEL = os.getenv("LLM_MODEL") or get_default_model()  # empty = the Agents SDK default

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


@function_tool
@saf3ai_setup.traced_tool  # Saf3AI
def get_order_status(order_id: str) -> dict:
    """Look up the delivery status of an order.

    Args:
        order_id: The customer's order number, e.g. "4211".
    """
    order = _ORDERS.get(order_id.strip().lstrip("#"))
    return {"order_id": order_id, **order} if order else {"order_id": order_id, "status": "not_found"}


support_agent = Agent(name="Support agent", instructions=SYSTEM_PROMPT, model=MODEL,
                      tools=[get_order_status])

# One long-lived event loop instead of Runner.run_sync(): run_sync keeps one loop
# per thread, and the web server's worker threads would then share one async OpenAI
# client across several loops. Turns are serialised by saf3ai_setup.run_turn().
_loop = None


def answer(message: str) -> str:
    """One agent turn (the model may call the tool first) -> final reply text.

    Stateless like agent/. For memory, pass an Agents SDK session keyed on the
    conversation id to Runner.run().
    """
    global _loop
    if _loop is None:
        _loop = asyncio.new_event_loop()
    result = _loop.run_until_complete(Runner.run(support_agent, message))
    return str(result.final_output or "")
