import contextlib
import io
import importlib.util
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("kokoro_worker.py")
SPEC = importlib.util.spec_from_file_location("kokoro_worker", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
KOKORO_WORKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = KOKORO_WORKER
SPEC.loader.exec_module(KOKORO_WORKER)


class NormalizeJobsTests(unittest.TestCase):
    def test_normalize_jobs_returns_valid_entries(self):
        jobs = KOKORO_WORKER.normalize_jobs(
            [
                {"index": 0, "location": 5, "length": 10, "text": "Hello world."},
                {"index": "1", "location": "20", "length": "9", "text": "Another line."},
            ]
        )

        self.assertEqual(2, len(jobs))
        self.assertEqual(1, jobs[1]["index"])
        self.assertEqual(20, jobs[1]["location"])
        self.assertEqual(9, jobs[1]["length"])

    def test_normalize_jobs_rejects_empty_text(self):
        with self.assertRaisesRegex(ValueError, "non-empty"):
            KOKORO_WORKER.normalize_jobs(
                [{"index": 0, "location": 0, "length": 1, "text": "   "}]
            )

    def test_normalize_jobs_rejects_non_array_payload(self):
        with self.assertRaisesRegex(ValueError, "array"):
            KOKORO_WORKER.normalize_jobs({"index": 0})


class EspeakStubTests(unittest.TestCase):
    def test_install_espeak_stub_injects_blocking_modules(self):
        original_misaki_espeak = sys.modules.get("misaki.espeak")
        original_espeak_loader = sys.modules.get("espeakng_loader")
        try:
            sys.modules.pop("misaki.espeak", None)
            sys.modules.pop("espeakng_loader", None)

            KOKORO_WORKER.install_espeak_stub()

            misaki_espeak = sys.modules.get("misaki.espeak")
            espeak_loader = sys.modules.get("espeakng_loader")

            self.assertIsNotNone(misaki_espeak)
            self.assertIsNotNone(espeak_loader)
            with self.assertRaisesRegex(RuntimeError, "disables misaki espeak backend"):
                misaki_espeak.EspeakFallback()
            with self.assertRaisesRegex(RuntimeError, "disables espeakng_loader"):
                espeak_loader.get_library_path()
        finally:
            if original_misaki_espeak is None:
                sys.modules.pop("misaki.espeak", None)
            else:
                sys.modules["misaki.espeak"] = original_misaki_espeak

            if original_espeak_loader is None:
                sys.modules.pop("espeakng_loader", None)
            else:
                sys.modules["espeakng_loader"] = original_espeak_loader


class ProcessJobsTests(unittest.TestCase):
    def test_process_jobs_emits_audio_ready_event(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir) / "out"
            emitted = []
            jobs = [{"index": 2, "location": 11, "length": 7, "text": "testing"}]

            def fake_generate_audio(**kwargs):
                out_file = Path(kwargs["output_path"]) / f"{kwargs['file_prefix']}.wav"
                out_file.parent.mkdir(parents=True, exist_ok=True)
                out_file.write_bytes(b"wav")

            KOKORO_WORKER.process_jobs(
                jobs=jobs,
                output_dir=output_dir,
                model=object(),
                voice="am_adam",
                speed=1.0,
                lang_code="a",
                generate_audio=fake_generate_audio,
                emit_event=emitted.append,
            )

            self.assertEqual(1, len(emitted))
            self.assertEqual("audio_ready", emitted[0]["event"])
            self.assertEqual(2, emitted[0]["index"])
            self.assertTrue(Path(emitted[0]["path"]).exists())

    def test_process_jobs_fails_when_generator_does_not_write_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir) / "out"
            jobs = [{"index": 0, "location": 0, "length": 4, "text": "test"}]

            def fake_generate_audio(**kwargs):
                del kwargs

            with self.assertRaisesRegex(RuntimeError, "not generated"):
                KOKORO_WORKER.process_jobs(
                    jobs=jobs,
                    output_dir=output_dir,
                    model=object(),
                    voice="am_adam",
                    speed=1.0,
                    lang_code="a",
                    generate_audio=fake_generate_audio,
                    emit_event=lambda event: event,
                )


class MainEspeakBehaviorTests(unittest.TestCase):
    def test_main_disables_espeak_modules_by_default(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            jobs_file = Path(temp_dir) / "jobs.json"
            output_dir = Path(temp_dir) / "audio"
            jobs_file.write_text(
                json.dumps([{"index": 0, "location": 0, "length": 5, "text": "hello"}]),
                encoding="utf-8",
            )

            original_modules = {name: sys.modules.get(name) for name in (
                "mlx_audio",
                "mlx_audio.tts",
                "mlx_audio.tts.generate",
                "misaki.espeak",
                "espeakng_loader",
            )}
            try:
                sys.modules.pop("misaki.espeak", None)
                sys.modules.pop("espeakng_loader", None)

                fake_mlx_audio = types.ModuleType("mlx_audio")
                fake_tts = types.ModuleType("mlx_audio.tts")
                fake_generate_module = types.ModuleType("mlx_audio.tts.generate")

                def fake_load(model_id):
                    del model_id
                    return object()

                def fake_generate_audio(**kwargs):
                    output_path = Path(kwargs["output_path"])
                    output_path.mkdir(parents=True, exist_ok=True)
                    output_file = output_path / f"{kwargs['file_prefix']}.wav"
                    output_file.write_bytes(b"wav")

                fake_tts.load = fake_load
                fake_generate_module.generate_audio = fake_generate_audio
                fake_mlx_audio.tts = fake_tts

                sys.modules["mlx_audio"] = fake_mlx_audio
                sys.modules["mlx_audio.tts"] = fake_tts
                sys.modules["mlx_audio.tts.generate"] = fake_generate_module

                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    exit_code = KOKORO_WORKER.main(
                        [
                            "--jobs-file",
                            str(jobs_file),
                            "--output-dir",
                            str(output_dir),
                        ]
                    )

                self.assertEqual(0, exit_code)
                self.assertIn("misaki.espeak", sys.modules)
                self.assertIn("espeakng_loader", sys.modules)
            finally:
                for name, module in original_modules.items():
                    if module is None:
                        sys.modules.pop(name, None)
                    else:
                        sys.modules[name] = module

    def test_main_does_not_install_espeak_stubs_when_enabled(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            jobs_file = Path(temp_dir) / "jobs.json"
            output_dir = Path(temp_dir) / "audio"
            jobs_file.write_text(
                json.dumps([{"index": 0, "location": 0, "length": 5, "text": "hello"}]),
                encoding="utf-8",
            )

            original_modules = {name: sys.modules.get(name) for name in (
                "mlx_audio",
                "mlx_audio.tts",
                "mlx_audio.tts.generate",
                "misaki.espeak",
                "espeakng_loader",
            )}
            try:
                sys.modules.pop("misaki.espeak", None)
                sys.modules.pop("espeakng_loader", None)

                fake_mlx_audio = types.ModuleType("mlx_audio")
                fake_tts = types.ModuleType("mlx_audio.tts")
                fake_generate_module = types.ModuleType("mlx_audio.tts.generate")

                def fake_load(model_id):
                    del model_id
                    return object()

                def fake_generate_audio(**kwargs):
                    output_path = Path(kwargs["output_path"])
                    output_path.mkdir(parents=True, exist_ok=True)
                    output_file = output_path / f"{kwargs['file_prefix']}.wav"
                    output_file.write_bytes(b"wav")

                fake_tts.load = fake_load
                fake_generate_module.generate_audio = fake_generate_audio
                fake_mlx_audio.tts = fake_tts

                sys.modules["mlx_audio"] = fake_mlx_audio
                sys.modules["mlx_audio.tts"] = fake_tts
                sys.modules["mlx_audio.tts.generate"] = fake_generate_module

                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    exit_code = KOKORO_WORKER.main(
                        [
                            "--jobs-file",
                            str(jobs_file),
                            "--output-dir",
                            str(output_dir),
                            "--enable-espeak",
                        ]
                    )

                self.assertEqual(0, exit_code)
                self.assertNotIn("misaki.espeak", sys.modules)
                self.assertNotIn("espeakng_loader", sys.modules)
            finally:
                for name, module in original_modules.items():
                    if module is None:
                        sys.modules.pop(name, None)
                    else:
                        sys.modules[name] = module


if __name__ == "__main__":
    unittest.main()
