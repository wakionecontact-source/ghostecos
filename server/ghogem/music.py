"""Music/sound-domain tools owned by GhoGem.

The assistant sees only public GhoSou metadata. Local upload paths are resolved
server-side only when Telegram must send a selected public audio item.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx


GHOSOU_URL = (os.getenv("GHOSOU_URL") or "http://127.0.0.1:8030").rstrip("/")
GHOSOU_DATA = os.getenv("GHOSOU_DATA_PATH") or "/opt/ghosou/ghosou.json"
GHOSOU_PUBLIC_BASE = (os.getenv("GHOSOU_PUBLIC_BASE") or "https://ghostecos.duckdns.org").rstrip("/")
GHOSOU_ROOT = Path(GHOSOU_DATA).resolve().parent
GHOSOU_UPLOADS = (GHOSOU_ROOT / "uploads").resolve()

VALID_KINDS = frozenset({
    "music", "sound", "voice", "podcast", "ambient",
    "loop", "sample", "audiobook", "other",
})
_KIND_ALIASES = {
    "song":"music", "track":"music", "музыка":"music", "трек":"music", "песня":"music",
    "sfx":"sound", "effect":"sound", "fx":"sound", "звук":"sound", "эффект":"sound", "foley":"sound",
    "голос":"voice", "speech":"voice",
    "подкаст":"podcast",
    "ambience":"ambient", "atmosphere":"ambient", "атмосфера":"ambient", "эмбиент":"ambient",
    "луп":"loop",
    "сэмпл":"sample", "sample":"sample",
    "аудиокнига":"audiobook",
}
VALID_SORTS = frozenset({
    "relevance", "plays", "newest", "oldest", "title",
    "duration_short", "duration_long", "bitrate", "random",
})
VALID_TAG_MODES = frozenset({"all", "any"})
VALID_MATCH_MODES = frozenset({"all", "any", "phrase"})
_SEPARATORS = re.compile(r"\s+(?:[-–—]|by|·|—)\s+", re.I)
_PUBLIC_TRACK_KEYS = (
    "ID", "Filename", "Title", "Artist", "Album", "Genre", "Description", "Lyrics",
    "Cover", "Mime", "Slug", "IsAnonymous", "AIEdit", "Status", "Duration", "Size",
    "Plays", "Bitrate", "CreatedAt", "UpdatedAt", "PublishedAt", "Kind",
    "AuthorMode", "AuthorName", "AnonAuthorID", "Genres", "Tags", "Language",
    "SourceType", "License", "LicenseURL", "Visibility", "DownloadAllowed",
    "ModerationStatus", "Revision", "CurrentRevisionID", "RevisionCount",
    "AuthorVerified", "VerifiedAccountID", "VerifiedArtistName",
)


def _text(value: Any) -> str:
    return " ".join(str(value or "").strip().split())


def _fold(value: Any) -> str:
    return " ".join(
        re.sub(r"[\W_]+", " ", _text(value), flags=re.UNICODE).casefold().split()
    )


def _normalize_kind(value: Any) -> str:
    kind=_text(value).casefold()
    return _KIND_ALIASES.get(kind,kind)


def _number(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _bitrate_kbps(value: Any) -> int:
    raw = _text(value).casefold().replace("kbps", "k").replace("кбит/с", "k")
    match = re.search(r"(\d+(?:\.\d+)?)", raw)
    if not match:
        return 0
    number = float(match.group(1))
    if "mb" in raw or "мбит" in raw:
        number *= 1000
    return max(0, int(round(number)))


def _bool_filter(value: Any) -> bool | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return value
    folded = _text(value).casefold()
    if folded in {"1", "true", "yes", "да", "on"}:
        return True
    if folded in {"0", "false", "no", "нет", "off"}:
        return False
    return None


def _parse_datetime(value: Any) -> datetime | None:
    raw=_text(value)
    if not raw or raw.startswith("0001-01-01"):
        return None
    try:
        dt=datetime.fromisoformat(raw.replace("Z","+00:00"))
        if dt.tzinfo is None:
            dt=dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


def _is_publicly_readable(item: dict[str, Any]) -> bool:
    """Published records that may be opened by exact ID/slug."""
    return (
        str(item.get("ModerationStatus") or "") == "published"
        and str(item.get("Visibility") or "") in {"public", "unlisted"}
    )


def _is_searchable(item: dict[str, Any]) -> bool:
    """Records allowed to appear in ordinary catalog/search discovery."""
    return (
        str(item.get("ModerationStatus") or "") == "published"
        and str(item.get("Visibility") or "") == "public"
    )


# Compatibility for older internal callers/tests: readable by exact identifier.
def _is_public(item: dict[str, Any]) -> bool:
    return _is_publicly_readable(item)


def _load_snapshot_rows() -> list[dict[str, Any]]:
    try:
        with open(GHOSOU_DATA, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        rows = list((data.get("t") or {}).values())
        return [row for row in rows if isinstance(row, dict)]
    except (OSError, ValueError, TypeError):
        return []


def _public_urls(item: dict[str, Any]) -> dict[str, str]:
    slug = _text(item.get("Slug"))
    track_id = _text(item.get("ID"))
    cover = _text(item.get("Cover"))
    urls: dict[str, str] = {}
    if slug:
        urls["stream_url"] = f"{GHOSOU_PUBLIC_BASE}/sound/stream/{slug}"
        if bool(item.get("DownloadAllowed")):
            urls["download_url"] = f"{GHOSOU_PUBLIC_BASE}/sound/dl/{slug}"
    if cover and track_id:
        urls["cover_url"] = f"{GHOSOU_PUBLIC_BASE}/sound/covers/{track_id}.jpg"
    return urls


def public_track(item: dict[str, Any]) -> dict[str, Any]:
    """Return only data that the public GhoSou API is allowed to expose."""
    out = {key: item[key] for key in _PUBLIC_TRACK_KEYS if key in item}
    out.update(_public_urls(item))
    return out


def compact_search_match(row: dict[str, Any]) -> dict[str, Any]:
    """Small search result for LLM context; full metadata is fetched on demand."""
    track = row.get("track") if isinstance(row, dict) else None
    if not isinstance(track, dict):
        return {}

    def short(value: Any, limit: int) -> str:
        text = _text(value)
        return text if len(text) <= limit else text[: max(1, limit - 1)] + "…"

    artist = (
        short(track.get("VerifiedArtistName"), 120)
        or short(track.get("Artist"), 120)
        or short(track.get("AuthorName"), 120)
    )
    tags = [short(value, 40) for value in list(track.get("Tags") or [])[:4] if _text(value)]
    out = {
        "id": short(track.get("ID"), 80),
        "slug": short(track.get("Slug"), 120),
        "title": short(track.get("Title"), 180) or short(track.get("Filename"), 180) or "Без названия",
        "artist": artist,
        "kind": short(track.get("Kind"), 24) or "other",
        "duration": round(_number(track.get("Duration"), 0.0), 3),
        "plays": int(_number(track.get("Plays"), 0)),
        "genre": short(track.get("Genre"), 64),
        "tags": tags,
        "downloadable": bool(track.get("DownloadAllowed")),
        "verified": bool(track.get("AuthorVerified")),
    }
    if track.get("Bitrate"):
        out["bitrate"] = short(track.get("Bitrate"), 24)
    if track.get("Language"):
        out["language"] = short(track.get("Language"), 32)
    if track.get("License"):
        out["license"] = short(track.get("License"), 64)
    score = row.get("score") if isinstance(row, dict) else None
    if score not in (None, 0, 0.0):
        out["score"] = score
    return {key: value for key, value in out.items() if value not in ("", [], None)}


def compact_agent_search_payload(payload: dict[str, Any], max_items: int = 12) -> dict[str, Any]:
    """Bounded, valid JSON shape for an agent tool result.

    UI/API consumers can still receive the full public result. The language model
    gets only enough fields to choose a record and can call ghosou_get_track for
    complete metadata. This avoids generic tool-result truncation cutting JSON.
    """
    try:
        max_items = max(1, min(int(max_items or 12), 12))
    except (TypeError, ValueError):
        max_items = 12
    catalog = payload.get("catalog") if isinstance(payload, dict) else None
    compact = [
        item for item in (
            compact_search_match(row) for row in (catalog or [])[:max_items]
        ) if item
    ]
    out: dict[str, Any] = {"catalog": compact}
    if isinstance(payload, dict) and payload.get("web_fallback"):
        out["web_fallback"] = True
    meta = payload.get("catalog_meta") if isinstance(payload, dict) else None
    if isinstance(meta, dict):
        compact_meta = {
            key: meta.get(key)
            for key in (
                "total", "offset", "limit", "has_more", "next_offset",
                "match_mode_used", "relaxed_match",
            )
        }
        facets = meta.get("facets")
        if isinstance(facets, dict):
            compact_facets = {}
            for name, bucket in facets.items():
                if isinstance(bucket, dict):
                    compact_facets[name] = dict(list(bucket.items())[:6])
            if compact_facets:
                compact_meta["facets"] = compact_facets
        summary = meta.get("summary")
        if isinstance(summary, dict):
            compact_meta["summary"] = {
                key: summary.get(key)
                for key in ("matches","total_duration_seconds","downloadable","verified")
                if key in summary
            }
        kinds = meta.get("kinds")
        if isinstance(kinds, dict):
            compact_meta["kinds"] = dict(list(kinds.items())[:8])
        out["catalog_meta"] = compact_meta
    external = payload.get("external") if isinstance(payload, dict) else None
    if external:
        external_text = str(external)
        out["external"] = external_text[:900] + ("…" if len(external_text) > 900 else "")

    # Keep JSON valid under the generic agent tool-result budget. If very long
    # metadata still makes the page too large, shorten the page itself and fix
    # next_offset so a follow-up search never skips unseen rows.
    def encoded_size() -> int:
        return len(json.dumps(out, ensure_ascii=False, default=str))

    while encoded_size() > 5200 and len(out.get("catalog") or []) > 1:
        out["catalog"].pop()
    compact_meta = out.get("catalog_meta")
    if isinstance(compact_meta, dict) and out.get("catalog") is not None:
        returned = len(out.get("catalog") or [])
        try:
            offset = max(0, int(compact_meta.get("offset") or 0))
            total = max(0, int(compact_meta.get("total") or 0))
        except (TypeError, ValueError):
            offset, total = 0, returned
        compact_meta["returned"] = returned
        compact_meta["limit"] = returned
        compact_meta["has_more"] = offset + returned < total
        compact_meta["next_offset"] = offset + returned if offset + returned < total else None
    if encoded_size() > 5200 and "external" in out:
        text = str(out["external"])
        out["external"] = text[:350] + ("…" if len(text) > 350 else "")
    if encoded_size() > 5200 and isinstance(out.get("catalog_meta"), dict):
        out["catalog_meta"].pop("facets", None)
        out["catalog_meta"].pop("kinds", None)
    return out


def normalize_metadata(data: dict[str, Any]) -> dict[str, Any]:
    """Return the public metadata shape. filename is preserved verbatim."""
    try:
        size = int(
            data.get("size") or data.get("original_size") or
            data.get("originalSize") or data.get("Size") or
            data.get("OriginalSize") or 0
        )
    except (TypeError, ValueError):
        size = 0
    return {
        "filename": _text(data.get("filename") or data.get("file_name") or data.get("Filename")),
        "title": _text(data.get("title") or data.get("Title")),
        "artist": _text(data.get("artist") or data.get("Artist")),
        "album": _text(data.get("album") or data.get("Album")),
        "genre": _text(data.get("genre") or data.get("Genre")),
        "description": _text(data.get("description") or data.get("Description")),
        "lyrics": _text(data.get("lyrics") or data.get("Lyrics")),
        "size": size,
    }


def fill_from_filename(data: dict[str, Any]) -> dict[str, Any]:
    """Conservative parser. It suggests values; it never overwrites user input."""
    out = normalize_metadata(data)
    stem = re.sub(r"\.[A-Za-z0-9]{1,8}$", "", out["filename"])
    stem = re.sub(r"[_]+", " ", stem)
    stem = re.sub(r"\s*\((?:official|audio|video|lyrics?)\)\s*$", "", stem, flags=re.I)
    if not out["title"] and stem:
        parts = _SEPARATORS.split(stem, maxsplit=1)
        if len(parts) == 2 and not out["artist"]:
            out["title"], out["artist"] = parts[0].strip(), parts[1].strip()
        else:
            out["title"] = stem.strip()
    out["source"] = "filename"
    out["metadata_only"] = True
    out["questions"] = []
    for field, label in (("title", "название"), ("artist", "исполнитель")):
        if not out[field]:
            out["questions"].append(f"Уточни {label}, чтобы проверить совпадения точнее.")
    return out


def _score(query: dict[str, Any], item: dict[str, Any]) -> tuple[int, list[str]]:
    q = normalize_metadata(query)
    i = normalize_metadata(item)
    score = 0
    reasons: list[str] = []
    query_filename, item_filename = _fold(q["filename"]), _fold(i["filename"])
    if query_filename and item_filename:
        if query_filename == item_filename:
            score += 8
            reasons.append("filename:exact")
        elif query_filename in item_filename or item_filename in query_filename:
            score += 5
            reasons.append("filename:similar")
    for key, weight in (("title", 7), ("artist", 6), ("album", 3), ("genre", 2)):
        a, b = _fold(q[key]), _fold(i[key])
        if not a or not b:
            continue
        if a == b:
            score += weight
            reasons.append(f"{key}:exact")
        elif a in b or b in a:
            score += max(1, weight - 2)
            reasons.append(f"{key}:similar")
    if q["size"] and i["size"]:
        delta = abs(q["size"] - i["size"])
        if delta <= max(1024, int(q["size"] * 0.02)):
            score += 3
            reasons.append("size:similar")
    return score, reasons


async def catalog(limit: int = 500) -> list[dict[str, Any]]:
    rows = _load_snapshot_rows()
    if rows:
        return rows[: max(1, min(int(limit or 500), 500))]
    async with httpx.AsyncClient(timeout=8, trust_env=False) as client:
        response = await client.get(f"{GHOSOU_URL}/sound/api/tracks")
        response.raise_for_status()
        rows = response.json()
    return rows[: max(1, min(int(limit or 500), 500))] if isinstance(rows, list) else []


def _matches_filters(
    item: dict[str, Any], *,
    kind: str = "", title: str = "", artist: str = "", album: str = "", genre: str = "",
    language: str = "", tags: list[str] | None = None, tag_mode: str = "all",
    min_duration: float | None = None, max_duration: float | None = None,
    min_bitrate_kbps: int | None = None, max_bitrate_kbps: int | None = None,
    min_size_kb: float | None = None, max_size_kb: float | None = None,
    min_plays: int | None = None, downloadable: bool | None = None,
    verified: bool | None = None, license: str = "", source_type: str = "",
    published_after: str = "", published_before: str = "",
) -> bool:
    if kind and _text(item.get("Kind")).casefold() != kind.casefold():
        return False
    artist_blob = " ".join(str(item.get(k) or "") for k in (
        "Artist", "AuthorName", "VerifiedArtistName"
    ))
    for haystack, wanted in (
        (item.get("Title"), title),
        (artist_blob, artist),
        (item.get("Album"), album),
        (" ".join([str(item.get("Genre") or ""), *map(str, item.get("Genres") or [])]), genre),
        (item.get("Language"), language),
        (item.get("License"), license),
        (item.get("SourceType"), source_type),
    ):
        if wanted and _fold(wanted) not in _fold(haystack):
            return False

    wanted_tags = [_fold(x) for x in (tags or []) if _fold(x)]
    if wanted_tags:
        item_tags = {
            _fold(x) for x in
            list(item.get("Tags") or []) + list(item.get("Genres") or [])
            if _fold(x)
        }
        matches = [
            any(w == t or w in t or t in w for t in item_tags)
            for w in wanted_tags
        ]
        if (tag_mode == "any" and not any(matches)) or (tag_mode != "any" and not all(matches)):
            return False

    duration = _number(item.get("Duration"), 0.0)
    if min_duration is not None and duration < float(min_duration):
        return False
    if max_duration is not None and duration > float(max_duration):
        return False
    bitrate = _bitrate_kbps(item.get("Bitrate"))
    if min_bitrate_kbps is not None and bitrate < int(min_bitrate_kbps):
        return False
    if max_bitrate_kbps is not None and bitrate > int(max_bitrate_kbps):
        return False
    size_kb=_number(item.get("Size"),0.0)/1024.0
    if min_size_kb is not None and size_kb < float(min_size_kb):
        return False
    if max_size_kb is not None and size_kb > float(max_size_kb):
        return False
    published=_parse_datetime(item.get("PublishedAt") or item.get("CreatedAt"))
    after=_parse_datetime(published_after)
    before=_parse_datetime(published_before)
    if after is not None and (published is None or published < after):
        return False
    if before is not None and (published is None or published > before):
        return False
    if min_plays is not None and int(_number(item.get("Plays"), 0)) < int(min_plays):
        return False
    if downloadable is not None and bool(item.get("DownloadAllowed")) is not downloadable:
        return False
    if verified is not None and bool(item.get("AuthorVerified")) is not verified:
        return False
    return True


async def search_catalog(
    query: str = "",
    metadata: dict[str, Any] | None = None,
    limit: int = 20,
    *,
    offset: int = 0,
    kind: str = "",
    title: str = "",
    artist: str = "",
    album: str = "",
    genre: str = "",
    language: str = "",
    tags: list[str] | None = None,
    tag_mode: str = "all",
    match_mode: str = "all",
    sort: str = "relevance",
    min_duration: float | None = None,
    max_duration: float | None = None,
    min_bitrate_kbps: int | None = None,
    max_bitrate_kbps: int | None = None,
    min_size_kb: float | None = None,
    max_size_kb: float | None = None,
    min_plays: int | None = None,
    downloadable: bool | None = None,
    verified: bool | None = None,
    license: str = "",
    source_type: str = "",
    published_after: str = "",
    published_before: str = "",
) -> list[dict[str, Any]]:
    """Search public GhoSou audio with music/sound-aware filters.

    Returns only public metadata. `offset` paginates after ranking/sorting.
    """
    kind = _normalize_kind(kind)
    if kind and kind not in VALID_KINDS:
        raise ValueError("invalid GhoSou kind")
    sort = _text(sort).casefold() or "relevance"
    if sort not in VALID_SORTS:
        sort = "relevance"
    tag_mode = _text(tag_mode).casefold() or "all"
    if tag_mode not in VALID_TAG_MODES:
        tag_mode = "all"
    match_mode = _text(match_mode).casefold() or "all"
    if match_mode not in VALID_MATCH_MODES:
        match_mode = "all"
    try:
        limit = max(1, min(int(limit or 20), 200))
    except (TypeError, ValueError):
        limit = 20
    try:
        offset = max(0, min(int(offset or 0), 10000))
    except (TypeError, ValueError):
        offset = 0

    downloadable = _bool_filter(downloadable)
    verified = _bool_filter(verified)
    rows = await catalog()
    folded_q = _fold(query)
    terms = folded_q.split()[:20]
    meta = normalize_metadata(metadata or {})
    has_metadata = any(
        meta.get(key)
        for key in ("title", "artist", "album", "genre", "description", "lyrics", "size")
    )
    result: list[dict[str, Any]] = []
    for item in rows:
        if not _is_searchable(item):
            continue
        if not _matches_filters(
            item, kind=kind, title=title, artist=artist, album=album, genre=genre,
            language=language, tags=tags, tag_mode=tag_mode,
            min_duration=min_duration, max_duration=max_duration,
            min_bitrate_kbps=min_bitrate_kbps,
            max_bitrate_kbps=max_bitrate_kbps,
            min_size_kb=min_size_kb, max_size_kb=max_size_kb,
            min_plays=min_plays,
            downloadable=downloadable, verified=verified,
            license=license, source_type=source_type,
            published_after=published_after, published_before=published_before,
        ):
            continue
        blob = _fold(
            " ".join(str(item.get(k, "")) for k in (
                "ID", "Filename", "Slug", "Title", "Artist", "AuthorName",
                "VerifiedArtistName", "Album", "Genre", "Description", "Lyrics",
                "Language", "Kind", "SourceType", "License",
            ))
            + " " + " ".join(str(x) for x in (item.get("Tags") or []))
            + " " + " ".join(str(x) for x in (item.get("Genres") or []))
        )
        if not terms:
            text_match = False
            matched_terms = 0
        elif match_mode == "phrase":
            text_match = folded_q in blob
            matched_terms = len(terms) if text_match else 0
        else:
            matched_terms = sum(1 for term in terms if term in blob)
            text_match = (
                matched_terms == len(terms)
                if match_mode == "all"
                else matched_terms > 0
            )

        if has_metadata:
            score, reasons = _score(meta, item)
        else:
            score, reasons = 0, []
        if text_match:
            # Exact title/artist matches should outrank generic description hits.
            item_title_folded = _fold(item.get("Title"))
            artist_blob = _fold(" ".join(str(item.get(k) or "") for k in (
                "Artist", "AuthorName", "VerifiedArtistName"
            )))
            if folded_q and folded_q == item_title_folded:
                score += 30
                reasons.append("title:query_exact")
            elif folded_q and folded_q in item_title_folded:
                score += 18
                reasons.append("title:query_match")
            if folded_q and folded_q == artist_blob:
                score += 20
                reasons.append("artist:query_exact")
            score += max(1, matched_terms * 3)
            reasons.append("text:match")
        elif match_mode == "any" and matched_terms:
            score += matched_terms
            reasons.append("text:partial")

        if score or text_match or (not folded_q and not has_metadata):
            track = public_track(item)
            result.append({
                "track": track,
                "score": score,
                "reasons": reasons,
            })

    def timestamp(row: dict[str, Any]) -> str:
        track = row["track"]
        return _text(track.get("PublishedAt") or track.get("CreatedAt") or track.get("UpdatedAt"))

    if sort == "plays":
        result.sort(key=lambda x: int(_number(x["track"].get("Plays"), 0)), reverse=True)
    elif sort == "newest":
        result.sort(key=timestamp, reverse=True)
    elif sort == "oldest":
        result.sort(key=timestamp)
    elif sort == "title":
        result.sort(key=lambda x: _fold(x["track"].get("Title")))
    elif sort == "duration_short":
        result.sort(key=lambda x: _number(x["track"].get("Duration"), 0))
    elif sort == "duration_long":
        result.sort(key=lambda x: _number(x["track"].get("Duration"), 0), reverse=True)
    elif sort == "bitrate":
        result.sort(key=lambda x: _bitrate_kbps(x["track"].get("Bitrate")), reverse=True)
    elif sort == "random":
        # Stable pseudo-random order for this query so pagination cannot repeat
        # or skip items merely because page 2 was calculated in another call.
        seed = folded_q or "catalog"
        result.sort(key=lambda x: hashlib.sha256(
            (seed + "|" + _text((x.get("track") or {}).get("ID"))).encode("utf-8")
        ).hexdigest())
    else:
        result.sort(
            key=lambda x: (x["score"], int(_number(x["track"].get("Plays"), 0))),
            reverse=True,
        )
    return result[offset:offset + limit]


async def search_catalog_page(**kwargs) -> dict[str, Any]:
    """Search plus pagination metadata/facets for agent/API consumers.

    For natural-language queries the default strict `all` match is tried first.
    If it returns nothing, one transparent `any` retry is used so the assistant
    can still offer close catalog matches instead of silently giving up.
    """
    offset = max(0, int(kwargs.get("offset") or 0))
    limit = max(1, min(int(kwargs.get("limit") or 20), 200))
    all_kwargs = dict(kwargs)
    all_kwargs["offset"] = 0
    all_kwargs["limit"] = 200
    requested_match_mode = _text(all_kwargs.get("match_mode")).casefold() or "all"
    first = await search_catalog(**all_kwargs)
    relaxed_match = False
    if (
        not first
        and _fold(all_kwargs.get("query"))
        and requested_match_mode == "all"
    ):
        all_kwargs["match_mode"] = "any"
        first = await search_catalog(**all_kwargs)
        relaxed_match = bool(first)

    matches = list(first)
    cursor = len(first)
    while len(first) == 200 and cursor < 500:
        all_kwargs["offset"] = cursor
        first = await search_catalog(**all_kwargs)
        matches.extend(first)
        cursor += len(first)
        if not first:
            break

    page = matches[offset:offset + limit]
    kinds: dict[str, int] = {}
    artists: dict[str, int] = {}
    albums: dict[str, int] = {}
    genres: dict[str, int] = {}
    tags: dict[str, int] = {}
    languages: dict[str, int] = {}
    licenses: dict[str, int] = {}
    source_types: dict[str, int] = {}
    downloadable_count=0
    verified_count=0
    total_duration=0.0

    def bump(bucket: dict[str, int], value: Any):
        name = _text(value)
        if name:
            bucket[name] = bucket.get(name, 0) + 1

    for row in matches:
        track = row.get("track") or {}
        bump(kinds, track.get("Kind") or "other")
        artist=(
            track.get("VerifiedArtistName")
            or track.get("Artist")
            or track.get("AuthorName")
        )
        bump(artists,artist)
        bump(albums,track.get("Album"))
        bump(genres, track.get("Genre"))
        for value in track.get("Genres") or []:
            bump(genres, value)
        for value in track.get("Tags") or []:
            bump(tags, value)
        bump(languages, track.get("Language"))
        bump(licenses, track.get("License"))
        bump(source_types,track.get("SourceType"))
        total_duration+=_number(track.get("Duration"),0.0)
        downloadable_count+=1 if bool(track.get("DownloadAllowed")) else 0
        verified_count+=1 if bool(track.get("AuthorVerified")) else 0

    def top(bucket: dict[str, int], n: int = 20) -> dict[str, int]:
        return dict(sorted(bucket.items(), key=lambda item: (-item[1], item[0].casefold()))[:n])

    return {
        "matches": page,
        "total": len(matches),
        "offset": offset,
        "limit": limit,
        "has_more": offset + len(page) < len(matches),
        "next_offset": offset + len(page) if offset + len(page) < len(matches) else None,
        "match_mode_used": "any" if relaxed_match else requested_match_mode,
        "relaxed_match": relaxed_match,
        "facets": {
            "kinds": top(kinds),
            "artists": top(artists),
            "albums": top(albums),
            "genres": top(genres),
            "tags": top(tags),
            "languages": top(languages),
            "licenses": top(licenses),
            "source_types": top(source_types),
        },
        "summary": {
            "matches": len(matches),
            "total_duration_seconds": round(total_duration, 3),
            "downloadable": downloadable_count,
            "verified": verified_count,
        },
        # Backward compatibility for older GhoSou clients/tests.
        "kinds": top(kinds),
    }


async def get_track(identifier: str) -> dict[str, Any] | None:
    """Resolve a public track by exact ID or slug."""
    needle = _text(identifier)
    if not needle:
        return None
    for item in await catalog():
        if not _is_public(item):
            continue
        if needle in {_text(item.get("ID")), _text(item.get("Slug"))}:
            return public_track(item)
    return None


async def related_tracks(identifier: str, limit: int = 8) -> list[dict[str, Any]]:
    base = await get_track(identifier)
    if not base:
        return []
    try:
        limit = max(1, min(int(limit or 8), 30))
    except (TypeError, ValueError):
        limit = 8
    meta = {
        "title": base.get("Title"),
        "artist": base.get("Artist"),
        "album": base.get("Album"),
        "genre": base.get("Genre"),
    }
    rows = await search_catalog(
        metadata=meta,
        kind=_text(base.get("Kind")),
        limit=min(200, max(20, limit * 5)),
    )
    base_id = _text(base.get("ID"))
    out = [row for row in rows if _text((row.get("track") or {}).get("ID")) != base_id]
    return out[:limit]


def resolve_public_audio_path(identifier: str) -> tuple[dict[str, Any], str] | None:
    """Internal-only resolver used by Telegram delivery. Never expose the path."""
    needle = _text(identifier)
    if not needle:
        return None
    for item in _load_snapshot_rows():
        if not _is_public(item):
            continue
        if needle not in {_text(item.get("ID")), _text(item.get("Slug"))}:
            continue
        raw = _text(item.get("File"))
        if not raw:
            return None
        candidate = (GHOSOU_ROOT / raw).resolve()
        try:
            candidate.relative_to(GHOSOU_UPLOADS)
        except ValueError:
            return None
        if not candidate.is_file():
            return None
        return public_track(item), str(candidate)
    return None


async def check_duplicates(metadata: dict[str, Any], limit: int = 10) -> dict[str, Any]:
    matches = await search_catalog(metadata=metadata, limit=limit)
    normalized = normalize_metadata(metadata)
    strong = [m for m in matches if m["score"] >= 6]
    return {
        "metadata_only": True,
        "moderation_required": bool(strong),
        "duplicates": bool(strong),
        "count": len(strong),
        "matches": matches,
        "reason": (
            "Найдены похожие метаданные; публикация должна попасть на модерацию."
            if strong else
            "Сильных совпадений по метаданным не найдено."
        ),
        "checked": normalized,
    }
