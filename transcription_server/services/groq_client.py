import asyncio
import logging
import os
from typing import Any, Optional

# `groq` is only needed at transcription time. Importing lazily lets the
# server boot (and respond to /api/health, /api/jobs/active, etc.) on a
# machine that doesn't have it installed yet — useful for first-run setup.
try:
    import groq
    from groq import AsyncGroq
    _GROQ_AVAILABLE = True
except ImportError:  # pragma: no cover
    groq = None  # type: ignore[assignment]
    AsyncGroq = None  # type: ignore[assignment,misc]
    _GROQ_AVAILABLE = False

from config import settings

logger = logging.getLogger("groq")

MODEL = "whisper-large-v3"

# Lazy client — don't construct at import time, so the server can boot
# without a key set (useful for health checks and smoke tests).
_client: Optional[Any] = None


def _get_client() -> Any:
    global _client
    if not _GROQ_AVAILABLE:
        raise RuntimeError(
            "The 'groq' package is not installed. "
            "Run: pip install groq")
    if _client is None:
        if not settings.GROQ_API_KEY:
            raise RuntimeError(
                "GROQ_API_KEY is empty — set it in .env before transcribing")
        _client = AsyncGroq(api_key=settings.GROQ_API_KEY)
    return _client


async def _create_with_retry(audio_path: str) -> list[dict]:
    """Groq transcription with exponential-backoff rate limit retries.

    Auth errors (bad API key) are NOT retried — fail fast so the user
    sees a clear error instead of waiting 7s for 3 doomed attempts.
    """
    if not _GROQ_AVAILABLE:
        raise RuntimeError(
            "The 'groq' package is not installed. Run: pip install groq")
    client = _get_client()
    for attempt in range(3):
        try:
            with open(audio_path, "rb") as f:
                response = await client.audio.transcriptions.create(
                    model=MODEL,
                    file=f,
                    response_format="verbose_json",
                    timestamp_granularities=["word"],
                )
            # Groq's verbose_json returns dicts in response.words.
            words = response.words or []
            return [
                {
                    "word": w.get("word", ""),
                    "start": float(w.get("start", 0) or 0),
                    "end": float(w.get("end", 0) or 0),
                }
                for w in words
                if isinstance(w, dict) and w.get("word")
            ]
        except groq.AuthenticationError as e:
            # Don't waste 3 attempts on a bad key.
            raise RuntimeError(
                f"Groq rejected the API key: {e}. "
                f"Check GROQ_API_KEY in .env") from e
        except groq.RateLimitError as e:
            logger.warning("Groq rate-limited (attempt %d/3): %s", attempt + 1, e)
            if attempt == 2:
                raise RuntimeError(f"Groq rate limit exceeded after 3 retries: {e}") from e
            await asyncio.sleep(2 ** attempt)
        except (groq.APIConnectionError, groq.InternalServerError) as e:
            logger.warning("Groq transient error (attempt %d/3): %s", attempt + 1, e)
            if attempt == 2:
                raise RuntimeError(f"Groq API error after 3 retries: {e}") from e
            await asyncio.sleep(2 ** attempt)
    raise RuntimeError("Groq transcription failed (exhausted retries)")


async def transcribe_audio(audio_path: str) -> list[dict]:
    """Transcribes one file (≤ 24 MB). Returns [{word, start, end}, ...]."""
    return await _create_with_retry(audio_path)


async def transcribe_chunked(audio_path: str, chunk_size_mb: float = 20.0,
                             overlap_seconds: float = 8.0,
                             progress_cb=None) -> list[dict]:
    """Transcribes a file of any size, splitting into Groq-safe chunks.

    For the overlap zone: drops the first 4s and last 4s of neighbouring
    chunks' words before merging, then offsets timestamps by each chunk's
    start position in the original file.

    [progress_cb] — optional async callback(progress: float 0.0–1.0) invoked
    as chunks complete.
    """
    from services.ffmpeg_service import split_audio, cleanup_tmp

    async def _report(fraction: float) -> None:
        if progress_cb is not None:
            try:
                await progress_cb(fraction)
            except Exception:  # noqa: BLE001 — progress must never break a job
                pass

    file_size_mb = os.path.getsize(audio_path) / (1024 * 1024)
    if file_size_mb <= 24:
        await _report(0.9)
        return await transcribe_audio(audio_path)

    chunk_duration = chunk_size_mb * 1024 * 1024 / (64 * 1024 / 8)  # ≈2500s @64kbps
    out_dir = audio_path + "_chunks"
    chunks = await split_audio(audio_path, chunk_duration, overlap_seconds,
                               out_dir)
    try:
        all_words: list[dict] = []
        total = max(1, len(chunks))
        for i, (chunk_path, offset) in enumerate(chunks):
            words = await transcribe_audio(chunk_path)
            if i > 0:
                words = [w for w in words if w["start"] >= overlap_seconds / 2]
            if i < len(chunks) - 1:
                words = [w for w in words if w["start"] <= chunk_duration]
            for w in words:
                all_words.append({
                    "word": w["word"],
                    "start": w["start"] + offset,
                    "end": w["end"] + offset,
                })
            # 10% → 85% of the job is spent during transcription.
            await _report(0.1 + 0.8 * (i + 1) / total)
        all_words.sort(key=lambda w: w["start"])
        await _report(0.95)
        return all_words
    finally:
        cleanup_tmp(out_dir)
