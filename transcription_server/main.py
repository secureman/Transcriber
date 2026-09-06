import logging
import os
from contextlib import asynccontextmanager
from logging.handlers import RotatingFileHandler

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import database as db
from config import settings
from routers import metadata, transcribe, vtt
from services import ffmpeg_service, queue as job_queue
from services.ffmpeg_service import ensure_dirs


def _configure_logging() -> None:
    """Set up logging to both stdout and a rotating file (logs/server.log).

    Verbose INFO so the user can see what's running, ERRORs include the full
    traceback because we use logger.exception() at the call sites.
    """
    log_dir = settings.LOG_DIR
    try:
        os.makedirs(log_dir, exist_ok=True)
    except OSError:
        # Termux-scoped storage can disallow creating the dir in some
        # setups — fall back to stdout-only logging rather than refusing
        # to start.
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
        )
        logging.getLogger("server").warning(
            "Could not create log dir %r — logging to stdout only", log_dir
        )
        return
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


def _verify_writable_dirs() -> None:
    """Fails fast with a clear message when a data dir is not writable.

    On Termux, running from /storage (shared Android storage) commonly fails
    here — SQLite cannot create its journal files there.
    """
    for name in ("DB_PATH", "OUTPUT_DIR", "TEMP_DIR", "LOG_DIR"):
        path = getattr(settings, name)
        folder = os.path.dirname(path) or "."
        try:
            os.makedirs(folder, exist_ok=True)
            probe = os.path.join(folder, ".write_test")
            with open(probe, "w") as f:
                f.write("ok")
            os.remove(probe)
        except OSError as e:
            raise RuntimeError(
                f"{name}={path!r} is not writable ({e}). "
                "If you are on Termux, run the server from your home "
                "directory (not /storage) or point the *_DIR / DB_PATH "
                "variables in .env somewhere writable."
            ) from e


_configure_logging()
logger = logging.getLogger("server")


@asynccontextmanager
async def lifespan(app: FastAPI):
    _verify_writable_dirs()
    await ffmpeg_service.init_encoder_profile()
    await db.init_db()
    ensure_dirs()
    # Log exactly which DB we opened and what's in it. This is the single
    # most useful line in the log for diagnosing "it re-transcribed
    # chapters that were already done" — if the counts look wrong (e.g.
    # 0 done on a book you know finished transcribing), the server opened
    # the wrong database file. See paths.py for why that could happen.
    counts = await db.job_status_counts()
    logger.info(
        "Database: %s (%s)", settings.DB_PATH,
        ", ".join(f"{k}={v}" for k, v in counts.items()) or "empty",
    )
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

    # reload=False: the reloader spawns a subprocess/watcher that behaves
    # badly on Termux (and on production hosts in general). Use
    # `uvicorn main:app --reload` explicitly when developing on a PC.
    uvicorn.run("main:app", host=settings.HOST, port=settings.PORT,
                reload=False)
