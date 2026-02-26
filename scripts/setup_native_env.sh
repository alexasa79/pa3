#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="$ROOT_DIR/native/.venv"
PYTHON_BIN="$VENV_DIR/bin/python"
PIP_BIN="$VENV_DIR/bin/pip"
REQ_FILE="$ROOT_DIR/native/requirements.txt"
PREFLIGHT_SCRIPT="$ROOT_DIR/native/check_native_env.py"

if [[ ! -f "$REQ_FILE" ]]; then
  echo "Missing requirements file: $REQ_FILE"
  exit 1
fi

if [[ ! -f "$PREFLIGHT_SCRIPT" ]]; then
  echo "Missing preflight script: $PREFLIGHT_SCRIPT"
  exit 1
fi

if [[ ! -d "$VENV_DIR" ]]; then
  echo "Creating virtual environment: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Failed to create Python executable at: $PYTHON_BIN"
  exit 1
fi

echo "Installing native host dependencies from: $REQ_FILE"
"$PIP_BIN" install --upgrade pip
"$PIP_BIN" install -r "$REQ_FILE"

echo "Ensuring spaCy English model is installed (en_core_web_sm)"
if ! "$PYTHON_BIN" -c "import spacy.util, sys; sys.exit(0 if spacy.util.is_package('en_core_web_sm') else 1)"; then
  "$PYTHON_BIN" -m spacy download en_core_web_sm
fi

echo "Running pip dependency integrity checks"
if ! "$PYTHON_BIN" -m pip check; then
  echo "pip dependency check failed. See errors above."
  exit 1
fi

echo "Running native environment preflight checks"
if ! "$PYTHON_BIN" "$PREFLIGHT_SCRIPT"; then
  echo "Native environment preflight failed. See errors above."
  exit 1
fi

echo "Native environment ready: $PYTHON_BIN"
