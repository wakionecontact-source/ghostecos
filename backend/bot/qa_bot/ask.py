"""CLI: вопрос -> поиск в интернете -> промпт с контекстом -> генерация
-> обрезка до краткого ответа."""

import json
import os
import sys

import torch
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics.pairwise import cosine_similarity
from tokenizers import Tokenizer

from model import GPT, GPTConfig
from search import search_and_extract

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(__file__)
TOKENIZER_FILE = os.path.join(HERE, "tokenizer", "tokenizer.json")
QA_CKPT = os.path.join(HERE, "checkpoints", "model_qa.pt")
PRETRAIN_CKPT = os.path.join(HERE, "checkpoints", "model.pt")
SMALLTALK_FILE = os.path.join(HERE, "data", "smalltalk_qa.jsonl")
KNOWLEDGE_FILE = os.path.join(HERE, "data", "ghostecos_knowledge.txt")
GHOSTECOS_MIN_SIM = 0.08

MAX_NEW_TOKENS = 100
MAX_CONTEXT_CHARS = 1200
# self-consistency: сколько независимых вариантов генерить и голосовать
# между ними. На CPU (T1) дорого — оставляем 1. На GPU (T2) можно
# поднять до 3-5, там это почти бесплатно по времени.
SELF_CONSISTENCY_N = 1


def load_smalltalk_phrases():
    phrases = set()
    if os.path.exists(SMALLTALK_FILE):
        with open(SMALLTALK_FILE, "r", encoding="utf-8") as f:
            for line in f:
                row = json.loads(line)
                phrases.add(row["question"].strip().lower())
    return phrases


SMALLTALK_PHRASES = load_smalltalk_phrases()

# Модель на 15-45М параметров писать код физически не может — для этого
# нужны датасеты кода в терабайты и модели в миллиарды параметров.
# Ловим такие запросы жёстко до генерации, а не надеемся, что модель
# "откажется" сама.
CODE_KEYWORDS = [
    "напиши код", "напиши функцию", "напиши скрипт", "напиши программу",
    "код на python", "код на javascript", "код на java", "код на c++",
    "код на dart", "write code", "write a function", "write a script",
    "html код", "css код", "sql запрос", "регулярное выражение",
    "напиши класс", "напиши метод",
]
CODE_REFUSAL = "Я не умею писать код — я создан для общения и вопросов про GhostEcos."


def is_code_request(question):
    q = question.strip().lower()
    return any(kw in q for kw in CODE_KEYWORDS)


def load_ghostecos_sections():
    if not os.path.exists(KNOWLEDGE_FILE):
        return []
    with open(KNOWLEDGE_FILE, "r", encoding="utf-8") as f:
        text = f.read()
    sections, current, buf = [], None, []
    for line in text.split("\n"):
        if line.startswith("=== ") and line.endswith(" ==="):
            if current:
                sections.append(current + "\n" + "\n".join(buf))
            current = line
            buf = []
        else:
            buf.append(line)
    if current:
        sections.append(current + "\n" + "\n".join(buf))
    return [s.strip() for s in sections if s.strip()]


GHOSTECOS_SECTIONS = load_ghostecos_sections()
if GHOSTECOS_SECTIONS:
    GHOSTECOS_VECTORIZER = TfidfVectorizer()
    GHOSTECOS_MATRIX = GHOSTECOS_VECTORIZER.fit_transform(GHOSTECOS_SECTIONS)
else:
    GHOSTECOS_VECTORIZER = None
    GHOSTECOS_MATRIX = None


GHOSTECOS_KEYWORDS = [
    "ghost", "гост", "экосистем", "аккаунт", "мессенджер", "диктофон",
    "паник", "мультиаккаунт", "лицензия", "roadmap", "roadmap", "сервер",
    "wallet", "кошел", "nft", "gost", "soul", "prem", "экономик",
]


def is_ghostecos_question(question):
    q = question.strip().lower()
    return any(kw in q for kw in GHOSTECOS_KEYWORDS)


def ghostecos_local_search(question, top_k=1):
    """Локальный поиск по базе знаний GhostEcos (TF-IDF) — веб-поиск не
    находит ничего по приватным внутренним фактам проекта, так что для
    таких вопросов используем свою же базу знаний вместо интернета.
    TF-IDF по большим секциям плохо различает "по теме"/"не по теме"
    (например "фотосинтез" получал похожий скор с "как зайти в
    аккаунт"), поэтому сначала фильтруем по ключевым словам — только
    вопросы явно про GhostEcos вообще пробуют локальный поиск."""
    if GHOSTECOS_VECTORIZER is None or not is_ghostecos_question(question):
        return []
    q_vec = GHOSTECOS_VECTORIZER.transform([question])
    sims = cosine_similarity(q_vec, GHOSTECOS_MATRIX).flatten()
    best_idx = sims.argsort()[::-1][:top_k]
    return [GHOSTECOS_SECTIONS[i] for i in best_idx if sims[i] >= GHOSTECOS_MIN_SIM]


def load_model():
    ckpt_path = QA_CKPT if os.path.exists(QA_CKPT) else PRETRAIN_CKPT
    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    cfg: GPTConfig = ckpt["cfg"]
    model = GPT(cfg)
    model.load_state_dict(ckpt["model_state"])
    model.eval()
    print(f"[ask] загружен чекпоинт: {ckpt_path}")
    return model, cfg


def build_prompt(question, context):
    context = context[:MAX_CONTEXT_CHARS]
    return f"Вопрос: {question}\nКонтекст: {context}\nОтвет: "


def answer(model, cfg, tok, question):
    if is_code_request(question):
        return CODE_REFUSAL, 0

    is_smalltalk = question.strip().lower() in SMALLTALK_PHRASES
    n_sources = 0
    context = ""
    if not is_smalltalk:
        ghostecos_hits = ghostecos_local_search(question)
        if ghostecos_hits:
            context = " ".join(ghostecos_hits)
            n_sources = len(ghostecos_hits)
        else:
            try:
                snippets = search_and_extract(question, num_results=3)
            except Exception as e:
                snippets = []
                print(f"[ask] поиск не удался: {e}")
            context = " ".join(s["text"] for s in snippets)
            n_sources = len(snippets)

    prompt = build_prompt(question, context)

    bos_id = tok.token_to_id("<bos>")
    eos_id = tok.token_to_id("<eos>")
    prompt_ids = [bos_id] + tok.encode(prompt).ids
    prompt_ids = prompt_ids[-cfg.block_size:]

    candidates = [_generate_one(model, tok, prompt_ids, eos_id) for _ in range(SELF_CONSISTENCY_N)]
    text = _pick_best(candidates)
    return text, n_sources


def _generate_one(model, tok, prompt_ids, eos_id):
    idx = torch.tensor([prompt_ids], dtype=torch.long)
    out = model.generate(idx, max_new_tokens=MAX_NEW_TOKENS, temperature=0.7, top_k=40)
    new_ids = out[0, len(prompt_ids):].tolist()

    if eos_id in new_ids:
        new_ids = new_ids[:new_ids.index(eos_id)]
    text = tok.decode(new_ids)

    # краткость: обрезаем по первому переводу строки / началу нового "Вопрос:"
    for stop in ["\n", "Вопрос:"]:
        if stop in text:
            text = text.split(stop)[0]
    return text.strip()


def _pick_best(candidates):
    """Self-consistency: генерим несколько вариантов с разной случайностью
    и берём самый частый — на маленькой модели это снижает шум лучше,
    чем попытки заставить модель "думать" (chain-of-thought ей не по
    силам, а голосование по независимым сэмплам — рабочий трюк даже для
    маленьких моделей)."""
    if len(candidates) == 1:
        return candidates[0]
    counts = {}
    for c in candidates:
        counts[c] = counts.get(c, 0) + 1
    return max(counts.items(), key=lambda kv: (kv[1], -len(kv[0])))[0]


def main():
    tok = Tokenizer.from_file(TOKENIZER_FILE)
    model, cfg = load_model()

    print("Бот готов. Пиши вопрос (exit — выход)\n")
    while True:
        q = input("Ты: ").strip()
        if q.lower() in ("exit", "выход"):
            break
        if not q:
            continue
        ans, n = answer(model, cfg, tok, q)
        print(f"AI ({n} источников): {ans}\n")


if __name__ == "__main__":
    main()
