import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("reedah_native_host.py")
SPEC = importlib.util.spec_from_file_location("reedah_native_host", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
HOST = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HOST
SPEC.loader.exec_module(HOST)


class Utf16HelpersTests(unittest.TestCase):
    def test_utf16_slice_handles_surrogate_pairs(self):
        text = "A😀B"
        # UTF-16 code units: A(1), 😀(2), B(1)
        sliced = HOST.utf16_slice(text, 1, 3)
        self.assertEqual("😀", sliced)

    def test_build_sentence_jobs_uses_utf16_offsets(self):
        text = "A😀B. C"
        ranges = [HOST.SentenceRange(start=0, end=5), HOST.SentenceRange(start=5, end=7)]
        jobs = HOST.build_sentence_jobs(text, ranges)

        self.assertEqual(2, len(jobs))
        self.assertEqual("A😀B.", jobs[0].text)
        self.assertEqual(" C", jobs[1].text)
        self.assertEqual(5, jobs[0].length)


class ParseHelpersTests(unittest.TestCase):
    def test_parse_int(self):
        self.assertEqual(4, HOST.parse_int("4"))
        self.assertEqual(4, HOST.parse_int(4.0))
        self.assertIsNone(HOST.parse_int("x"))

    def test_parse_float(self):
        self.assertEqual(1.5, HOST.parse_float("1.5"))
        self.assertEqual(2.0, HOST.parse_float(2))
        self.assertIsNone(HOST.parse_float("abc"))

    def test_normalize_config_value(self):
        self.assertEqual("default", HOST.normalize_config_value("", "default"))
        self.assertEqual("value", HOST.normalize_config_value(" value ", "default"))

    def test_default_kokoro_python_path_points_to_native_venv(self):
        expected_suffix = "/native/.venv/bin/python"
        self.assertTrue(HOST.DEFAULT_KOKORO_PYTHON.endswith(expected_suffix))


class AudioSendTests(unittest.TestCase):
    class StubMessenger:
        def __init__(self):
            self.sent = []
            self.logs = []

        def send(self, payload):
            self.sent.append(payload)

        def log(self, message):
            self.logs.append(message)

    def test_send_audio_from_file_emits_audio_event(self):
        messenger = self.StubMessenger()
        sayer = HOST.ReedahSayer(messenger)
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                audio_path = Path(temp_dir) / "audio.wav"
                audio_path.write_bytes(b"wav")

                ok = sayer._send_audio_from_file(
                    utterance_id="u1",
                    index=0,
                    location=0,
                    length=3,
                    output_path=audio_path,
                )

                self.assertTrue(ok)
                self.assertEqual("audio", messenger.sent[0]["event"])
                self.assertEqual("audio/wav", messenger.sent[0]["mimeType"])
                self.assertFalse(audio_path.exists())
        finally:
            sayer.shutdown()


if __name__ == "__main__":
    unittest.main()
