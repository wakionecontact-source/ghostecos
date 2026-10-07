"""Collect OpenAI-compatible streaming completions, exposing only provider-returned
public reasoning/text and preserving fragmented tool-call arguments.

The result has the ordinary ChatCompletion fields expected by GhoGemo's agent,
so streaming does not change tool authorization, action ordering or side effects.
"""
from __future__ import annotations

import inspect
import re
from types import SimpleNamespace
from typing import Callable, Any


def _field(record: Any, key: str, default=None):
    if isinstance(record, dict):
        return record.get(key, default)
    return getattr(record, key, default)


def _reasoning_parts(delta):
    for key in ("reasoning_content", "reasoning", "thinking"):
        content=_field(delta,key)
        if isinstance(content,str) and content:
            return content
    # Public, unencrypted reasoning text, if OpenRouter-style details contain it.
    parts=[]
    for part in _field(delta,"reasoning_details",[]) or []:
        kind=_field(part,"type")
        if kind in ("reasoning.text","reasoning.summary","reasoning_text"):
            text=_field(part,"text")
            if isinstance(text,str) and text:
                parts.append(text)
    return "\n".join(parts)


_THINK_OPEN=re.compile(r"<(think|thinking|thought|reasoning)>",re.IGNORECASE)
_THINK_MARKERS=("<think>","<thinking>","<thought>","<reasoning>")


def _without_partial_marker(value: str, markers: tuple[str,...]) -> str:
    """Keep unfinished <think> markers out of the final-answer preview."""
    lower=value.lower()
    for count in range(min(len(value), max(map(len,markers))-1),0,-1):
        if any(mark.startswith(lower[-count:]) for mark in markers):
            return value[:-count]
    return value


def _split_visible_thinking_stream(raw: str) -> tuple[str,str]:
    """Split cumulative text containing zero or more (possibly open) think tags."""
    visible=[]
    thoughts=[]
    pos=0
    while pos<len(raw):
        match=_THINK_OPEN.search(raw,pos)
        if match is None:
            visible.append(_without_partial_marker(raw[pos:],_THINK_MARKERS))
            break
        visible.append(raw[pos:match.start()])
        close_marker=f"</{match.group(1)}>".lower()
        close=re.search(re.escape(close_marker),raw[match.end():],re.I)
        if close is None:
            thoughts.append(_without_partial_marker(
                raw[match.end():],(close_marker,)
            ))
            break
        thoughts.append(raw[match.end():match.end()+close.start()])
        pos=match.end()+close.end()
    return "".join(visible),"".join(thoughts)


async def _deliver(callback, value):
    outcome=callback(value)
    if inspect.isawaitable(outcome):
        await outcome


async def collect_completion(create: Callable[...,Any], kwargs: dict,
                             *, on_reasoning=None, on_content=None):
    """Use streaming when supported; close stream even on task cancellation.

    If a mocked/non-streaming provider returns a regular ChatCompletion,
    leave it unchanged. Explicit stream-not-supported API errors are surfaced
    to the existing agent fallback handlers, not swallowed here.
    """
    response=create(**{**kwargs,"stream":True})
    if inspect.isawaitable(response):
        response=await response
    if not hasattr(response,"__aiter__"):
        return response
    text=[]
    tagged_reason_sent=0
    reasoning_delivered=False
    tool_fragments={}
    finish_reason=None
    usage=None
    try:
        async for chunk in response:
            if _field(chunk,"usage") is not None:
                usage=_field(chunk,"usage")
            choices=_field(chunk,"choices",[]) or []
            if not choices:
                continue
            choice=choices[0]
            if _field(choice,"finish_reason") is not None:
                finish_reason=_field(choice,"finish_reason")
            delta=_field(choice,"delta")
            if delta is None:
                continue
            reason=_reasoning_parts(delta)
            if reason and on_reasoning:
                await _deliver(on_reasoning, reason)
                reasoning_delivered=True
            part=_field(delta,"content")
            if isinstance(part,str) and part:
                text.append(part)
                accumulated="".join(text)
                # Publish visible <think> deltas on the same reasoning stream.
                # Cumulative parsing handles tags split across network chunks.
                visible,tagged_thought=_split_visible_thinking_stream(
                    accumulated
                )
                if on_reasoning and len(tagged_thought)>tagged_reason_sent:
                    await _deliver(on_reasoning, tagged_thought[tagged_reason_sent:])
                    reasoning_delivered=True
                tagged_reason_sent=max(tagged_reason_sent,len(tagged_thought))
                if on_content and visible.strip():
                    await _deliver(on_content, visible)
            for tool in _field(delta,"tool_calls",[]) or []:
                idx=_field(tool,"index",0)
                if idx is None:
                    idx=0
                entry=tool_fragments.setdefault(
                    int(idx),{"id":"","name":"","arguments":""}
                )
                tid=_field(tool,"id")
                if tid:
                    entry["id"]+=str(tid)
                func=_field(tool,"function")
                if func is not None:
                    name=_field(func,"name")
                    args=_field(func,"arguments")
                    if name:
                        entry["name"]+=str(name)
                    if args:
                        entry["arguments"]+=str(args)
    finally:
        close=getattr(response,"close",None)
        if close:
            result=close()
            if inspect.isawaitable(result):
                await result
    tools=[
        SimpleNamespace(
            id=value["id"] or f"stream_tool_{index}",
            function=SimpleNamespace(
                name=value["name"],
                arguments=value["arguments"] or "{}",
            ),
        )
        for index,value in sorted(tool_fragments.items())
    ]
    message=SimpleNamespace(
        content="".join(text),
        tool_calls=tools,
        reasoning_content=None,
    )
    return SimpleNamespace(
        choices=[SimpleNamespace(finish_reason=finish_reason,message=message)],
        usage=usage,
        _reasoning_streamed=reasoning_delivered,
    )
