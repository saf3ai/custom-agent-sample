"""Chat with the agent in a terminal - same Saf3AI path as the HTTP service.

    python cli.py
"""
import logging
import uuid

from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(level=logging.WARNING)

import saf3ai_setup  # noqa: E402

saf3ai_setup.start()

import agent  # noqa: E402

if __name__ == "__main__":
    conversation_id = str(uuid.uuid4())
    print(f"Agent ready ({agent.provider.name} / {agent.provider.model}). Ctrl+C to exit.")
    while True:
        try:
            message = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not message:
            continue
        try:
            print(saf3ai_setup.run_turn(agent.answer, message, conversation_id))
        except saf3ai_setup.PolicyBlocked as blocked:
            print(f"[blocked by Saf3AI at {blocked.stage}: {', '.join(blocked.reasons)}]")
