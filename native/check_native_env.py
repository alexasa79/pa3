#!/usr/bin/env python3
"""Preflight checks for Reedah's local Kokoro runtime environment."""

from __future__ import annotations

import importlib
import subprocess
import sys
from typing import Callable

REQUIRED_MODULES = (
    "mlx",
    "mlx_audio",
    "mlx_audio.tts",
    "mlx_audio.tts.generate",
    "misaki",
    "misaki.en",
    "misaki.espeak",
    "num2words",
    "spacy",
    "phonemizer",
    "espeakng_loader",
)
REQUIRED_SPACY_MODELS = ("en_core_web_sm",)


def find_missing_modules(
    modules: tuple[str, ...] = REQUIRED_MODULES,
    import_module: Callable[[str], object] = importlib.import_module,
) -> list[tuple[str, str]]:
    missing: list[tuple[str, str]] = []
    for module_name in modules:
        try:
            import_module(module_name)
        except Exception as exc:
            missing.append((module_name, str(exc)))
    return missing


def find_missing_spacy_models(
    models: tuple[str, ...] = REQUIRED_SPACY_MODELS,
    is_package: Callable[[str], bool] | None = None,
    spacy_module: object | None = None,
) -> list[str]:
    if spacy_module is None:
        try:
            import spacy
        except Exception:
            return list(models)
        spacy_module = spacy

    checker = is_package or spacy_module.util.is_package
    missing: list[str] = []
    for model_name in models:
        if not checker(model_name):
            missing.append(model_name)
    return missing


def run_pip_check(
    python_executable: str = sys.executable,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> tuple[bool, str]:
    result = run(
        [python_executable, "-m", "pip", "check"],
        capture_output=True,
        text=True,
    )
    output = (result.stdout or "") + (result.stderr or "")
    return result.returncode == 0, output.strip()


def main() -> int:
    pip_check_ok, pip_check_output = run_pip_check()
    missing = find_missing_modules()
    missing_models = find_missing_spacy_models()

    if pip_check_ok and not missing and not missing_models:
        print("Reedah native preflight OK.")
        return 0

    print("Reedah native preflight FAILED.")

    if not pip_check_ok:
        print("pip dependency integrity check failed (python -m pip check):")
        if pip_check_output:
            print(pip_check_output)

    print("Missing or broken Python modules:")
    if missing:
        for module_name, error in missing:
            print(f"- {module_name}: {error}")
    else:
        print("- none")

    print("Missing spaCy model packages:")
    if missing_models:
        for model_name in missing_models:
            print(f"- {model_name}")
    else:
        print("- none")

    print("Run: ./scripts/setup_native_env.sh")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
