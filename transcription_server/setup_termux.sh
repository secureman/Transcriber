#!/data/data/com.termux/files/usr/bin/bash
# Termux setup for the Audiobook Transcription Server.
#
# Run inside Termux, from the extracted repo folder:
#   bash setup_termux.sh
#
# Installs the system packages (Python, ffmpeg) and the Python dependencies,
# then creates a ready-to-edit .env. Data (DB, VTT cache, temp audio, logs)
# lives in ~/.local/share/audiobook-transcriber — always writable, unlike
# shared Android storage.

set -euo pipefail

echo "==> Updating Termux packages"
pkg update -y

echo "==> Installing python, ffmpeg and git (if missing)"
pkg install -y python ffmpeg git

echo "==> Creating a virtualenv"
python -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate

echo "==> Installing Python dependencies"
pip install --upgrade pip wheel
pip install -r requirements.txt

echo "==> Creating .env (edit it to point at your ABS server)"
if [ ! -f .env ]; then
  cp .env.example .env
  echo "    Created .env from .env.example — open it and set ABS_BASE_URL,"
  echo "    ABS_API_TOKEN and GROQ_API_KEY."
else
  echo "    .env already exists — leaving it alone."
fi

mkdir -p "$HOME/.local/share/audiobook-transcriber"

echo ""
echo "Setup complete. Start the server with:"
echo "  bash run_termux.sh"
echo "or:"
echo "  source .venv/bin/activate && python main.py"
