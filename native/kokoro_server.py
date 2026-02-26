#!/usr/bin/env python3
"""HTTP TTS server for Reedah. Loads Kokoro model once and serves requests."""

from __future__ import annotations

import argparse
import base64
import contextlib
import json
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from kokoro_worker import (
    DEFAULT_LANG_CODE,
    DEFAULT_MODEL,
    DEFAULT_SPEED,
    DEFAULT_VOICE,
    normalize_jobs,
)

DEFAULT_PORT = 7865


def log(message: str) -> None:
    print(f"ReedahServer: {message}", file=sys.stderr, flush=True)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Reedah Kokoro TTS HTTP server.")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Server port.")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="mlx-audio model repo/path.")
    parser.add_argument("--voice", default=DEFAULT_VOICE, help="Default Kokoro voice preset.")
    parser.add_argument("--speed", type=float, default=DEFAULT_SPEED, help="Default speed multiplier.")
    parser.add_argument("--lang-code", default=DEFAULT_LANG_CODE, help="Default Kokoro language code.")
    return parser.parse_args(argv)


def load_model(model_id: str) -> Any:
    log(f"Loading model: {model_id}")
    from mlx_audio.tts import load as load_tts_model

    with contextlib.redirect_stdout(sys.stderr):
        model = load_tts_model(model_id)
    log("Model loaded.")
    return model


def generate_sentence_audio(
    job: dict[str, Any],
    output_dir: Path,
    model: Any,
    voice: str,
    speed: float,
    lang_code: str,
) -> dict[str, Any]:
    """Generate audio for a single sentence job. Returns an event dict with base64 audio."""
    from mlx_audio.tts.generate import generate_audio

    prefix = f"sentence-{job['index']}"
    output_file = output_dir / f"{prefix}.wav"
    if output_file.exists():
        output_file.unlink()

    with contextlib.redirect_stdout(sys.stderr):
        generate_audio(
            text=job["text"],
            model=model,
            voice=voice,
            speed=speed,
            lang_code=lang_code,
            output_path=str(output_dir),
            file_prefix=prefix,
            audio_format="wav",
            join_audio=True,
            play=False,
            stream=False,
            verbose=False,
        )

    if not output_file.exists():
        raise RuntimeError(f"Audio file was not generated for sentence index {job['index']}.")
    if output_file.stat().st_size == 0:
        raise RuntimeError(f"Audio file is empty for sentence index {job['index']}.")

    audio_bytes = output_file.read_bytes()
    output_file.unlink()

    return {
        "event": "audio",
        "index": job["index"],
        "location": job["location"],
        "length": job["length"],
        "audioBase64": base64.b64encode(audio_bytes).decode("ascii"),
        "mimeType": "audio/wav",
    }


class TTSHandler(BaseHTTPRequestHandler):
    server: TTSServer

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        log(f"{self.address_string()} {format % args}")

    def _send_json(self, status: int, body: dict[str, Any]) -> None:
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _write_ndjson_line(self, event: dict[str, Any]) -> None:
        line = json.dumps(event, separators=(",", ":")).encode("utf-8") + b"\n"
        self.wfile.write(line)
        self.wfile.flush()

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(200, {
                "status": "ready",
                "model": self.server.model_id,
            })
            return
        self._send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.path == "/tts":
            self._handle_tts()
            return
        self._send_json(404, {"error": "not_found"})

    def _handle_tts(self) -> None:
        content_length = self.headers.get("Content-Length")
        if not content_length:
            self._send_json(400, {"error": "missing_content_length"})
            return

        try:
            body = json.loads(self.rfile.read(int(content_length)))
        except (json.JSONDecodeError, ValueError) as exc:
            self._send_json(400, {"error": "invalid_json", "details": str(exc)})
            return

        utterance_id = body.get("utteranceId", "")
        if not isinstance(utterance_id, str) or not utterance_id:
            self._send_json(400, {"error": "missing_utterance_id"})
            return

        try:
            jobs = normalize_jobs(body.get("sentenceJobs"))
        except (ValueError, TypeError) as exc:
            self._send_json(400, {"error": "invalid_sentence_jobs", "details": str(exc)})
            return
        if not jobs:
            self._send_json(400, {"error": "empty_sentence_jobs"})
            return

        voice = body.get("voice") or self.server.default_voice
        lang_code = body.get("langCode") or self.server.default_lang_code
        speed = self.server.default_speed
        if "speed" in body:
            try:
                speed = float(body["speed"])
            except (TypeError, ValueError):
                self._send_json(400, {"error": "invalid_speed"})
                return
            if speed <= 0:
                self._send_json(400, {"error": "invalid_speed"})
                return

        if not self.server.generation_lock.acquire(blocking=False):
            self._send_json(503, {"error": "busy", "details": "Another request is in progress."})
            return

        try:
            self._stream_tts(utterance_id, jobs, voice, speed, lang_code)
        finally:
            self.server.generation_lock.release()

    def _stream_tts(
        self,
        utterance_id: str,
        jobs: list[dict[str, Any]],
        voice: str,
        speed: float,
        lang_code: str,
    ) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        try:
            self._write_ndjson_line({
                "event": "started",
                "utteranceId": utterance_id,
                "voiceName": voice,
                "voiceIdentifier": f"kokoro:{voice}",
            })
        except (BrokenPipeError, ConnectionResetError):
            log(f"Client disconnected before start: {utterance_id}")
            return

        with tempfile.TemporaryDirectory(prefix="reedah-tts-") as tmp_dir:
            output_dir = Path(tmp_dir)
            for job in jobs:
                try:
                    event = generate_sentence_audio(
                        job=job,
                        output_dir=output_dir,
                        model=self.server.model,
                        voice=voice,
                        speed=speed,
                        lang_code=lang_code,
                    )
                    event["utteranceId"] = utterance_id
                    self._write_ndjson_line(event)
                except (BrokenPipeError, ConnectionResetError):
                    log(f"Client disconnected during generation: {utterance_id}")
                    return
                except Exception as exc:
                    log(f"Generation error for job {job['index']}: {exc}")
                    try:
                        self._write_ndjson_line({
                            "event": "error",
                            "utteranceId": utterance_id,
                            "message": "generation_failed",
                            "details": str(exc),
                        })
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return

        try:
            self._write_ndjson_line({
                "event": "finished",
                "utteranceId": utterance_id,
            })
        except (BrokenPipeError, ConnectionResetError):
            log(f"Client disconnected before finish: {utterance_id}")


class TTSServer(ThreadingHTTPServer):
    def __init__(
        self,
        port: int,
        model: Any,
        model_id: str,
        default_voice: str,
        default_speed: float,
        default_lang_code: str,
    ) -> None:
        super().__init__(("127.0.0.1", port), TTSHandler)
        self.model = model
        self.model_id = model_id
        self.default_voice = default_voice
        self.default_speed = default_speed
        self.default_lang_code = default_lang_code
        self.generation_lock = threading.Lock()


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    try:
        model = load_model(args.model)
    except Exception as exc:
        log(f"Failed to load model: {exc}")
        return 1

    server = TTSServer(
        port=args.port,
        model=model,
        model_id=args.model,
        default_voice=args.voice,
        default_speed=args.speed,
        default_lang_code=args.lang_code,
    )

    log(f"Listening on http://127.0.0.1:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Shutting down.")
        server.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
