#!/bin/bash
set -euo pipefail

EXTENSION_ID="${1:?Usage: install_native_host.sh <chrome-extension-id>}"
if [[ ! "$EXTENSION_ID" =~ ^[a-p]{32}$ ]]; then
  echo "Expected a Chrome extension ID (32 lowercase letters a-p)." >&2
  exit 1
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
HOST_PATH="$ROOT_DIR/native/reedah_native_host.py"
MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_PATH="$MANIFEST_DIR/com.reedah.sayer.json"

if [[ ! -f "$HOST_PATH" ]]; then
  echo "Native host file not found: $HOST_PATH"
  exit 1
fi

chmod +x "$HOST_PATH"

if [[ ! -x "$HOST_PATH" ]]; then
  echo "Native host is not executable: $HOST_PATH"
  exit 1
fi

mkdir -p "$MANIFEST_DIR"

cat > "$MANIFEST_PATH" <<JSON
{
  "name": "com.reedah.sayer",
  "description": "Reedah PA3 bridge",
  "path": "$HOST_PATH",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON

echo "Installed native host manifest to: $MANIFEST_PATH"
echo "Native host path: $HOST_PATH"
