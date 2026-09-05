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
    HOST: str = "0.0.0.0"
    PORT: int = 8000

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
