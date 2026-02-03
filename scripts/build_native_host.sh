#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/native/bin"
SOURCE="$ROOT_DIR/native/reedah-sayer/main.swift"
OUTPUT="$OUTPUT_DIR/reedah-sayer"

mkdir -p "$OUTPUT_DIR"

swiftc -O -Xfrontend -disable-availability-checking -o "$OUTPUT" "$SOURCE" \
  2> >(grep -v "#DeprecatedDeclaration" | grep -v "deprecated in macOS 14.0" >&2)

echo "Built native host at: $OUTPUT"
