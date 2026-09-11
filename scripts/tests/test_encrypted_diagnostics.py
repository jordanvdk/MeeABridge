import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("signing_diagnostics", Path(__file__).parents[1] / "sign_and_upload.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class EncryptedDiagnosticTests(unittest.TestCase):
    def test_failure_never_publishes_partial_or_plaintext_output(self):
        for mode in ("exit", "timeout", "malformed", "context"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                env = {"RUNNER_TEMP": directory, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
                       "GITHUB_OUTPUT": str(root / "outputs"), "DIAGNOSTIC_PUBLIC_KEY_BASE64": "YQ=="}
                with patch.dict(os.environ, env, clear=True):
                    state = signing.state_directory()
                    state.mkdir()
                    (state / "command.log").write_text("PRIVATE_CANARY")
                    def fake(args, **kwargs):
                        Path(args[-2]).write_text("PRIVATE_CANARY")
                        if mode == "timeout":
                            raise subprocess.TimeoutExpired("synthetic", 120)
                        if mode == "context":
                            Path(args[-2]).write_text(json.dumps(self.envelope("wrong-context")))
                        return subprocess.CompletedProcess(args, 1 if mode == "exit" else 0)
                    output = io.StringIO()
                    with patch.object(signing.subprocess, "run", side_effect=fake), contextlib.redirect_stdout(output):
                        signing.preserve_apple_diagnostic("Apple package validation", state, {})
                    self.assertFalse(signing.encrypted_diagnostic_path().exists())
                    self.assertFalse((root / "outputs").exists())
                    self.assertNotIn("PRIVATE_CANARY", output.getvalue())

    @staticmethod
    def envelope(context):
        def encoded(length): return base64.b64encode(bytes(length)).decode()
        return {"version": 1, "algorithm": "RSA-OAEP-256+A256GCM", "context": context,
                "wrappedKey": encoded(384), "nonce": encoded(12), "ciphertext": encoded(32), "tag": encoded(16)}

    def test_only_checked_envelope_is_published_and_original_failure_remains(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {"RUNNER_TEMP": directory, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
                   "GITHUB_OUTPUT": str(root / "outputs"), "DIAGNOSTIC_PUBLIC_KEY_BASE64": "YQ==",
                   "ASC_PRIVATE_KEY": "PRIVATE_KEY_CANARY"}
            with patch.dict(os.environ, env, clear=True):
                state = signing.state_directory()
                state.mkdir()
                def fake(args, **kwargs):
                    self.assertNotIn("ASC_PRIVATE_KEY", kwargs["env"])
                    if args[0] == "swift":
                        Path(args[-2]).write_text(json.dumps(self.envelope(args[-1])))
                        return subprocess.CompletedProcess(args, 0)
                    kwargs["stdout"].write(b"PRIVATE_LOG_CANARY")
                    return subprocess.CompletedProcess(args, 1)
                with patch.object(signing.subprocess, "run", side_effect=fake), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(signing.SigningError):
                        signing.command("Apple package validation", ["synthetic"], state)
                data = signing.encrypted_diagnostic_path().read_text()
                self.assertNotIn("PRIVATE", data)
                self.assertEqual(json.loads(data)["context"], "run=123;attempt=1;stage=validation")
                self.assertEqual((root / "outputs").read_text(), "encrypted_diagnostic=true\n")

    def test_disabled_and_other_stages_do_not_invoke_encryption(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(signing.subprocess, "run") as run:
            signing.preserve_apple_diagnostic("Apple upload", Path("unused"), {})
            run.assert_not_called()
        with patch.dict(os.environ, {"DIAGNOSTIC_PUBLIC_KEY_BASE64": "YQ=="}, clear=True), patch.object(signing.subprocess, "run") as run:
            signing.preserve_apple_diagnostic("Import distribution identity", Path("unused"), {})
            run.assert_not_called()

    def test_envelope_rejects_extra_fields_invalid_sizes_and_oversized_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sealed"
            for field, value in (("extra", "PRIVATE"), ("nonce", "YQ=="), ("tag", "!"), ("version", True)):
                envelope = self.envelope("context")
                envelope[field] = value
                path.write_text(json.dumps(envelope))
                with self.assertRaises((ValueError, TypeError)):
                    signing.checked_envelope(path, "context")
            path.write_bytes(b"x" * (3 * 1024 * 1024 + 1))
            with self.assertRaises(ValueError):
                signing.checked_envelope(path, "context")


if __name__ == "__main__":
    unittest.main()
