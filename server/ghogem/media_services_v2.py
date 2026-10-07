"""Common multimodal/TTS runtime for Telegram and Web, with quotas.

No account ID is supplied by the agent; callers use the authenticated owner ID.
"""
from __future__ import annotations

import asyncio
import fcntl
import math
import os
from pathlib import Path
import subprocess
import tempfile

import media_quotas_v2 as quotas
import storage_v2

MAX_SEGMENTS = 120  # operational safety: no more than 4 hours per recording

# One heavy media job at a time. The production host has one vCPU, so running
# multiple ffmpeg/video/STT pipelines in parallel only increases latency and
# swap pressure. flock makes the queue shared by Telegram and Web API processes.
MEDIA_WORKERS = 1
MEDIA_LOCK_PATH = os.path.join(os.path.dirname(__file__), ".media-worker.lock")
_media_waiters = 0
_media_active = 0
_media_lock_fds: dict[int, int] = {}


async def acquire_media_slot() -> int:
    """Wait for the single heavy-media slot shared by bot and Web API."""
    global _media_waiters, _media_active
    _media_waiters += 1
    position = _media_waiters
    fd = None
    try:
        fd = os.open(MEDIA_LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o600)
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                await asyncio.sleep(0.1)
        task = asyncio.current_task()
        if task is None:
            raise RuntimeError("Media queue requires an asyncio task.")
        _media_lock_fds[id(task)] = fd
        fd = None
        _media_active += 1
        return position
    except BaseException:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        raise
    finally:
        _media_waiters = max(0, _media_waiters - 1)


def release_media_slot() -> None:
    global _media_active
    task = asyncio.current_task()
    fd = _media_lock_fds.pop(id(task), None) if task is not None else None
    if fd is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
    _media_active = max(0, _media_active - 1)


def media_queue_status() -> dict:
    return {
        "workers": MEDIA_WORKERS,
        "active": _media_active,
        "waiting": _media_waiters,
    }


def probe_duration(path: str) -> float:
    proc = subprocess.run(
        ["ffprobe","-v","error","-show_entries","format=duration",
         "-of","default=noprint_wrappers=1:nokey=1",path],
        text=True, capture_output=True, timeout=15
    )
    try:
        duration = float(proc.stdout.strip())
    except (ValueError,TypeError):
        duration = 0
    if proc.returncode or not math.isfinite(duration) or duration <= 0:
        raise ValueError("Не удалось определить длительность аудио/видео.")
    return duration

def _audio_chunk(path: str, offset: float, seconds: float) -> str:
    fd,tmp=tempfile.mkstemp(prefix="ghogem-audio-seg-",suffix=".wav")
    os.close(fd)
    args=["ffmpeg","-hide_banner","-loglevel","error","-nostdin",
          "-ss",str(round(offset,3)),"-i",path,"-t",str(round(seconds,3)),
          "-vn","-ac","1","-ar","16000","-c:a","pcm_s16le","-y",tmp]
    try:
        proc=subprocess.run(args,capture_output=True,timeout=45)
        if proc.returncode or os.path.getsize(tmp)<1024:
            raise RuntimeError("Не удалось подготовить аудиофрагмент.")
        return tmp
    except Exception:
        os.unlink(tmp)
        raise

async def audio_segments(ai, path: str, premium: bool) -> tuple[list[dict],str]:
    """Transcribe each allowed chunk, starting from zero; errors never return partial success."""
    length=await asyncio.to_thread(probe_duration,path)
    max_sec=quotas.POLICY["premium" if premium else "free"]["audio_segment_seconds"]
    length_to_process=length if premium else min(length,max_sec)
    count=max(1,math.ceil(length_to_process/max_sec))
    if count>MAX_SEGMENTS:
        raise RuntimeError("Слишком длинная аудиозапись для одного запроса (технический предел 4 часа).")
    chunks=[]
    for i in range(count):
        start=i*max_sec
        seconds=min(max_sec,length_to_process-start)
        segment=await asyncio.to_thread(_audio_chunk,path,start,seconds)
        try:
            text=await ai.transcribe_audio(segment)
        finally:
            try:os.unlink(segment)
            except OSError:pass
        if str(text).startswith("❌"):
            raise RuntimeError(str(text)[:350])
        chunks.append({"start":start,"end":start+seconds,"text":str(text).strip()})
    note=f"Исходная длительность: {length:.1f} с; обработано: {length_to_process:.1f} с."
    if not premium and length>max_sec:
        note+=(f" ВАЖНО: запись обрезана после {max_sec} с; "
               f"оставшиеся {length-max_sec:.1f} с НЕ прослушаны.")
    elif premium and count>1:
        note+=f" Premium: последовательно обработаны все {count} части по максимум {max_sec} с."
    return chunks,note

async def transcribe_with_quota(ai, uid: int, premium: bool, path: str) -> str:
    try:
        claim=quotas.reserve(ai.USERS_DIR,uid,"audio",premium,path)
    except (storage_v2.StorageError, OSError,ValueError) as e:
        return f"❌ Доступ к аудио запрещён: {e}"
    if not claim.ok:
        return claim.message
    good=False
    queued=False
    try:
        await acquire_media_slot()
        queued=True
        chunks,note=await audio_segments(ai,path,premium)
        # Transcribe tool output may be limited by agent context, but every
        # chunk has actually been examined, never silently dropped.
        text="\n".join(f"[{int(c['start'])}–{int(c['end'])} с] {c['text']}" for c in chunks)
        good=True
        return f"{note}\nРасшифровка:\n{text}"
    except Exception as e:
        return f"❌ Анализ аудио не удался: {str(e)[:350]}"
    finally:
        if queued:
            release_media_slot()
        quotas.finish(ai.USERS_DIR,uid,claim.token,good)

async def analyze_with_quota(ai, uid: int, premium: bool, *,
                             path: str, filename: str, task: str,
                             user_prompt: str, output_format: str,
                             writer_model_key: str, analysis_mode: str="fast",
                             **kwargs) -> str:
    ext=Path(path).suffix.lower()
    if analysis_mode not in ("fast","reasoning"):
        return "❌ Режим анализа должен быть fast или reasoning."
    if ext in storage_v2.IMAGE_TYPES and analysis_mode=="reasoning" and not premium:
        return "🔒 Анализ фото с рассуждениями доступен только с Premium; используй fast."
    kind=("audio" if ext in storage_v2.AUDIO_TYPES else
          "video" if ext in storage_v2.VIDEO_TYPES else "")
    claim=None
    if kind:
        try:
            claim=quotas.reserve(ai.USERS_DIR,uid,kind,premium,path)
        except (storage_v2.StorageError,OSError,ValueError) as e:
            return f"❌ Ошибка проверки медиа: {e}"
        if not claim.ok:
            return claim.message
    good=False
    queued=False
    try:
        if kind:
            await acquire_media_slot()
            queued=True
        note=""
        if kind=="video":
            max_len=quotas.POLICY["premium" if premium else "free"]["video_seconds"]
            duration=await asyncio.to_thread(probe_duration,path)
            start=float(kwargs.get("start_second") or 0)
            if start>=min(duration,max_len):
                return f"❌ Можно анализировать только первые {max_len} с этого видео."
            kwargs["start_second"]=max(0,start)
            requested=float(kwargs.get("duration_seconds") or 0)
            kwargs["duration_seconds"]=min(
                max(0.1,requested) if requested else max_len,
                max_len-max(0,start),
            )
            if duration>max_len:
                note=(f"⚠️ Видео длится {duration:.1f} с. "
                      f"По тарифу проанализированы только первые {max_len} с; "
                      f"остальная часть НЕ проверялась.\n")
        result=await ai.file_analyzer.analyze_file(
            ai=ai,path=path,filename=filename,task=task,user_prompt=user_prompt,
            output_format=output_format,writer_model_key=writer_model_key,
            premium=premium,analysis_mode=analysis_mode,**kwargs,
        )
        good=bool(result and not str(result).startswith(("❌","🔒","⚠️")))
        return note+str(result)
    except Exception as e:
        return f"❌ Ошибка медиаанализатора: {type(e).__name__}"
    finally:
        if queued:
            release_media_slot()
        if claim:
            quotas.finish(ai.USERS_DIR,uid,claim.token,good)

async def extract_audio_to_media(ai, uid: int, premium: bool, path: str, *,
                                 filename: str = "") -> dict:
    """Extract the first audio stream from an owned video into temporary media."""
    ext = Path(path).suffix.lower()
    if ext not in storage_v2.VIDEO_TYPES:
        return {"error": "❌ Это не видеофайл."}
    if not os.path.isfile(path):
        return {"error": "❌ Видеофайл не найден."}

    try:
        probe = await asyncio.to_thread(
            subprocess.run,
            [
                "ffprobe", "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=codec_type",
                "-of", "default=noprint_wrappers=1:nokey=1",
                path,
            ],
            capture_output=True, text=True, timeout=12,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"error": "❌ Не удалось проверить звуковую дорожку видео."}
    if probe.returncode != 0 or "audio" not in (probe.stdout or "").split():
        return {"error": "❌ В этом видео нет звуковой дорожки."}

    await acquire_media_slot()
    fd, tmp = tempfile.mkstemp(prefix="ghogem-extract-audio-", suffix=".ogg")
    os.close(fd)
    try:
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", path,
            "-map", "0:a:0", "-vn",
            "-c:a", "libopus", "-b:a", "96k",
            tmp,
        ]
        try:
            proc = await asyncio.to_thread(
                subprocess.run, cmd, capture_output=True, timeout=90
            )
        except subprocess.TimeoutExpired:
            return {"error": "❌ Извлечение аудио заняло слишком много времени."}
        if proc.returncode != 0 or not os.path.isfile(tmp) or os.path.getsize(tmp) < 256:
            return {"error": "❌ Не удалось отделить аудио от видео."}

        with open(tmp, "rb") as handle:
            data = handle.read(storage_v2.MEDIA_MAX_UPLOAD + 1)
        if len(data) > storage_v2.MEDIA_MAX_UPLOAD:
            return {"error": "❌ Получившееся аудио слишком большое для хранилища."}

        output_name = str(filename or "").strip()
        if not output_name:
            output_name = f"{Path(path).stem}_audio.ogg"
        if not output_name.lower().endswith((".ogg", ".opus")):
            output_name += ".ogg"

        try:
            return await asyncio.to_thread(
                storage_v2.save_temporary,
                ai.USERS_DIR, uid, output_name, data,
                area="media", premium=premium,
            )
        except (storage_v2.StorageError, OSError, ValueError) as exc:
            return {"error": f"❌ Не удалось сохранить извлечённое аудио: {str(exc)[:200]}"}
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        release_media_slot()


async def speech_to_media(ai, uid: int, premium: bool, text: str, *,
                          filename: str="", chat_id: str="",
                          reference_id: str|None=None,
                          voice_file: str|None=None,
                          voice_transcript: str|None=None) -> dict:
    if not ai.fish_tts_available():
        return {"error":"❌ Провайдер озвучки сейчас недоступен."}
    if not str(text or "").strip():
        return {"error":"❌ Нечего озвучивать."}
    if len(text)>2500:
        return {"error":"❌ Текст для озвучки превышает 2500 символов."}
    refpath=None
    if voice_file:
        try:
            refpath=ai.resolve_user_upload(uid,chat_id or ai.get_current_chat(uid),voice_file)
            if not os.path.isfile(refpath):
                return {"error":"❌ Аудиообразец не найден."}
        except (ValueError,OSError,storage_v2.StorageError):
            return {"error":"❌ Аудиообразец недоступен."}
    claim=quotas.reserve(ai.USERS_DIR,uid,"tts",premium)
    if not claim.ok:
        return {"error":claim.message}
    success=False
    fd,tmp=tempfile.mkstemp(prefix="ghogem-tts-v2-",suffix=".mp3")
    os.close(fd)
    try:
        output=await ai.fish_tts(
            text,tmp,reference_id=reference_id,reference_audio_path=refpath,
            reference_text=voice_transcript
        )
        if str(output).startswith("❌"):
            return {"error":str(output)}
        with open(tmp,"rb") as f:
            data=f.read(storage_v2.MEDIA_MAX_UPLOAD+1)
        saved=await asyncio.to_thread(
            storage_v2.save_temporary,ai.USERS_DIR,uid,
            filename if filename.lower().endswith(".mp3") else "ghogem_speech.mp3",
            data,area="media",premium=premium,
        )
        success=True
        return saved
    except (storage_v2.StorageError,OSError,ValueError) as exc:
        return {"error":f"❌ Не удалось сохранить озвучку: {str(exc)[:200]}"}
    finally:
        try:os.unlink(tmp)
        except OSError:pass
        quotas.finish(ai.USERS_DIR,uid,claim.token,success)
