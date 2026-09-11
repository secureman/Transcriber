# AGENTS.md — E-READER (Echoread)

> **Purpose of this file:** a complete working map of this repo and its
> sibling backend so any agent (or human) can be productive immediately.
> Keep it up to date when features, endpoints, or cache keys change.

## What this project is

**Echoread** is a Flutter client for a self-hosted
[Audiobookshelf](https://www.audiobookshelf.org/) server with a karaoke
word-by-word read-along ("transcript") view. It plays real narration audio
from ABS and highlights each spoken word using WebVTT transcripts generated
by a self-hosted backend (Groq Whisper).

Two servers are involved:

| Server | Location | Role | Required? |
|---|---|---|---|
| **Audiobookshelf (ABS)** | external (your NAS/PC) | streams audiobooks, item metadata, playback progress | required for playback |
| **audiobook-server** (unified backend) | `../audiobook-server` (sibling repo) | accounts (JWT), progress sync, metadata proxy, Groq Whisper transcription jobs, VTT serving | **optional** — app degrades gracefully without it |

The repo also contains a **legacy, standalone copy** of the transcription
half in `transcription_server/` (port 8000). The unified server
(`../audiobook-server`, port **8001**) is the current one; the legacy folder
is kept for the Termux one-click scripts and old installs. Prefer the
unified server for all new work.

## Commands

```bash
# Flutter app (this repo)
flutter pub get
flutter run
flutter analyze        # must stay clean — 0 errors
flutter test           # unit tests in test/

# Unified backend (../audiobook-server)
cd ../audiobook-server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
# configure .env — JWT_SECRET is REQUIRED
.venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port 8001
# Swagger docs: http://<host>:8001/docs
# smoke tests: BASE=http://127.0.0.1:8001 bash tests/smoke_metadata.sh
```

The app is pointed at both servers in the in-app **Setup screen**
(first launch) or **Settings**; values persist via `shared_preferences`
(`abs_url`, `abs_token`, `server_url`).

## Architecture map (Flutter app)

```
lib/
  main.dart                 entry: SharedPreferences + AudioService.init, ProviderScope overrides
  app.dart                  GoRouter: /setup, /, /book/:id, /settings, /player/:id/:chapterIndex
  core/
    network/                one Dio client per concern (all keyed off configProvider)
      abs_client.dart         → ABS (streams audio, item fetch, progress PATCH)
      backend_client.dart     → unified backend (10s connect / 60s receive timeout)
      metadata_client.dart    → legacy metadata-server client (kept for migration)
      progress_sync.dart      → unified-server progress sync (mirrors old ABS /api/me/progress)
    providers/
      config_provider.dart      AppConfig (absUrl/absToken/serverUrl) + configRevisionProvider
      shared_prefs_provider.dart SharedPreferences injection (overridden in main.dart)
      playback_progress_provider.dart local "where was I" store (chapter + seconds, per book)
      read_chapters_provider.dart   listened-chapter set (server sync + local mirror)
      reader_theme_provider.dart    read-along themes (sepia/dark/etc.)
      vtt_download_provider.dart    bulk "Download transcripts" controller (see below)
    offline/
      offline_provider.dart   OfflineController: download whole book / single chapters
                              (parallel workers, resumable, cancellable) + _cacheVttsFor bulk VTT cache
      offline_db.dart         sqflite `offline_books.db` — offline_books + offline_chapters tables
    utils/vtt_parser.dart     WebVTT → List<VttCue> (karaoke <ts><c>word</c> tags), binary search
    theme/app_theme.dart      AppColors, typography — the only colors the UI may use
    widgets/cover_image.dart  cached cover art w/ placeholder
  features/
    library/                  home screen (continue card, offline banner, book grid)
    book_detail/              detail screen: READ ALONG, DownloadControl (audio),
                              VttDownloadControl (transcripts), chapter list + per-chapter
                              transcribe status, TranscribeSheet (incl.
                              per-chapter picker), Transcribe FAB
    player/                   THE core feature (see below)
    settings/                 server URLs, token, sign-out
    setup/                    first-run configuration wizard
  models/
    abs_item.dart             AbsItem/AbsChapter/AbsAudioFile parsed from ABS JSON
    vtt_cue.dart              VttCue/VttWord/VttWordRef
    metadata_progress.dart    progress payloads for the unified server
```

### Player feature (lib/features/player/) — read this before touching VTT logic

- `player_state.dart` — immutable `PlayerState` + `VttStatus { loading,
  ready, notFound, transcribing, error }`, `servedFromCache` flag,
  `transcribeProgress` (0..1 from the backend's 202).
- `audio_handler.dart` — `BaseAudioHandler`; playlist of
  `ClippingAudioSource`s (current + prefetched next chapter) so chapters end
  exactly on the clip boundary and auto-advance fires.
- `player_provider.dart` — `PlayerController` (global `Notifier`), the heart
  of the app:
  - `_loadAudio` builds the playlist; `currentIndexStream`==1 detects
    playlist auto-advance → `_onChapterEnd(advanced: true)` rebuilds the
    queue with the next two chapters.
  - Positions are kept in **seconds since chapter start**. A resume that
    skips ahead mid-chapter sets `_chapterOffsetSeconds`
    (ClippingAudioSource reports position relative to its own `start`), and
    every raw position tick / seek target is corrected by it. VTT cue
    timestamps, the scrubber, and whole-book ABS progress math all assume
    this.
  - ABS progress sync is throttled with exponential backoff (10s → … → 5m
    cap) and self-recovers when the server returns; local progress is saved
    every ~5s regardless so a hard kill loses <5s.
  - **VTT loading (`_loadVtt`) — cache-first (BUG FIX v2)**: when a cached
    copy exists (prefs `vtt_{itemId}_{chapterIndex}`) it is applied
    INSTANTLY, even while online; the backend GET still runs as a
    background revalidate — a 200 with different text replaces cache +
    cues (server-side re-transcriptions flow through), 202/404/errors
    leave the shown cache untouched. With no cache the classic flow
    applies unchanged (202 → poll, 404 → notFound, network error → 45s
    one-shot retry). Bulk "Download transcripts" therefore eliminates the
    per-chapter-switch network round-trip entirely.
  - **Chapter auto-advance (BUG FIX v2)** — end-of-chapter is now detected
    two ways that collapse into one advance: (1) the classic
    `currentIndexStream == 1` playlist transition, and (2) a position-based
    fallback `_checkClipEndFallback` that fires when the raw clip position
    reaches `chapterDuration − 300ms` while playing (one-sided window — a
    stalled final tick must still fire). A once-per-chapter guard
    (`_clipEndFiredChapter`, re-armed in `init()` and after each playlist
    rebuild) prevents double-advance. The rebuild path also resumes
    playback when `setAudioSources` was called while playing (it pauses and
    resets the player), which previously left the app silently paused at
    0:00 of the next chapter.
  - **Prefetch depth & buffer (BUG FIX v2)** — the end-of-chapter playlist
    rebuild queues **3 sources** (current + next 2 chapters; resolveClipBounds
    returns empty for file-spanning chapters, which just skips that slot).
    `AudioLoadControl` keeps a 120 s forward buffer (was 60 s) on Android and
    Darwin — cheap insurance against slow-ABS chapter-boundary stalls.
  - **Buffering surfacing (BUG FIX v2)** — `PlayerState.buffering` is
    derived from `processingStateStream` (`== ProcessingState.buffering`,
    `.distinct()`; there is no `bufferingStream` getter on just_audio's
    AudioPlayer) and shows a spinner on the play/pause button
    (`audio_controls.dart`) so a slow ABS fetch reads as loading, not
    frozen. Subscription lives in `init()`, cancelled alongside the others.
  - **Chapter-transition indicator (BUG FIX v2)** — `PlayerState.advancing`
    flips on in `_onChapterEnd` (before the deferred rebuild) and is cleared
    in `_advancePlaylist`'s `finally` (success, bail, or failure — can never
    stick). UI: a "Loading next chapter…" pill (`_AdvancingPill`, stacked
    overlay in `player_screen.dart`, top: 16 in fullscreen / 76 otherwise)
    plus a spinner on the play button, whose tap is disabled during the
    rebuild so pause/play can't race the queue swap. This covers the silent
    window between "current clip ended" and "next clip prepared" that read
    as a crash on slow ABS servers.
  - **VTT loading (`_loadVtt`)** — the critical cache contract:
    - SharedPreferences keys `vtt_{itemId}_{chapterIndex}` hold the RAW VTT
      text (typically 100–400 KB each; written by `_writeCache` on every
      successful 200, and bulk by offline download's `_cacheVttsFor`).
    - Request flow (cache-first, BUG FIX v2 — see the cache-first bullet
      above): cached text is applied instantly, then the GET revalidates —
      200 → rewrite cache + apply if text changed; 202/404/500 → leave the
      shown cache alone (only poll/progress-UI when there was NO cache);
      network error → no-op with cache, else arm a **one-shot 45 s retry
      timer** (`_vttRetryTimer`) that re-runs `_loadVtt` (transcription may
      finish server-side meanwhile). All retry guards are stale-checked
      (itemId/chapterIndex must still match).
    - `reloadCurrentVtt()` — public hook used by the "Download transcripts"
      action to re-run `_loadVtt` for the current chapter after a bulk
      cache.
- `player_screen.dart` — screen + AppBar (fullscreen toggle, quick theme,
  overflow menu with **Download transcripts** tile `_VttDownloadTile`) +
  `_ReaderContainer`, chapter scrubber, controls, accessory row.
  - **Fullscreen wakelock (BUG FIX v2)** — entering fullscreen read-along
    holds a screen wakelock via `wakelock_plus` (`WakelockPlus.enable()`),
    toggled alongside the `SystemChrome.setEnabledSystemUIMode` listener
    (only fires when `fullscreenReader` flips). `dispose()` always calls
    `WakelockPlus.disable()` as a safety net, so popping the player by any
    path (deep-link, system pop) can't leave the display pinned on.
    Normal (non-fullscreen) player never holds the wakelock — screen
    timeout behaves as usual there.
  - **Fullscreen progress strip (BUG FIX v2)** — `_ProgressStripPainter`
    takes `isDark` from `ReaderThemeData`. Fill is full-strength accent on
    light themes (Snow/Parchment washed out under the old 0.32-alpha
    gradient) and a high floor alpha on dark themes; track contrast is
    resolved per theme darkness. The bright core is anchored at the fill
    tip (the playhead), so it reaches the strip's end exactly when the
    chapter ends (the old gradient peaked at the fill's midpoint).
- `widgets/reading_view.dart` — the karaoke text: ScrollablePositionedList,
  auto-follow with 3 anti-jitter guards (`_atEnd`, drag-detect suspend,
  resync button), word highlight via `flatWords` binary search.

### Offline model (server down ≠ broken app)

Downloaded books play with **zero** connection: raw ABS item JSON is stored
in sqflite, audio files on disk named by `AbsAudioFile.offlineFilename`
(ino-based, stable). The player resolves clips to local files when the book
is offline. Read-along text has its own cache (`vtt_{itemId}_{ch}` prefs
keys) that is filled by: playing a chapter while the backend is up, the
offline download's `_cacheVttsFor` (backend up at download time), or the
manual **Download transcripts** action (`vtt_download_provider.dart`).

## The backend (../audiobook-server) — one FastAPI process, two halves

```
audiobook-server/
  main.py                 FastAPI app + router mounting + CORS
  config.py               pydantic settings (.env): HOST/PORT, JWT_SECRET (required),
                          ABS_BASE_URL/ABS_API_TOKEN, GROQ_API_KEY, OUTPUT_DIR, ...
  paths.py                data-dir resolution (Termux-aware)
  database.py             metadata.db (users, book_progress, chapter_done, chapter_position)
  transcription_database.py  transcriptions.db (jobs) — separate SQLite DB
  transcription_models.py TranscribeRequest {abs_item_id, mode: full|chapter|range,
                          chapter_index, from_chapter, count}, JobStatus
  security.py             JWT + PBKDF2
  routers/
    auth.py               /api/auth/*  (register/login/me)
    progress.py           /api/progress/* (book + per-chapter positions)
    metadata.py           /api/metadata/{item_id}  ABS proxy w/ ABS-side caching
    transcribe.py         POST /api/transcribe, GET /api/jobs/{job_id},
                          /api/jobs/book/{item_id}, /api/jobs/active
    vtt.py                GET /api/vtt/{abs_item_id}/{chapter_index}
  services/
    abs_client.py         httpx client to ABS
    queue.py              in-process job queue (claim/priority)
    job_runner.py         ffmpeg chunking → Groq Whisper → VTT
    groq_client.py        Whisper API calls
    vtt_builder.py        word-timestamps → WebVTT karaoke text
  vtt_cache/              OUTPUT_DIR: vtt_cache/{abs_item_id}/chapter_{i}.vtt
  tmp_audio/              TEMP_DIR: chunked audio during jobs
```

Key endpoint contract used by the app:

- `POST /api/transcribe` — body `{abs_item_id, mode: full|chapter|range|custom,
  chapter_index?, from_chapter?, count?, chapters?}`; `full` is bulk priority 0,
  explicit chapter/range/custom requests jump the queue (priority 10).
  `custom` requires `chapters: [int, ...]` (validated, deduped, sorted).
- `GET /api/vtt/{item}/{ch}` — **200** `text/vtt` when done (or when an
  on-disk file exists even if the job row is in error); **202**
  `{"status":"processing","progress":0..1}` while running; **404** never
  queued & no file; **500** failed & no file. The 202's progress field is
  already 0..1 — do NOT divide by 100 (that was a v1 bug, fixed).
- `GET /api/jobs/book/{item_id}` — `{"book_id", "chapters": [{chapter_index,
  status, progress(0..100), priority, vtt_url?}...]}` — the app tolerates
  list, map, or flat-map shapes when parsing (see
  `book_detail_provider.dart` and `vtt_download_provider.dart`).

## Cross-cutting conventions

- **Riverpod**: classic manual providers (`Notifier`/`NotifierProvider`,
  `FutureProvider.family`). No codegen for providers despite
  `riverpod_generator` being present. Family notifiers extend
  `FamilyNotifier<State, Arg>` (State first!) and implement
  `State build(Arg arg)`.
- **State mutation**: never mutate `state` fields; always
  `state = state.copyWith(...)`. `copyWith(clearWord: true)` clears the
  word cursor (needed at chapter boundaries).
- **Comment style**: files carry long doc-comments explaining *why*
  (historical bug fixes are labeled "BUG FIX v1" — do not regress them).
- **Colors**: only `AppColors` from `core/theme/app_theme.dart`. Reader
  themes come from `reader_theme_provider.dart`.
- **SharedPreferences keys in use** (treat as a registry — don't collide):
  `abs_url`, `abs_token`, `server_url`, legacy `backend_url` /
  `metadata_url` (migrated + removed), `last_played_chapter_{itemId}`,
  `playback_speed`, `reading_font_size`, `chapter_bookmarks_v1`,
  `vtt_{itemId}_{chapterIndex}` (raw VTT text cache), plus the
  progress keys from `playback_progress_provider.dart`.
- **Networking**: `backendClientProvider` has `validateStatus < 500`, so
  check `statusCode` explicitly (404/202/500 are *returned*, not thrown).
  Only connection-level failures throw `DioException`.
- **Error messages**: user-facing failure strings mimic
  `offline_provider._friendlyError` (timeouts, unreachable, server error
  with code).
- **Android networking**: cleartext HTTP to LAN hosts is allowed via
  `android/app/src/main/res/xml/network_security_config.xml`. Domain
  elements only match exact hostnames, not CIDR subnets.

## AGENT RULES

- **Always update AGENTS.md** at the end of any task that changes features,
  endpoints, cache keys, architecture, or conventions — describe what you
  did and how you achieved it (files touched, approach, gotchas). If you
  only answered a question without changing code, state that explicitly
  instead of editing this file.

## Feature: Choose chapters to transcribe — added 2026-09

Adds a fourth option in the TranscribeSheet ("Choose chapters…") that opens
a multi-select chapter picker; the chosen indices are sent to the backend
as an explicit list.

How it works:

- `book_detail_provider.dart` — `TranscribeMode.custom = 'custom'`;
  `TranscribeController.start()` gained `chapterIndices`, sent as
  `{mode: 'custom', chapters: [sorted indices]}`. Empty selection is
  rejected client-side with "No chapters selected".
- `transcribe_sheet.dart` — "Choose chapters…" option whose detail line
  shows the live count (`N chapters selected`). Tapping it opens
  `_ChapterPickerSheet` (bottom sheet, watches `bookDetailProvider` for
  titles, checkbox rows, All/None toggle, confirmation button
  "TRANSCRIBE N CHAPTERS" that pops with the `Set<int>`). Selecting it as
  the radio option also auto-opens the picker; START with no selection
  re-opens the picker, and dismissing with zero picks blocks START with a
  snackbar.
- Backend (`../audiobook-server`):
  - `transcription_models.py` — `TranscribeRequest.mode` now also allows
    `"custom"`, with optional `chapters: list[int]`.
  - `routers/transcribe.py` — `_resolve_indices()` handles `custom`
    (validates range 0..total-1, dedupes, sorts, 422 on empty/out-of-range)
    and `custom` gets `PRIORITY_USER` (jumps the bulk queue) like explicit
    chapter/range requests. Response shape unchanged
    (`{enqueued, already_done, job_ids}`).

## Feature: Download transcripts (VTT) — added 2026-09

Lets the user explicitly cache every `done` chapter's VTT so the read-along
keeps working when the backend is down (playback itself always continues
via ABS). Files:

- `lib/core/providers/vtt_download_provider.dart` — `VttDownloadController`
  (family by itemId): `start(itemId, {force})` GETs `/api/jobs/book/{id}`,
  then fetches `/api/vtt/{id}/{ch}` for each `done` chapter and writes the
  prefs cache. Skips already-cached chapters unless `force`. State:
  `{status: idle|running|success|error, totalCount, doneCount,
  alreadyCached, error}`. Per-chapter fetch failures don't abort the run.
- `lib/features/book_detail/widgets/vtt_download_control.dart` —
  `VttDownloadControl`: tonal button under the audio `DownloadControl`
  (progress card while running, snackbar with counts on finish).
- `lib/features/player/player_screen.dart` — `_VttDownloadTile` in the
  overflow menu (same controller; after success calls
  `playerProvider.notifier.reloadCurrentVtt()` so the current chapter's
  text appears immediately).

## Verification checklist for agent changes

1. `flutter analyze` → 0 issues.
2. `flutter test` → all pass (VTT parser, duration ext, progress store,
   widget tests).
3. If touching player/VTT/offline: trace the **backend-down** path — no
   `dio` exceptions may crash the UI; cache fallbacks must still apply.
4. If touching the backend: restart uvicorn and check `GET /api/health`,
   then run the smoke script.
