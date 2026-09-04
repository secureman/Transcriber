import asyncio
import os

from config import settings


async def extract_chapter(audio_url: str, token: str, start: float,
                          end: float, output_path: str) -> None:
    """Extracts [start, end] from a remote audio file into a small mono MP3.

    Uses `-ss` (input seeking) + `-t` (duration) which is reliable over HTTP.
    """
    duration = max(0.0, end - start)
    cmd = [
        "ffmpeg", "-y",
        "-headers", f"Authorization: Bearer {token}\r\n",
        "-ss", f"{start:.3f}",
        "-t", f"{duration:.3f}",
        "-i", audio_url,
        "-c:a", "libmp3lame",
        "-b:a", "64k",
        "-ar", "22050",
        "-ac", "1",
        output_path,
    ]
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {stderr.decode(errors='ignore')[-800:]}")


async def split_audio(input_path: str, chunk_duration: float,
                      overlap: float,
                      output_dir: str) -> list[tuple[str, float]]:
    """Splits a file into chunks of ~chunk_duration seconds.

    Each chunk (except the first) includes `overlap` seconds of audio from
    the previous chunk for boundary safety.

    Returns list of (chunk_path, chunk_start_offset_in_original).
    """
    os.makedirs(output_dir, exist_ok=True)
    total = await _duration_of(input_path)

    # Probe duration via ffprobe.
    chunks: list[tuple[str, float]] = []
    start = 0.0
    idx = 0
    while start < total - 0.05:
        chunk_start_with_overlap = max(0.0, start - (overlap if idx > 0 else 0))
        out_path = os.path.join(output_dir, f"chunk_{idx:03d}.mp3")
        cmd = [
            "ffmpeg", "-y",
            "-ss", f"{chunk_start_with_overlap:.3f}",
            "-t", f"{chunk_duration + overlap:.3f}",
            "-i", input_path,
            "-c:a", "libmp3lame",
            "-b:a", "64k",
            "-ar", "22050",
            "-ac", "1",
            out_path,
        ]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(
                f"ffmpeg split failed: {stderr.decode(errors='ignore')[-800:]}")
        chunks.append((out_path, chunk_start_with_overlap))
        start += chunk_duration
        idx += 1
    return chunks


async def concat_files(parts: list[str], output_path: str) -> None:
    """Concatenates audio files using ffmpeg's concat demuxer."""
    list_path = output_path + ".txt"
    with open(list_path, "w", encoding="utf-8") as f:
        for p in parts:
            f.write(f"file '{os.path.abspath(p)}'\n")
    cmd = [
        "ffmpeg", "-y",
        "-f", "concat", "-safe", "0", "-i", list_path,
        "-c:a", "libmp3lame",
        "-b:a", "64k",
        "-ar", "22050",
        "-ac", "1",
        output_path,
    ]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(
                f"ffmpeg concat failed: {stderr.decode(errors='ignore')[-800:]}")
    finally:
        if os.path.exists(list_path):
            os.remove(list_path)


async def _duration_of(path: str) -> float:
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        path,
    ]
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, _ = await proc.communicate()
    try:
        return float(stdout.decode().strip())
    except ValueError:
        return 0.0


def cleanup_tmp(path: str) -> None:
    """Removes a tmp file (or every file in a tmp dir) after a job."""
    if os.path.isfile(path):
        os.remove(path)
    elif os.path.isdir(path):
        for name in os.listdir(path):
            p = os.path.join(path, name)
            if os.path.isfile(p):
                os.remove(p)
        try:
            os.rmdir(path)
        except OSError:
            pass


def ensure_dirs() -> None:
    os.makedirs(settings.OUTPUT_DIR, exist_ok=True)
    os.makedirs(settings.TEMP_DIR, exist_ok=True)
