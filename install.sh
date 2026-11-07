#!/bin/bash
# Set up Hark from a fresh clone: Python environment for the speech-to-text server, then build.sh.
# Needs Apple Silicon (MLX), Xcode Command Line Tools (swiftc) and internet (uv + Python packages).
# Models are downloaded later from Settings -> Models.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

[ "$(uname -m)" = arm64 ] || { echo "Hark needs a Mac with Apple Silicon (M1 or later): MLX does not run on Intel."; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found. Install the Command Line Tools: xcode-select --install, then run this again."; exit 1; }

cd "$ROOT"
# uv brings its own Python 3.13: the system python3 is too old for numpy/mlx.
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
[ -x .venv/bin/python ] || uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python -r requirements.txt

./build.sh
open "$HOME/Applications/Hark.app"
echo "Done. Hark is in the menu bar. Grant Microphone and Accessibility access when asked, then pick a model in Settings."
