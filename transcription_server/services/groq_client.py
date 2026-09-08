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

MODEL = settings.GROQ_MODEL

# Lazy client — don't construct at import time, so the server can boot
# without a key set (useful for health checks and smoke tests).
_client: Optional[Any] = None

# Caps parallel Groq API calls across all jobs/chapters.
_groq_semaphore = asyncio.Semaphore(max(1, settings.MAX_CONCURRENT_GROQ))


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


async def check_access() -> dict:
    """Validates the Groq API key and network reachability without burning
    transcription quota.

    Uses ``models.list()``, a lightweight read call: it proves the key is
    accepted and the account reachable, but does NOT prove transcription
    quota remains. Free-plan per-minute/hour caps only surface as 429s
    during an actual job, which ``_create_with_retry`` turns into a clear
    error on the job row (and every chunk upload already re-checks auth, so
    a revoked key fails fast there too).
    """
    if not settings.GROQ_API_KEY:
        return {
            "ok": False,
            "check": "groq",
            "label": "No API key",
            "detail": "GROQ_API_KEY is empty — set it in .env",
        }
    try:
        client = _get_client()
        await client.models.list()
    except RuntimeError as e:
        return {
            "ok": False, "check": "groq",
            "label": "Package not installed", "detail": str(e),
        }
    except groq.AuthenticationError as e:
        return {
            "ok": False, "check": "groq",
            "label": "Invalid API key",
            "detail": (f"Groq rejected the API key: {e}. "
                       "Check GROQ_API_KEY in .env"),
        }
    except groq.RateLimitError as e:
        return {
            "ok": False, "check": "groq",
            "label": "Rate limited / quota",
            "detail": (f"Groq rate-limited the request (free-plan caps or "
                       f"quota exhausted): {e}"),
        }
    except (groq.APIConnectionError, groq.InternalServerError) as e:
        return {
            "ok": False, "check": "groq",
            "label": "Unreachable",
            "detail": f"Groq API not reachable: {e}",
        }
    except Exception as e:  # noqa: BLE001 — surface any unexpected failure
        logger.warning("check_access: unexpected error: %s", e)
        return {
            "ok": False, "check": "groq",
            "label": "Unexpected error", "detail": f"{type(e).__name__}: {e}",
        }
    return {
        "ok": True, "check": "groq",
        "label": "OK",
        "detail": "Groq key accepted (models.list() succeeded). "
                  "Transcription quota itself is only confirmed per-job.",
    }


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
            async with _groq_semaphore:
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
            await asyncio.sleep(_retry_delay(attempt, e))
        except (groq.APIConnectionError, groq.InternalServerError) as e:
            logger.warning("Groq transient error (attempt %d/3): %s", attempt + 1, e)
            if attempt == 2:
                raise RuntimeError(f"Groq API error after 3 retries: {e}") from e
            await asyncio.sleep(_retry_delay(attempt, e))
    raise RuntimeError("Groq transcription failed (exhausted retries)")


def _retry_delay(attempt: int, exc: Exception) -> float:
    """Exponential backoff, honoring Retry-After when Groq sends one."""
    retry_after = getattr(exc, "response", None)
    header = None
    try:
        header = retry_after.headers.get("retry-after") if retry_after else None
    except AttributeError:
        pass
    if header:
        try:
            return max(0.0, float(header))
        except ValueError:
            pass
    return 2 ** attempt


async def transcribe_audio(audio_path: str) -> list[dict]:
    """Transcribes one file (≤ 24 MB). Returns [{word, start, end}, ...]."""
    return await _create_with_retry(audio_path)


async def transcribe_chunks(chunks: list[tuple[str, float]],
                            progress_cb=None, overlap_seconds: float = 8.0,
                            chunk_duration: float | None = None) -> list[dict]:
    """Transcribes pre-cut chunks **in parallel** and merges the words.

    [chunks] is [(chunk_path, offset_in_chapter)] as produced by
    ffmpeg_service.prepare_chapter_chunks(). Groq is I/O-bound, so uploads
    run concurrently, bounded by MAX_CONCURRENT_CHUNKS (per chapter) and
    MAX_CONCURRENT_GROQ (globally, via _groq_semaphore).

    Overlap handling (chunks longer than chunk_duration share `overlap`
    seconds with their neighbours):
      * head trim (i > 0): drop words starting before overlap_seconds / 2;
      * tail trim (i < last, when chunk_duration is given): drop words
        starting after chunk_duration.
    Timestamps are shifted by each chunk's offset, then globally sorted.

    [progress_cb] — optional async callback(progress: float 0.0–1.0)
    invoked as chunks complete.
    """
    total = max(1, len(chunks))
    done = 0

    async def _report(fraction: float) -> None:
        if progress_cb is not None:
            try:
                await progress_cb(fraction)
            except Exception:  # noqa: BLE001 — progress must never break a job
                pass

    async def _one(i: int, chunk_path: str, offset: float) -> list[dict]:
        nonlocal done
        words = await transcribe_audio(chunk_path)
        if i > 0:
            words = [w for w in words if w["start"] >= overlap_seconds / 2]
        if i < total - 1 and chunk_duration is not None:
            words = [w for w in words if w["start"] <= chunk_duration]
        shifted = [
            {
                "word": w["word"],
                "start": w["start"] + offset,
                "end": w["end"] + offset,
            }
            for w in words
        ]
        done += 1
        # 10% → 85% of the job is spent during transcription.
        await _report(0.1 + 0.8 * done / total)
        return shifted

    # Parallel Groq calls, bounded by MAX_CONCURRENT_CHUNKS per chapter.
    sem = asyncio.Semaphore(max(1, settings.MAX_CONCURRENT_CHUNKS))

    async def _bounded(i: int, path: str, offset: float) -> list[dict]:
        async with sem:
            return await _one(i, path, offset)

    try:
        results = await asyncio.gather(
            *(_bounded(i, p, off) for i, (p, off) in enumerate(chunks))
        )
    finally:
        # Chunks are pre-cut by the caller's pipeline; clean them up here so
        # tmp dirs don't accumulate even if gather raises.
        from services.ffmpeg_service import cleanup_tmp
        for path, _off in chunks:
            try:
                cleanup_tmp(path)
            except OSError:
                pass

    all_words = [w for chunk_words in results for w in chunk_words]
    all_words.sort(key=lambda w: w["start"])
    await _report(0.95)
    return all_words
