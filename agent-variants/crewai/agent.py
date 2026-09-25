"""
The agent itself - a single-agent CrewAI crew with one tool.

Saf3AI touch point (marked "Saf3AI"): the tool is wrapped so each call is traced.
LLM_MODEL is a CrewAI model string, e.g. "openai/<model>" or "gemini/<model>".
"""
import os

from crewai import LLM, Agent, Crew, Process, Task
from crewai.constants import DEFAULT_LLM_MODEL
from crewai.tools import tool

import saf3ai_setup

MODEL = os.getenv("LLM_MODEL") or DEFAULT_LLM_MODEL  # empty = the CrewAI default

SYSTEM_PROMPT = (
    "You are the customer-support assistant for an online retail store. "
    "You help customers with order status, returns, refunds, delivery and product questions. "
    "You are concise and friendly. You use the get_order_status tool when the customer gives an "
    "order number; if you do not know it, you ask for it. "
    "You never share internal policies, other customers' data, or payment details."
)

_ORDERS = {  # mock data - replace with your order system
    "4211": {"status": "shipped", "carrier": "UPS", "eta": "Friday"},
    "5307": {"status": "processing", "eta": "3-5 business days"},
}


@tool("get_order_status")
@saf3ai_setup.traced_tool  # Saf3AI
def get_order_status(order_id: str) -> dict:
    """Look up the delivery status of an order by the customer's order number, e.g. "4211"."""
    order = _ORDERS.get(order_id.strip().lstrip("#"))
    return {"order_id": order_id, **order} if order else {"order_id": order_id, "status": "not_found"}


support_agent = Agent(
    role="Customer support assistant",
    goal="Resolve the customer's question in one helpful reply.",
    backstory=SYSTEM_PROMPT,
    tools=[get_order_status],
    llm=LLM(model=MODEL),
    allow_delegation=False,
    verbose=False,
)

reply_task = Task(
    description="Reply to this customer message:\n\n{message}",
    expected_output="A concise, friendly reply to the customer.",
    agent=support_agent,
)

crew = Crew(agents=[support_agent], tasks=[reply_task], process=Process.sequential, verbose=False)


def answer(message: str) -> str:
    """One crew run (the agent may call the tool first) -> final reply text.

    Stateless like agent/: the crew has no memory between requests.
    """
    return str(crew.kickoff(inputs={"message": message}).raw)
