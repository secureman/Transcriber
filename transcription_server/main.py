from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import database as db
from config import settings
from routers import metadata, queue, transcribe, vtt
from services import queue as job_queue
from services.ffmpeg_service import ensure_dirs


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.init_db()
    ensure_dirs()
    # Resets rows stuck in 'processing' (from a previous crash) to 'pending'
    # and starts the durable worker pool so transcription continues even if
    # the client backgrounds/closes the app.
    await job_queue.ensure_started_on_boot()
    yield
    await job_queue.stop_workers()


app = FastAPI(title="Audiobook Transcription Server", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(transcribe.router, prefix="/api")
app.include_router(vtt.router, prefix="/api")
app.include_router(metadata.router, prefix="/api")
app.include_router(queue.router, prefix="/api")


@app.get("/api/health")
async def health() -> dict:
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host=settings.HOST, port=settings.PORT,
                reload=True)
