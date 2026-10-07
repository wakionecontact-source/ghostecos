import asyncio
from types import SimpleNamespace
import agent_stream

class FakeStream:
    def __init__(self):
        self.parts = ["Йо", ", снова", " на связи", " 😎"]
    def __aiter__(self):
        self._i = 0
        return self
    async def __anext__(self):
        if self._i >= len(self.parts):
            raise StopAsyncIteration
        part = self.parts[self._i]
        self._i += 1
        return SimpleNamespace(
            usage=None,
            choices=[SimpleNamespace(
                finish_reason="stop" if self._i == len(self.parts) else None,
                delta=SimpleNamespace(content=part, tool_calls=[], reasoning=None),
            )],
        )
    async def close(self):
        return None

async def main():
    seen = []
    async def on_content(value):
        seen.append(value)
    result = await agent_stream.collect_completion(
        lambda **kwargs: FakeStream(),
        {},
        on_content=on_content,
    )
    assert seen == [
        "Йо",
        "Йо, снова",
        "Йо, снова на связи",
        "Йо, снова на связи 😎",
    ], seen
    assert result.choices[0].message.content == "Йо, снова на связи 😎"
    print("PASS: agent stream delivers cumulative final text")

asyncio.run(main())
