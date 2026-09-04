import asyncio
import os

import groq
from groq import AsyncGroq

from config import settings

client = AsyncGroq(api_key=settings.GROQ_API_KEY)

MODEL = "whisper-large-v3"


async def _create_with_retry(audio_path: str) -> list[dict]:
    """Groq transcription with exponential-backoff rate limit retries."""
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
        except groq.RateLimitError:
            await asyncio.sleep(2 ** attempt)
        except (groq.APIConnectionError, groq.InternalServerError) as e:
            if attempt == 2:
                raise RuntimeError(f"Groq API error: {e}") from e
            await asyncio.sleep(2 ** attempt)
    raise RuntimeError("Groq rate limit exceeded after 3 retries")


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
