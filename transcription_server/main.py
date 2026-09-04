import logging
import os
from contextlib import asynccontextmanager
from logging.handlers import RotatingFileHandler

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import database as db
from config import settings
from routers import metadata, transcribe, vtt
from services import queue as job_queue
from services.ffmpeg_service import ensure_dirs


def _configure_logging() -> None:
    """Set up logging to both stdout and a rotating file (logs/server.log).

    Verbose INFO so the user can see what's running, ERRORs include the full
    traceback because we use logger.exception() at the call sites.
    """
    log_dir = "logs"
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, "server.log")

    fmt = "%(asctime)s %(levelname)s [%(name)s] %(message)s"
    formatter = logging.Formatter(fmt)

    root = logging.getLogger()
    root.setLevel(logging.INFO)
    # Idempotent: avoid duplicate handlers on reload / re-import in tests.
    if not any(isinstance(h, RotatingFileHandler) for h in root.handlers):
        file_handler = RotatingFileHandler(
            log_path, maxBytes=10_000_000, backupCount=5, encoding="utf-8"
        )
        file_handler.setFormatter(formatter)
        root.addHandler(file_handler)

    # Make noisy third-party loggers a bit quieter but still informative.
    for noisy in ("httpx", "httpcore"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


_configure_logging()
logger = logging.getLogger("server")


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.init_db()
    ensure_dirs()
    # Resets rows stuck in 'processing' (from a previous crash) to 'pending'
    # and starts the durable worker pool so transcription continues even if
    # the client backgrounds/closes the app.
    await job_queue.ensure_started_on_boot()
    logger.info("Server started on http://%s:%d", settings.HOST, settings.PORT)
    yield
    logger.info("Server shutting down, stopping workers")
    await job_queue.stop_workers()


app = FastAPI(title="Audiobook Transcription Server", lifespan=lifespan)

# CORS open-by-design for a self-hosted LAN service. If you ever expose this
# to the public internet, lock this down — see README "Security".
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(transcribe.router, prefix="/api")
app.include_router(vtt.router, prefix="/api")
app.include_router(metadata.router, prefix="/api")


@app.get("/api/health")
async def health() -> dict:
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host=settings.HOST, port=settings.PORT,
                reload=True)
