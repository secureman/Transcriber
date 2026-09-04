from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    ABS_BASE_URL: str = "http://localhost:13378"
    ABS_API_TOKEN: str = ""
    GROQ_API_KEY: str = ""
    OUTPUT_DIR: str = "./vtt_cache"
    TEMP_DIR: str = "./tmp_audio"
    MAX_CONCURRENT_JOBS: int = 2
    HOST: str = "0.0.0.0"
    PORT: int = 8000

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
