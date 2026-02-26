#!/usr/bin/env python3
"""Generate sentence audio with Kokoro via mlx-audio and stream JSON events."""

from __future__ import annotations

import argparse
import contextlib
import json
import sys
from pathlib import Path
from typing import Any, Callable

DEFAULT_MODEL = "mlx-community/Kokoro-82M-bf16"
DEFAULT_VOICE = "am_adam"
DEFAULT_LANG_CODE = "a"
DEFAULT_SPEED = 1.0


def log_error(message: str) -> None:
    print(f"ReedahKokoro: {message}", file=sys.stderr, flush=True)


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def emit_error(message: str, details: str) -> None:
    emit({"event": "error", "message": message, "details": details})


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Kokoro worker for Reedah native host.")
    parser.add_argument("--jobs-file", required=True, help="JSON file with sentence jobs.")
    parser.add_argument("--output-dir", required=True, help="Directory for generated wav files.")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="mlx-audio model repo/path.")
    parser.add_argument("--voice", default=DEFAULT_VOICE, help="Kokoro voice preset.")
    parser.add_argument("--speed", type=float, default=DEFAULT_SPEED, help="Speech speed multiplier.")
    parser.add_argument("--lang-code", default=DEFAULT_LANG_CODE, help="Kokoro language code.")
    return parser.parse_args(argv)


def _parse_int(value: Any, field_name: str, entry_index: int) -> int:
    if isinstance(value, bool):
        raise ValueError(f"job[{entry_index}].{field_name} must be an integer.")
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        trimmed = value.strip()
        if not trimmed:
            raise ValueError(f"job[{entry_index}].{field_name} must be an integer.")
        try:
            return int(trimmed)
        except ValueError as exc:
            raise ValueError(
                f"job[{entry_index}].{field_name} must be an integer."
            ) from exc
    raise ValueError(f"job[{entry_index}].{field_name} must be an integer.")


def normalize_jobs(raw_jobs: Any) -> list[dict[str, Any]]:
    if not isinstance(raw_jobs, list):
        raise ValueError("jobs payload must be an array.")

    jobs: list[dict[str, Any]] = []
    for entry_index, raw_entry in enumerate(raw_jobs):
        if not isinstance(raw_entry, dict):
            raise ValueError(f"job[{entry_index}] must be an object.")

        index = _parse_int(raw_entry.get("index"), "index", entry_index)
        location = _parse_int(raw_entry.get("location"), "location", entry_index)
        length = _parse_int(raw_entry.get("length"), "length", entry_index)

        text = raw_entry.get("text")
        if not isinstance(text, str):
            raise ValueError(f"job[{entry_index}].text must be a string.")
        if not text.strip():
            raise ValueError(f"job[{entry_index}].text must be non-empty.")

        jobs.append(
            {
                "index": index,
                "location": location,
                "length": length,
                "text": text,
            }
        )
    return jobs


def process_jobs(
    jobs: list[dict[str, Any]],
    output_dir: Path,
    model: Any,
    voice: str,
    speed: float,
    lang_code: str,
    generate_audio: Callable[..., None],
    emit_event: Callable[[dict[str, Any]], None],
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    for job in jobs:
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

        emit_event(
            {
                "event": "audio_ready",
                "index": job["index"],
                "location": job["location"],
                "length": job["length"],
                "path": str(output_file),
            }
        )


def _load_jobs(jobs_file: Path) -> list[dict[str, Any]]:
    raw = json.loads(jobs_file.read_text(encoding="utf-8"))
    return normalize_jobs(raw)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    jobs_file = Path(args.jobs_file)
    output_dir = Path(args.output_dir)

    try:
        jobs = _load_jobs(jobs_file)
    except Exception as exc:
        message = f"Failed to read jobs file '{jobs_file}': {exc}"
        log_error(message)
        emit_error("jobs_read_failed", str(exc))
        return 1

    if not jobs:
        message = "Jobs file did not contain any sentence jobs."
        log_error(message)
        emit_error("jobs_empty", message)
        return 1

    if args.speed <= 0:
        message = f"Invalid speed value '{args.speed}'. Speed must be > 0."
        log_error(message)
        emit_error("invalid_speed", message)
        return 1

    log_error("espeak backend enabled for this run.")

    try:
        from mlx_audio.tts import load as load_tts_model
        from mlx_audio.tts.generate import generate_audio
    except Exception as exc:
        message = f"Failed to import mlx_audio: {exc}"
        log_error(message)
        emit_error("mlx_import_failed", str(exc))
        return 1

    try:
        with contextlib.redirect_stdout(sys.stderr):
            model = load_tts_model(args.model)
    except Exception as exc:
        message = f"Failed to load model '{args.model}': {exc}"
        log_error(message)
        emit_error("model_load_failed", str(exc))
        return 1

    try:
        process_jobs(
            jobs=jobs,
            output_dir=output_dir,
            model=model,
            voice=args.voice,
            speed=args.speed,
            lang_code=args.lang_code,
            generate_audio=generate_audio,
            emit_event=emit,
        )
    except Exception as exc:
        message = f"Failed to generate audio: {exc}"
        log_error(message)
        emit_error("generation_failed", str(exc))
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
