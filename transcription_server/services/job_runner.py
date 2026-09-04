import asyncio
import logging
import os
import time
import traceback

import database as db
from config import settings
from services import abs_client, ffmpeg_service, groq_client
from services.vtt_builder import build_vtt

logger = logging.getLogger("job_runner")

# Limits parallel Groq calls (shared with the worker pool in queue.py).
semaphore = asyncio.Semaphore(settings.MAX_CONCURRENT_JOBS)


async def _execute_job(job_id: str) -> None:
    """Run one job from start to finish. Logs every step. On any failure,
    captures the full traceback to the log file AND to the DB so the user
    can see what went wrong without having to ssh into the server.
    """
    tmp_dir: str | None = None
    t0 = time.monotonic()
    try:
        job = await db.get_job(job_id)
        if job is None:
            logger.warning("Job %s vanished before execution", job_id)
            return
        await db.set_job_status(job_id, "processing", progress=0)
        book_id = job["book_id"]
        chapter_index = job["chapter_index"]
        logger.info(
            "Job %s starting: book=%s chapter=%d (priority=%s)",
            job_id, book_id, chapter_index, job.get("priority", 0),
        )

        # 1. Book metadata (cached in DB by the transcribe endpoint).
        item_json = await db.get_book(book_id)
        if item_json is None:
            logger.info("Job %s: book %s not cached, fetching from ABS",
                        job_id, book_id)
            item_json = await abs_client.get_item(book_id)
        meta = abs_client.extract_meta(item_json)
        chapters = meta["chapters"]
        if chapter_index >= len(chapters):
            raise RuntimeError(
                f"Chapter {chapter_index} out of range "
                f"(book has {len(chapters)} chapters)")
        chapter = chapters[chapter_index]
        logger.info("Job %s: chapter title=%r start=%.2f end=%.2f",
                    job_id, chapter.get("title"), chapter["start"],
                    chapter["end"])

        # 2. Map global chapter times onto audio files (handles both
        #    single-file and multi-file books).
        parts = _resolve_chapter_parts(meta["audio_files"],
                                       chapter["start"], chapter["end"])
        logger.info("Job %s: chapter spans %d audio file(s)",
                    job_id, len(parts))

        # 3. Extract audio to tmp.
        tmp_dir = os.path.join(settings.TEMP_DIR, f"{book_id}_{chapter_index}")
        os.makedirs(tmp_dir, exist_ok=True)
        part_paths: list[str] = []
        for i, (ino, start_in_file, end_in_file) in enumerate(parts):
            await db.set_job_progress(job_id, 0.02 + 0.10 * i / max(1, len(parts)))
            url = abs_client.audio_file_url(book_id, ino)
            part_path = os.path.join(tmp_dir, f"part_{i}.mp3")
            t = time.monotonic()
            await ffmpeg_service.extract_chapter(
                url, settings.ABS_API_TOKEN, start_in_file, end_in_file,
                part_path)
            logger.info("Job %s: extracted part %d/%d in %.2fs (%.1fs → %.1fs)",
                        job_id, i + 1, len(parts), time.monotonic() - t,
                        start_in_file, end_in_file)
            part_paths.append(part_path)
        await db.set_job_progress(job_id, 0.12)

        if len(part_paths) == 1:
            audio_path = part_paths[0]
        else:
            audio_path = os.path.join(tmp_dir, "chapter.mp3")
            t = time.monotonic()
            await ffmpeg_service.concat_files(part_paths, audio_path)
            logger.info("Job %s: concatenated %d parts in %.2fs",
                        job_id, len(part_paths), time.monotonic() - t)
        await db.set_job_progress(job_id, 0.15)

        # 4. Transcribe (chunked if > 24 MB); progress 15% → 92%.
        async def _on_progress(fraction: float) -> None:
            await db.set_job_progress(job_id, 0.15 + fraction * 0.77)

        t = time.monotonic()
        words = await groq_client.transcribe_chunked(
            audio_path, progress_cb=_on_progress)
        logger.info("Job %s: groq returned %d words in %.2fs",
                    job_id, len(words), time.monotonic() - t)

        # 5. Build VTT and write to cache.
        vtt_text = build_vtt(words)
        out_dir = os.path.join(settings.OUTPUT_DIR, book_id)
        os.makedirs(out_dir, exist_ok=True)
        vtt_path = os.path.join(out_dir, f"chapter_{chapter_index}.vtt")
        with open(vtt_path, "w", encoding="utf-8") as f:
            f.write(vtt_text)
        await db.set_job_progress(job_id, 0.98)
        logger.info("Job %s: wrote %d bytes of VTT to %s",
                    job_id, len(vtt_text), vtt_path)

        # 6. Done.
        await db.set_job_status(job_id, "done", vtt_path=vtt_path,
                                progress=100.0)
        logger.info("Job %s: DONE in %.2fs", job_id, time.monotonic() - t0)

    except Exception as e:  # noqa: BLE001 — report any failure on the job
        # Full traceback in the log file; truncated copy in the DB so the
        # Flutter UI can surface it without having to read logs.
        tb = traceback.format_exc()
        logger.error("Job %s FAILED after %.2fs: %s\n%s",
                     job_id, time.monotonic() - t0, e, tb)
        # Keep DB column reasonable in size; logs/server.log has the full thing.
        await db.set_job_status(job_id, "error",
                                error_message=f"{type(e).__name__}: {e}\n\n{tb[-3500:]}")
    finally:
        if tmp_dir is not None:
            ffmpeg_service.cleanup_tmp(tmp_dir)


def _resolve_chapter_parts(audio_files: list[dict], start: float,
                           end: float) -> list[tuple[str, float, float]]:
    """Maps global chapter times onto (ino, start_in_file, end_in_file).

    A chapter may span multiple audio files; returns one entry per file.
    """
    parts: list[tuple[str, float, float]] = []
    cursor = 0.0
    for f in audio_files:
        file_start = cursor
        file_end = cursor + f["duration"]
        cursor = file_end

        if file_end <= start or file_start >= end:
            continue

        s = max(start - file_start, 0.0)
        e = min(end - file_start, f["duration"])
        if e > s:
            parts.append((f["ino"], s, e))

    if not parts and audio_files:
        # Fallback: entire single file (shouldn't normally happen).
        f = audio_files[0]
        parts.append((f["ino"], start, end))
    return parts
