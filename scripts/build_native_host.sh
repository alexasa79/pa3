#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/native/bin"
HOST_SOURCE="$ROOT_DIR/native/reedah_native_host.py"
WORKER_SOURCE="$ROOT_DIR/native/kokoro_worker.py"
OUTPUT="$OUTPUT_DIR/reedah-sayer"
WORKER_OUTPUT="$OUTPUT_DIR/kokoro_worker.py"

mkdir -p "$OUTPUT_DIR"

if [[ ! -f "$HOST_SOURCE" ]]; then
  echo "Native host source not found: $HOST_SOURCE"
  exit 1
fi

if [[ ! -f "$WORKER_SOURCE" ]]; then
  echo "Kokoro worker source not found: $WORKER_SOURCE"
  exit 1
fi

cp "$HOST_SOURCE" "$OUTPUT"
chmod +x "$OUTPUT"
cp "$WORKER_SOURCE" "$WORKER_OUTPUT"
chmod +x "$WORKER_OUTPUT"

echo "Built native host at: $OUTPUT"
