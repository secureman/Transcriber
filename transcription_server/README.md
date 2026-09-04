# Audiobook Transcription Server

Self-hosted FastAPI backend that transcribes Audiobookshelf audiobooks
chapter-by-chapter using Groq Whisper and serves WebVTT karaoke sidecar
files for the EReader Flutter app.

## Setup

1. Install ffmpeg + ffprobe (system packages).
2. Fill in `.env`:

   ```env
   ABS_BASE_URL=http://192.168.1.35:2080
   ABS_API_TOKEN=<your ABS token>
   GROQ_API_KEY=<your Groq key>
   ```

3. Install & run:

   ```bash
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   .venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port 8000
   ```

## API

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | connectivity check |
| `GET /api/metadata/{item_id}` | book metadata (ABS proxy, DB-cached) |
| `POST /api/transcribe` | enqueue jobs (`mode`: `full` / `chapter` / `range`) |
| `GET /api/jobs/{job_id}` | single job status |
| `GET /api/jobs/book/{item_id}` | all chapter statuses for a book |
| `GET /api/vtt/{item_id}/{chapter}` | serve VTT: 200 done / 202 processing / 404 never queued |

## Behaviour

- Chapters already `done` are never re-transcribed (cache: `vtt_cache/{item_id}/chapter_N.vtt`).
- `MAX_CONCURRENT_JOBS` (default 2) Groq calls in parallel via semaphore.
- Chapters > 24 MB are split into ~20 MB chunks with 8s overlap; overlapping words are trimmed on merge.
- Chapters spanning multiple audio files are extracted piecewise and concatenated with ffmpeg.
- Tmp audio is cleaned up after every job (success or failure).
