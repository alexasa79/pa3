#!/bin/bash
set -euo pipefail

EXTENSION_ID="${1:-cjihffoodggjaecnpiiciehbgkacnmkp}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST_PATH="$ROOT_DIR/native/reedah_native_host.py"
WORKER_PATH="$ROOT_DIR/native/kokoro_worker.py"
MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_PATH="$MANIFEST_DIR/com.reedah.sayer.json"

if [[ ! -f "$HOST_PATH" ]]; then
  echo "Native host file not found: $HOST_PATH"
  exit 1
fi

if [[ ! -f "$WORKER_PATH" ]]; then
  echo "Kokoro worker file not found: $WORKER_PATH"
  exit 1
fi

chmod +x "$HOST_PATH"
chmod +x "$WORKER_PATH"

if [[ ! -x "$HOST_PATH" ]]; then
  echo "Native host is not executable: $HOST_PATH"
  exit 1
fi

mkdir -p "$MANIFEST_DIR"

cat > "$MANIFEST_PATH" <<JSON
{
  "name": "com.reedah.sayer",
  "description": "Reedah Kokoro Python host",
  "path": "$HOST_PATH",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON

echo "Installed native host manifest to: $MANIFEST_PATH"
echo "Native host path: $HOST_PATH"
