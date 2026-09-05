import asyncio
import os

from config import settings
from paths import ffmpeg_path, ffprobe_path


async def extract_chapter(audio_url: str, token: str, start: float,
                          end: float, output_path: str) -> None:
    """Extracts [start, end] from a remote audio file into a small mono MP3.

    Uses `-ss` (input seeking) + `-t` (duration) which is reliable over HTTP.
    """
    duration = max(0.0, end - start)
    cmd = [
        ffmpeg_path(), "-y",
        "-headers", f"Authorization: Bearer {token}\r\n",
        "-ss", f"{start:.3f}",
        "-t", f"{duration:.3f}",
        "-i", audio_url,
        # libmp3lame is not compiled into every Android/Termux ffmpeg build;
        # fall back to the always-available native aac encoder when needed.
        *_audio_codec_args(),
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


# Audio codec args. libmp3lame is missing from some ffmpeg builds (notably
# certain Android/Termux packages), so the available encoders are probed
# once at startup (see init_encoder_profile, called from the app lifespan)
# and cached here. Falls back to libmp3lame until/unless the probe says
# otherwise — every mainstream ffmpeg build for PC ships it.
_codec_args: list[str] | None = None

_MP3_ARGS = ["-c:a", "libmp3lame", "-b:a", "64k"]
_AAC_ARGS = ["-c:a", "aac", "-b:a", "64k"]


def _audio_codec_args() -> list[str]:
    return _codec_args or _MP3_ARGS


async def init_encoder_profile() -> None:
    """Probes ffmpeg's encoders once and selects MP3 or AAC accordingly."""
    global _codec_args
    if _codec_args is not None:
        return
    try:
        proc = await asyncio.create_subprocess_exec(
            ffmpeg_path(), "-hide_banner", "-encoders",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await proc.communicate()
        listing = out.decode(errors="ignore")
    except (OSError, FileNotFoundError):
        listing = ""
    _codec_args = _MP3_ARGS if "libmp3lame" in listing else _AAC_ARGS


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
            ffmpeg_path(), "-y",
            "-ss", f"{chunk_start_with_overlap:.3f}",
            "-t", f"{chunk_duration + overlap:.3f}",
            "-i", input_path,
            *_audio_codec_args(),
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
        ffmpeg_path(), "-y",
        "-f", "concat", "-safe", "0", "-i", list_path,
        *_audio_codec_args(),
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
        ffprobe_path(), "-v", "error",
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
    os.makedirs(settings.LOG_DIR, exist_ok=True)
