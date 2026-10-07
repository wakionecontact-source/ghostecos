import asyncio, json, os, re, subprocess, time, uuid
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse
from pydantic import BaseModel
TOKEN = os.getenv("CODER_TOKEN", "dev")
COOKIE = os.getenv("QWEN_COOKIE", "")
MODEL = os.getenv("CODER_MODEL", "qwen3.8-max")
API = "https://chat.qwen.ai/api/v2/chat/completions"
app = FastAPI()
