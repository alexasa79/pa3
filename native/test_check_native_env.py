import importlib.util
import sys
import types
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("check_native_env.py")
SPEC = importlib.util.spec_from_file_location("check_native_env", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
CHECK_NATIVE_ENV = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECK_NATIVE_ENV
SPEC.loader.exec_module(CHECK_NATIVE_ENV)


class CheckNativeEnvTests(unittest.TestCase):
    def test_find_missing_modules_returns_empty_when_all_import(self):
        def fake_import(name):
            return {"name": name}

        missing = CHECK_NATIVE_ENV.find_missing_modules(
            modules=("a", "b"),
            import_module=fake_import,
        )
        self.assertEqual([], missing)

    def test_find_missing_modules_collects_all_failures(self):
        def fake_import(name):
            if name == "ok":
                return object()
            raise ModuleNotFoundError(f"No module named '{name}'")

        missing = CHECK_NATIVE_ENV.find_missing_modules(
            modules=("ok", "missing_one", "missing_two"),
            import_module=fake_import,
        )
        self.assertEqual(
            [
                ("missing_one", "No module named 'missing_one'"),
                ("missing_two", "No module named 'missing_two'"),
            ],
            missing,
        )

    def test_find_missing_spacy_models_reports_missing(self):
        fake_spacy = types.SimpleNamespace(
            util=types.SimpleNamespace(is_package=lambda name: False)
        )
        missing = CHECK_NATIVE_ENV.find_missing_spacy_models(
            models=("en_core_web_sm", "xx_model"),
            is_package=lambda name: name == "en_core_web_sm",
            spacy_module=fake_spacy,
        )
        self.assertEqual(["xx_model"], missing)

    def test_run_pip_check_returns_success_for_zero_exit(self):
        class Result:
            returncode = 0
            stdout = "ok\n"
            stderr = ""

        def fake_run(*args, **kwargs):
            del args, kwargs
            return Result()

        ok, output = CHECK_NATIVE_ENV.run_pip_check(
            python_executable="/tmp/fake-python",
            run=fake_run,
        )
        self.assertTrue(ok)
        self.assertEqual("ok", output)

    def test_run_pip_check_returns_failure_output(self):
        class Result:
            returncode = 1
            stdout = ""
            stderr = "broken-dep 1.0 requires x, which is not installed\n"

        def fake_run(*args, **kwargs):
            del args, kwargs
            return Result()

        ok, output = CHECK_NATIVE_ENV.run_pip_check(
            python_executable="/tmp/fake-python",
            run=fake_run,
        )
        self.assertFalse(ok)
        self.assertIn("requires x", output)


if __name__ == "__main__":
    unittest.main()
