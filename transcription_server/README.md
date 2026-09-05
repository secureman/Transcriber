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

## Hosting on Termux (Android)

The server runs on an Android phone or tablet via Termux — useful when you
don't want a PC running 24/7.

### One-time setup

1. Install [Termux](https://f-droid.org/en/packages/com.termux/) (F-Droid
   build; the Play Store version is outdated).
2. Copy or clone this `transcription_server` folder into Termux **home**
   (`~/transcription_server`) — e.g.
   `pkg install git && git clone <repo-url> transcription_server`.
   Do **not** run it from `/storage/...` (shared storage): SQLite needs to
   create journal files, which Android's FUSE mount forbids. The server
   detects this at startup and tells you exactly what's wrong.
3. Inside Termux:

   ```bash
   cd ~/transcription_server
   bash setup_termux.sh        # installs python, ffmpeg, deps, creates .env
   nano .env                   # set ABS_BASE_URL, ABS_API_TOKEN, GROQ_API_KEY
   ```

4. Start it:

   ```bash
   bash run_termux.sh          # or: source .venv/bin/activate && python main.py
   ```

   Your phone's browser or the Flutter app can then reach it on
   `http://<phone-ip>:8000` (Wi-Fi LAN).

### Where data lives on Termux

| What | Default location |
|---|---|
| Database | `~/.local/share/audiobook-transcriber/transcriptions.db` |
| VTT cache | `~/.local/share/audiobook-transcriber/vtt_cache/` |
| Temp audio | `~/.local/share/audiobook-transcriber/tmp_audio/` |
| Logs | `~/.local/share/audiobook-transcriber/logs/server.log` |

Override any of these with `DB_PATH`, `OUTPUT_DIR`, `TEMP_DIR`, `LOG_DIR`
in `.env` (see `.env.example`). Binaries resolve from the Termux prefix
automatically; you can also pin them with `FFMPEG_PATH` / `FFPROBE_PATH`.

### Keeping it running

- **wake-lock** (prevents Android from freezing the server):
  `pkg install termux-api && termux-wake-lock`
- **sv-enable** first if `termux-wake-lock` says command not found.
- **autostart on boot**: install `Termux:Boot`, then create
  `~/.termux/boot/start-server` containing
  `#!/data/data/com.termux/files/usr/bin/bash` +
  `bash ~/transcription_server/run_termux.sh`.
- **acquire wake-lock from the app itself**: Termux notification →
  "Acquire wakelock".

### Notes & limits

- `libmp3lame` is probed at startup; Termux's ffmpeg ships it, but if a
  minimal build doesn't, extraction transparently falls back to AAC
  (transcription quality is unaffected — Groq accepts both).
- Screen-off may still throttle long transcriptions; the wake-lock and
  disabling battery optimisation for Termux both help.
- The app connects to the server the same way as before — set the backend
  URL in the app's settings to `http://<phone-ip>:8000`.
