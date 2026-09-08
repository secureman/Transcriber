from pydantic_settings import BaseSettings

from paths import resolve_dir, resolve_file


class Settings(BaseSettings):
    ABS_BASE_URL: str = "http://localhost:13378"
    ABS_API_TOKEN: str = ""
    GROQ_API_KEY: str = ""
    # Defaults resolve to Termux home on Android, repo-local paths elsewhere
    # (see paths.py). Override freely via environment or .env.
    OUTPUT_DIR: str = resolve_dir("OUTPUT_DIR", "vtt_cache")
    TEMP_DIR: str = resolve_dir("TEMP_DIR", "tmp_audio")
    DB_PATH: str = resolve_file("DB_PATH", "transcriptions.db")
    LOG_DIR: str = resolve_dir("LOG_DIR", "logs")
    MAX_CONCURRENT_JOBS: int = 2
    # Parallel Groq API calls across all workers. Groq is I/O-bound, so this
    # is deliberately separate from MAX_CONCURRENT_JOBS (which bounds the
    # CPU-bound ffmpeg work). Raise on paid Groq tiers with higher RPM.
    MAX_CONCURRENT_GROQ: int = 4
    # Parallel chunk uploads within a single chapter's transcription.
    MAX_CONCURRENT_CHUNKS: int = 4
    # Target chunk size in MB fed to Groq per request (must stay < 25 MB).
    # Smaller chunks parallelize better; ~10 MB ≈ 20 min of 64 kbps audio.
    GROQ_CHUNK_SIZE_MB: float = 10.0
    # Whisper model. whisper-large-v3-turbo is ~8x faster with a small
    # accuracy tradeoff; set to whisper-large-v3 for maximum quality.
    GROQ_MODEL: str = "whisper-large-v3-turbo"
    HOST: str = "0.0.0.0"
    PORT: int = 8000

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
