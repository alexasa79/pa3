#!/bin/bash
set -euo pipefail

EXTENSION_ID="cjihffoodggjaecnpiiciehbgkacnmkp"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY_PATH="$ROOT_DIR/native/bin/reedah-sayer"
MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_PATH="$MANIFEST_DIR/com.reedah.sayer.json"

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Native host binary not found. Build it first: ./scripts/build_native_host.sh"
  exit 1
fi

mkdir -p "$MANIFEST_DIR"

cat > "$MANIFEST_PATH" <<JSON
{
  "name": "com.reedah.sayer",
  "description": "Reedah macOS narration host",
  "path": "$BINARY_PATH",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON

echo "Installed native host manifest to: $MANIFEST_PATH"
