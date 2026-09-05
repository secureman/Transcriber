"""Environment-aware paths and binary discovery.

Makes the server run unchanged on:
  * a normal Linux/macOS machine  — everything stays inside the repo folder;
  * Termux on Android             — writable data lives in the home directory
    (the repo dir on Android storage is often read-only / slow), and binaries
    are looked up in Termux's prefix (``$PREFIX/files/usr/bin`` when run from
    the Files app, otherwise the standard ``$PREFIX/bin``).

Everything can still be overridden explicitly via environment variables or a
`.env` file — see `.env.example`.
"""

import os
import shutil
from pathlib import Path


def is_termux() -> bool:
    """True when running inside a Termux environment on Android."""
    return (
        os.environ.get("TERMUX_VERSION") is not None
        or "/com.termux" in os.environ.get("PREFIX", "")
        or "/com.termux" in os.environ.get("ANDROID_ROOT", "")
    )


def default_data_dir() -> Path:
    """Base directory for writable data (DB, VTT cache, temp audio, logs)."""
    if is_termux():
        # Termux home is always writable, private, and on fast internal
        # storage — ideal for SQLite and audio scratch files.
        return Path.home() / ".local" / "share" / "audiobook-transcriber"
    return Path.cwd()


def resolve_dir(env_var: str, default_name: str) -> str:
    """Resolves a writable directory.

    Order: explicit env var → Termux data dir/<name> → repo-local ./<name>.
    """
    env = os.environ.get(env_var)
    if env:
        return str(Path(env).expanduser())
    return str(default_data_dir() / default_name)


def resolve_file(env_var: str, default_name: str) -> str:
    """Resolves a writable file path (same rules as :func:`resolve_dir`)."""
    env = os.environ.get(env_var)
    if env:
        return str(Path(env).expanduser())
    return str(default_data_dir() / default_name)


def _termux_bin_dir() -> Path | None:
    """Termux binary dir, including the private-files-app prefix."""
    prefix = os.environ.get("PREFIX")
    candidates: list[Path] = []
    if prefix:
        candidates.append(Path(prefix) / "bin")
        # When launched from the Termux:Files share the prefix points at the
        # files-app dir; real binaries live one level deeper.
        candidates.append(Path(prefix) / "files" / "usr" / "bin")
    if is_termux():
        candidates.append(Path.home() / "files" / "usr" / "bin")
    for c in candidates:
        if c.is_dir():
            return c
    return None


def find_binary(name: str, env_var: str) -> str:
    """Finds an external binary.

    Order: explicit env var (e.g. FFMPEG_PATH) → PATH → Termux prefix dirs.
    Raises FileNotFoundError with an actionable hint when missing.
    """
    explicit = os.environ.get(env_var)
    if explicit:
        return str(Path(explicit).expanduser())

    found = shutil.which(name)
    if found:
        return found

    if is_termux():
        bin_dir = _termux_bin_dir()
        if bin_dir is not None:
            candidate = bin_dir / name
            if candidate.exists():
                return str(candidate)
        raise FileNotFoundError(
            f"'{name}' not found. Install it with:  pkg install {name}"
        )

    raise FileNotFoundError(
        f"'{name}' not found on PATH. Install ffmpeg (https://ffmpeg.org) "
        f"or set {env_var} to its full path."
    )


def ffmpeg_path() -> str:
    return find_binary("ffmpeg", "FFMPEG_PATH")


def ffprobe_path() -> str:
    return find_binary("ffprobe", "FFPROBE_PATH")
