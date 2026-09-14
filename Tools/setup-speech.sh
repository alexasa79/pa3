#!/bin/sh
# Install verified speech model data. The runtimes come from Homebrew.
set -eu
cd "$(dirname "$0")/.."
pa3_models="${PA3_MODEL_DIR:-$HOME/Library/Application Support/PA3/models}"
mkdir -p "$pa3_models/qwen3-tts"
pa3_staging=$(mktemp -d "$pa3_models/.setup.XXXXXX")
trap 'rm -rf "$pa3_staging"' EXIT HUP INT TERM

matches() {
    [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" = "$2" ]
}
install_model() {
    destination=$1
    checksum=$2
    url=$3
    reuse=${4:-}
    if matches "$destination" "$checksum"; then
        echo "Ready: $destination"
        return
    fi
    staged="$pa3_staging/$(basename "$destination")"
    if [ -n "$reuse" ] && matches "$reuse" "$checksum"; then
        cp -L "$reuse" "$staged"
    else
        echo "Downloading $(basename "$destination")"
        curl --fail --location --retry 3 --progress-bar "$url" -o "$staged"
    fi
    if ! matches "$staged" "$checksum"; then
        echo "Checksum mismatch: $(basename "$destination")" >&2
        exit 1
    fi
    mv -f "$staged" "$destination"
    echo "Ready: $destination"
}

install_model "$pa3_models/whisper.ggml" \
    1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69 \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin \
    models/whisper.ggml

qwen_url=https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF/resolve/ca27d74bc954b73dadab5b71ca265d87fc861a7c
install_model "$pa3_models/qwen3-tts/Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf" \
    ac7931aeb2e7aad1a6ed6602d353a5679c9d096b18ce8204ac730a8408d572e1 \
    "$qwen_url/Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf"
install_model "$pa3_models/qwen3-tts/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf" \
    6fd65188839bcd6ecc91b277ad471e22a0edfada4699a0fe82f1165c18cfcce2 \
    "$qwen_url/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf"
