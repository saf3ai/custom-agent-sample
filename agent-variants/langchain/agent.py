"""
The agent itself - a LangChain tool-calling agent (langchain.agents.create_agent)
with one tool. Saf3AI touch point (marked "Saf3AI"): the tool is wrapped so each
call is traced. app.py passes the Saf3AI callback handler in.

LLM_PROVIDER picks the chat model: google-genai | openai | anthropic.
"""
import os
from typing import Optional

from langchain.agents import create_agent
from langchain.chat_models import init_chat_model
from langchain_core.tools import tool

import saf3ai_setup

# LLM_PROVIDER -> (LangChain provider, default model; None = LLM_MODEL required)
PROVIDERS = {
    "google-genai": ("google_genai", "gemini-flash-latest"),   # GOOGLE_API_KEY
    "openai": ("openai", None),                                # OPENAI_API_KEY
    "anthropic": ("anthropic", "claude-opus-5"),               # ANTHROPIC_API_KEY
}

PROVIDER = (os.getenv("LLM_PROVIDER") or "google-genai").strip().lower()
if PROVIDER not in PROVIDERS:
    raise ValueError(f"LLM_PROVIDER='{PROVIDER}' is not one of: {', '.join(PROVIDERS)}")
_LC_PROVIDER, _DEFAULT_MODEL = PROVIDERS[PROVIDER]
MODEL = os.getenv("LLM_MODEL") or _DEFAULT_MODEL
if not MODEL:
    raise ValueError(f"LLM_MODEL is required for LLM_PROVIDER={PROVIDER}")

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


@tool
@saf3ai_setup.traced_tool  # Saf3AI
def get_order_status(order_id: str) -> dict:
    """Look up the delivery status of an order by the customer's order number, e.g. "4211"."""
    order = _ORDERS.get(order_id.strip().lstrip("#"))
    return {"order_id": order_id, **order} if order else {"order_id": order_id, "status": "not_found"}


llm = init_chat_model(MODEL, model_provider=_LC_PROVIDER)
graph = create_agent(llm, tools=[get_order_status], system_prompt=SYSTEM_PROMPT)


def answer(message: str, callbacks: Optional[list] = None) -> str:
    """One agent turn (the model may call the tool first) -> final reply text.

    Stateless like agent/. For memory, compile the agent with a checkpointer and
    pass {"configurable": {"thread_id": conversation_id}}.
    """
    result = graph.invoke({"messages": [{"role": "user", "content": message}]},
                          config={"callbacks": callbacks or []})
    return result["messages"][-1].text
