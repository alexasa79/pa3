#!/usr/bin/env python3
"""Chrome native host for Reedah using Kokoro via mlx-audio."""

from __future__ import annotations

import base64
import json
import os
import queue
import struct
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any

NATIVE_DIR = Path(__file__).resolve().parent
DEFAULT_KOKORO_PYTHON = str(NATIVE_DIR / ".venv" / "bin" / "python")
DEFAULT_KOKORO_MODEL = "mlx-community/Kokoro-82M-bf16"
DEFAULT_KOKORO_VOICE = "am_adam"
DEFAULT_KOKORO_LANG_CODE = "a"


@dataclass(frozen=True)
class SentenceJob:
    index: int
    location: int
    length: int
    text: str


class NativeMessenger:
    def __init__(self) -> None:
        self._stdin = sys.stdin.buffer
        self._stdout = sys.stdout.buffer
        self._write_lock = threading.Lock()

    def log(self, message: str) -> None:
        print(message, file=sys.stderr, flush=True)

    def send(self, payload: dict[str, Any]) -> None:
        try:
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        except Exception as exc:
            self.log(f"ReedahNative: Failed to encode payload: {exc}")
            return

        header = struct.pack("<I", len(data))
        with self._write_lock:
            self._stdout.write(header)
            self._stdout.write(data)
            self._stdout.flush()

    def read_message(self) -> dict[str, Any] | None:
        header = self._read_exact(4)
        if header is None:
            return None
        message_length = struct.unpack("<I", header)[0]
        if message_length <= 0:
            self.log("ReedahNative: Invalid message length from native messaging stdin.")
            return None

        body = self._read_exact(message_length)
        if body is None:
            return None

        try:
            payload = json.loads(body.decode("utf-8"))
        except Exception as exc:
            self.log(f"ReedahNative: Failed to decode message JSON: {exc}")
            return None

        if not isinstance(payload, dict):
            self.log("ReedahNative: Invalid message payload. Expected object.")
            return None
        return payload

    def _read_exact(self, count: int) -> bytes | None:
        remaining = count
        chunks: list[bytes] = []
        while remaining > 0:
            chunk = self._stdin.read(remaining)
            if not chunk:
                return None
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)


def parse_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        trimmed = value.strip()
        if not trimmed:
            return None
        try:
            return int(trimmed)
        except ValueError:
            return None
    return None


def parse_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        trimmed = value.strip()
        if not trimmed:
            return None
        try:
            return float(trimmed)
        except ValueError:
            return None
    return None


def normalize_config_value(value: str | None, default: str) -> str:
    if value is None:
        return default
    trimmed = value.strip()
    if not trimmed:
        return default
    return trimmed


class ReedahSayer:
    def __init__(self, messenger: NativeMessenger) -> None:
        self.messenger = messenger
        self._speech_queue: queue.Queue[dict[str, Any] | None] = queue.Queue()
        self._state_lock = threading.Lock()
        self._cancel_requested = False
        self._current_process: subprocess.Popen[str] | None = None
        self._speech_thread = threading.Thread(target=self._speech_loop, daemon=True)
        self._speech_thread.start()

    def speak(
        self,
        *,
        utterance_id: str,
        voice_hint: str | None,
        speed: float | None,
        sentence_jobs: list[SentenceJob],
        python_path: str | None,
        model: str | None,
        lang_code: str | None,
    ) -> None:
        self._speech_queue.put(
            {
                "utterance_id": utterance_id,
                "voice_hint": voice_hint,
                "speed": speed,
                "sentence_jobs": sentence_jobs,
                "python_path": python_path,
                "model": model,
                "lang_code": lang_code,
            }
        )

    def stop(self) -> None:
        with self._state_lock:
            self._cancel_requested = True
            process = self._current_process
        if process is not None and process.poll() is None:
            try:
                process.terminate()
            except Exception as exc:
                self.messenger.log(f"ReedahNative: Failed to terminate Kokoro worker: {exc}")

    def shutdown(self) -> None:
        self._speech_queue.put(None)
        self._speech_thread.join(timeout=2)

    def _speech_loop(self) -> None:
        while True:
            payload = self._speech_queue.get()
            if payload is None:
                return
            self._run_speech(**payload)

    def _run_speech(
        self,
        *,
        utterance_id: str,
        voice_hint: str | None,
        speed: float | None,
        sentence_jobs: list[SentenceJob],
        python_path: str | None,
        model: str | None,
        lang_code: str | None,
    ) -> None:
        with self._state_lock:
            self._cancel_requested = False

        if not sentence_jobs:
            self._send_error("missing_sentence_jobs", utterance_id)
            return
        if speed is not None and speed <= 0:
            self._send_error("invalid_speed", utterance_id, f"speed={speed}")
            return

        jobs = sentence_jobs

        resolved_voice = normalize_config_value(voice_hint, DEFAULT_KOKORO_VOICE)
        resolved_python_path = normalize_config_value(python_path, DEFAULT_KOKORO_PYTHON)
        resolved_model = normalize_config_value(model, DEFAULT_KOKORO_MODEL)
        resolved_lang_code = normalize_config_value(lang_code, DEFAULT_KOKORO_LANG_CODE)
        resolved_speed = speed if speed is not None else 1.0

        for job in jobs:
            self.messenger.log(
                "ReedahNative: Narration sentence "
                f"utterance={utterance_id} index={job.index} "
                f"location={job.location} length={job.length} "
                f"text={json.dumps(job.text, ensure_ascii=False)}"
            )

        self.messenger.send(
            {
                "event": "started",
                "utteranceId": utterance_id,
                "voiceName": resolved_voice,
                "voiceIdentifier": resolved_voice,
            }
        )

        with tempfile.TemporaryDirectory(prefix=f"reedah-{utterance_id}-") as temp_dir_raw:
            temp_dir = Path(temp_dir_raw)
            jobs_file = temp_dir / "jobs.json"
            jobs_payload = [
                {
                    "index": job.index,
                    "location": job.location,
                    "length": job.length,
                    "text": job.text,
                }
                for job in jobs
            ]
            try:
                jobs_file.write_text(json.dumps(jobs_payload), encoding="utf-8")
            except Exception as exc:
                self._send_error("jobs_write_failed", utterance_id, str(exc))
                return

            status = self._run_kokoro_worker(
                utterance_id=utterance_id,
                jobs_file=jobs_file,
                output_dir=temp_dir,
                python_path=resolved_python_path,
                model=resolved_model,
                voice=resolved_voice,
                speed=resolved_speed,
                lang_code=resolved_lang_code,
            )

        if status == "cancelled":
            self._send_cancelled(utterance_id)
            return
        if status == "failed":
            return
        if self._is_cancelled():
            self._send_cancelled(utterance_id)
            return

        self.messenger.send({"event": "finished", "utteranceId": utterance_id})

    def _run_kokoro_worker(
        self,
        *,
        utterance_id: str,
        jobs_file: Path,
        output_dir: Path,
        python_path: str,
        model: str,
        voice: str,
        speed: float,
        lang_code: str,
    ) -> str:
        worker_path = Path(__file__).with_name("kokoro_worker.py")
        if not worker_path.exists():
            self._send_error("kokoro_worker_missing", utterance_id, str(worker_path))
            return "failed"
        if not worker_path.is_file():
            self._send_error("kokoro_worker_missing", utterance_id, str(worker_path))
            return "failed"

        python_executable = Path(python_path)
        if not python_executable.exists() or not python_executable.is_file():
            self._send_error("kokoro_python_not_found", utterance_id, python_path)
            return "failed"
        if not python_executable.stat().st_mode & 0o111:
            self._send_error("kokoro_python_not_executable", utterance_id, python_path)
            return "failed"

        command = [
            python_path,
            str(worker_path),
            "--jobs-file",
            str(jobs_file),
            "--output-dir",
            str(output_dir),
            "--model",
            model,
            "--voice",
            voice,
            "--speed",
            str(speed),
            "--lang-code",
            lang_code,
        ]
        self.messenger.log(
            "ReedahNative: Launching Kokoro worker "
            f"python={python_path} worker={worker_path} "
            f"model={model} voice={voice} lang={lang_code} speed={speed} espeak=enabled"
        )

        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=sys.stderr,
                text=True,
                bufsize=1,
            )
        except Exception as exc:
            self._send_error("kokoro_launch_failed", utterance_id, str(exc))
            return "failed"

        with self._state_lock:
            self._current_process = process

        worker_error_details: str | None = None
        try:
            assert process.stdout is not None
            for raw_line in process.stdout:
                if self._is_cancelled():
                    self._terminate_process(process)
                    return "cancelled"

                line = raw_line.strip()
                if not line:
                    continue

                try:
                    event_payload = json.loads(line)
                except Exception:
                    self._send_error("kokoro_protocol_error", utterance_id, line)
                    self._terminate_process(process)
                    return "failed"

                if not isinstance(event_payload, dict):
                    self._send_error("kokoro_protocol_error", utterance_id, line)
                    self._terminate_process(process)
                    return "failed"

                event = event_payload.get("event")
                if event == "audio_ready":
                    ok = self._handle_audio_ready(utterance_id=utterance_id, event_payload=event_payload)
                    if not ok:
                        self._terminate_process(process)
                        return "failed"
                    continue

                if event == "error":
                    details = event_payload.get("details") or event_payload.get("message")
                    worker_error_details = str(details) if details else "kokoro_worker_error"
                    self.messenger.log(f"ReedahNative: Kokoro worker error: {worker_error_details}")
                    continue

                self._send_error("kokoro_protocol_error", utterance_id, line)
                self._terminate_process(process)
                return "failed"
        finally:
            with self._state_lock:
                self._current_process = None

        process.wait()

        if self._is_cancelled():
            return "cancelled"
        if process.returncode != 0:
            details = worker_error_details or f"worker_exit_{process.returncode}"
            self._send_error("kokoro_failed", utterance_id, details)
            return "failed"
        if worker_error_details:
            self._send_error("kokoro_failed", utterance_id, worker_error_details)
            return "failed"

        return "ok"

    def _handle_audio_ready(self, *, utterance_id: str, event_payload: dict[str, Any]) -> bool:
        index = parse_int(event_payload.get("index"))
        location = parse_int(event_payload.get("location"))
        length = parse_int(event_payload.get("length"))
        path = event_payload.get("path")

        if index is None:
            self._send_error("kokoro_protocol_error", utterance_id, "missing_index")
            return False
        if location is None:
            self._send_error("kokoro_protocol_error", utterance_id, "missing_location")
            return False
        if length is None:
            self._send_error("kokoro_protocol_error", utterance_id, "missing_length")
            return False
        if not isinstance(path, str) or not path:
            self._send_error("kokoro_protocol_error", utterance_id, "missing_path")
            return False

        output_path = Path(path)
        return self._send_audio_from_file(
            utterance_id=utterance_id,
            index=index,
            location=location,
            length=length,
            output_path=output_path,
        )

    def _send_audio_from_file(
        self,
        *,
        utterance_id: str,
        index: int,
        location: int,
        length: int,
        output_path: Path,
    ) -> bool:
        try:
            data = output_path.read_bytes()
        except Exception as exc:
            self._send_error("audio_read_failed", utterance_id, str(exc))
            return False
        if not data:
            self._send_error("audio_empty", utterance_id, str(output_path))
            return False

        base64_audio = base64.b64encode(data).decode("ascii")
        self.messenger.send(
            {
                "event": "audio",
                "utteranceId": utterance_id,
                "index": index,
                "location": location,
                "length": length,
                "mimeType": "audio/wav",
                "audioBase64": base64_audio,
            }
        )

        try:
            output_path.unlink()
        except Exception:
            pass
        return True

    def _is_cancelled(self) -> bool:
        with self._state_lock:
            return self._cancel_requested

    def _terminate_process(self, process: subprocess.Popen[str]) -> None:
        try:
            if process.poll() is None:
                process.terminate()
        except Exception as exc:
            self.messenger.log(f"ReedahNative: Failed to terminate process: {exc}")
        try:
            process.wait(timeout=2)
        except Exception:
            pass

    def _send_cancelled(self, utterance_id: str) -> None:
        self.messenger.send({"event": "cancelled", "utteranceId": utterance_id})

    def _send_error(self, code: str, utterance_id: str, details: str | None = None) -> None:
        if details:
            self.messenger.log(
                f"ReedahNative: ERROR [{code}] utteranceId={utterance_id} details={details}"
            )
        else:
            self.messenger.log(f"ReedahNative: ERROR [{code}] utteranceId={utterance_id}")

        payload: dict[str, Any] = {"event": "error", "message": code, "utteranceId": utterance_id}
        if details:
            payload["details"] = details
        self.messenger.send(payload)


def _read_sentence_jobs(raw_value: Any) -> list[SentenceJob]:
    if not isinstance(raw_value, list):
        raise ValueError("sentenceJobs must be an array.")

    jobs: list[SentenceJob] = []
    for entry_index, entry in enumerate(raw_value):
        if not isinstance(entry, dict):
            raise ValueError(f"sentenceJobs[{entry_index}] must be an object.")

        index = parse_int(entry.get("index"))
        if index is None:
            raise ValueError(f"sentenceJobs[{entry_index}].index must be an integer.")

        location = parse_int(entry.get("location"))
        if location is None:
            raise ValueError(f"sentenceJobs[{entry_index}].location must be an integer.")

        length = parse_int(entry.get("length"))
        if length is None or length <= 0:
            raise ValueError(f"sentenceJobs[{entry_index}].length must be a positive integer.")

        text = entry.get("text")
        if not isinstance(text, str):
            raise ValueError(f"sentenceJobs[{entry_index}].text must be a string.")
        if not text.strip():
            raise ValueError(f"sentenceJobs[{entry_index}].text must be non-empty.")

        jobs.append(
            SentenceJob(
                index=index,
                location=location,
                length=length,
                text=text,
            )
        )

    return jobs


def run() -> int:
    messenger = NativeMessenger()
    messenger.log(f"ReedahNative: Host started pid={os.getpid()} path={Path(__file__).resolve()}")
    sayer = ReedahSayer(messenger)

    while True:
        message = messenger.read_message()
        if message is None:
            break

        action = message.get("action")
        if not isinstance(action, str):
            messenger.send({"event": "error", "message": "missing_action", "utteranceId": ""})
            continue

        if action == "speak":
            utterance_id = message.get("utteranceId")
            if not isinstance(utterance_id, str) or not utterance_id:
                utterance_id = ""
            voice = message.get("voice")
            if voice is not None and not isinstance(voice, str):
                voice = ""
            speed = parse_float(message.get("rate"))
            python_path = message.get("pythonPath")
            if python_path is not None and not isinstance(python_path, str):
                python_path = ""
            model = message.get("model")
            if model is not None and not isinstance(model, str):
                model = ""
            lang_code = message.get("langCode")
            if lang_code is not None and not isinstance(lang_code, str):
                lang_code = ""

            try:
                sentence_jobs = _read_sentence_jobs(message.get("sentenceJobs"))
            except Exception as exc:
                messenger.log(
                    f"ReedahNative: ERROR [invalid_sentence_jobs] utteranceId={utterance_id} details={exc}"
                )
                messenger.send(
                    {
                        "event": "error",
                        "message": "invalid_sentence_jobs",
                        "utteranceId": utterance_id,
                        "details": str(exc),
                    }
                )
                continue

            sayer.speak(
                utterance_id=utterance_id,
                voice_hint=voice,
                speed=speed,
                sentence_jobs=sentence_jobs,
                python_path=python_path,
                model=model,
                lang_code=lang_code,
            )
            continue

        if action == "stop":
            sayer.stop()
            continue

        messenger.send({"event": "error", "message": "unknown_action", "utteranceId": ""})

    sayer.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
