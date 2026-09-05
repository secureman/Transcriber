#!/data/data/com.termux/files/usr/bin/bash
# Starts the transcription server under Termux (also works on any PC).
#
#   bash run_termux.sh
#
# Logs: ~/.local/share/audiobook-transcriber/logs/server.log

set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
  echo "No .venv found — running setup first…"
  bash setup_termux.sh
fi

# shellcheck disable=SC1091
source .venv/bin/activate
exec python main.py
