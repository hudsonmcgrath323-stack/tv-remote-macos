#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.env"
    set +a
fi

DEFAULT_APP_SUPPORT="$HOME/Library/Application Support/TVRemote"
VENV_DIR="${TVREMOTE_VENV_DIR:-$DEFAULT_APP_SUPPORT/venv}"
PYTHON_BIN="${TVREMOTE_PYTHON_BIN:-}"

if [ -z "$PYTHON_BIN" ]; then
    # Prefer Python 3.11-3.13 for prebuilt C-extension wheels (miniaudio/cryptography)
    for candidate in \
        /opt/homebrew/bin/python3.13 \
        /opt/homebrew/bin/python3.12 \
        /opt/homebrew/bin/python3.11 \
        /opt/homebrew/bin/python3 \
        /usr/local/bin/python3 \
        /usr/bin/python3; do
        if [ -x "$candidate" ]; then
            PYTHON_BIN="$candidate"
            break
        fi
    done
fi

if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    echo "Error: Python 3 not found. Install Python 3 via Homebrew (brew install python@3.12) or set TVREMOTE_PYTHON_BIN." >&2
    exit 1
fi

echo "Using Python interpreter: $PYTHON_BIN ($("$PYTHON_BIN" --version))"
mkdir -p "$(dirname "$VENV_DIR")"

if [ ! -x "$VENV_DIR/bin/python3" ]; then
    echo "Creating virtual environment at $VENV_DIR..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

echo "Installing Python dependencies from requirements.txt..."
"$VENV_DIR/bin/pip" install --upgrade pip wheel >/dev/null
"$VENV_DIR/bin/pip" install --upgrade -r "$PROJECT_ROOT/requirements.txt"

echo "pyatv installed successfully: $("$VENV_DIR/bin/python3" -c 'import importlib.metadata; print(importlib.metadata.version("pyatv"))')"
