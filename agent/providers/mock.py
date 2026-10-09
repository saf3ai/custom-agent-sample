"""No-LLM provider for smoke tests: proves the Saf3AI wiring (traces, scanning,
blocking) end to end without any model key or model cost."""


class Provider:
    name = "mock"
    model = "mock-echo"

    def generate(self, system: str, user: str) -> str:
        return f"(mock reply) Thanks for your message - you said: {user}"
