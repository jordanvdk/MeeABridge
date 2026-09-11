import base64
import copy
import datetime as dt
import hashlib
import importlib.util
from pathlib import Path
import unittest
import sys
import tempfile

spec = importlib.util.spec_from_file_location("sign_and_upload", Path(__file__).parents[1] / "sign_and_upload.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningContractTests(unittest.TestCase):
    def setUp(self):
        self.team = "EXAMPLE123"
        self.bundle = "org.example.Companion"
        self.now = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        self.profile = {
            "UUID": "00000000-0000-4000-8000-000000000001",
            "TeamIdentifier": [self.team],
            "ExpirationDate": dt.datetime(2027, 1, 1),
            "DeveloperCertificates": [b"synthetic public certificate"],
            "Entitlements": {
                "application-identifier": self.team + "." + self.bundle,
                "com.apple.developer.team-identifier": self.team,
                "com.apple.developer.healthkit": True,
                "get-task-allow": False,
                "beta-reports-active": True,
            },
        }

    def test_exact_app_store_profile_and_certificate_binding(self):
        identifier, certificates = signing.checked_profile(self.profile, self.team, self.bundle, self.now)
        self.assertEqual(identifier, self.profile["UUID"])
        self.assertEqual(certificates, {hashlib.sha1(b"synthetic public certificate").hexdigest().upper()})

    def test_wrong_team_and_wildcard_or_other_app_are_rejected(self):
        for key, value in [("application-identifier", self.team + ".*"), ("application-identifier", self.team + ".org.example.Other"), ("com.apple.developer.team-identifier", "OTHER12345")]:
            with self.subTest(key=key, value=value):
                profile = copy.deepcopy(self.profile)
                profile["Entitlements"][key] = value
                with self.assertRaises(signing.SigningError):
                    signing.checked_profile(profile, self.team, self.bundle, self.now)

    def test_development_adhoc_enterprise_and_missing_health_are_rejected(self):
        mutations = [
            lambda p: p.update(ProvisionedDevices=["synthetic-device"]),
            lambda p: p.update(ProvisionedDevices=[]),
            lambda p: p.update(ProvisionsAllDevices=True),
            lambda p: p["Entitlements"].update({"get-task-allow": True}),
            lambda p: p["Entitlements"].update({"com.apple.developer.healthkit": False}),
            lambda p: p["Entitlements"].pop("beta-reports-active"),
        ]
        for mutate in mutations:
            profile = copy.deepcopy(self.profile)
            mutate(profile)
            with self.assertRaises(signing.SigningError):
                signing.checked_profile(profile, self.team, self.bundle, self.now)

    def test_expired_and_malformed_profile_fail_without_echoing_values(self):
        for field, value in [("ExpirationDate", self.now), ("UUID", "../../private-value"), ("DeveloperCertificates", []), ("DeveloperCertificates", ["private-value"]), ("Entitlements", None)]:
            profile = copy.deepcopy(self.profile)
            profile[field] = value
            with self.assertRaises(signing.SigningError) as caught:
                signing.checked_profile(profile, self.team, self.bundle, self.now)
            self.assertNotIn("private-value", str(caught.exception))

    def test_base64_accepts_wrapping_but_rejects_garbage_empty_and_oversized(self):
        encoded = base64.b64encode(b"synthetic bytes").decode()
        self.assertEqual(signing.decode_secret(encoded[:4] + "\n" + encoded[4:]), b"synthetic bytes")
        for value in ["", "***private-value***", "a" * (2 * 1024 * 1024 + 1)]:
            with self.assertRaises(signing.SigningError) as caught:
                signing.decode_secret(value)
            self.assertNotIn("private-value", str(caught.exception))

    def test_archive_profile_settings_do_not_override_package_signing(self):
        arguments = signing.archive_signing_settings(self.team, "A" * 40,
                                                     self.profile["UUID"], Path("/tmp/synthetic.keychain"))
        settings = dict(argument.split("=", 1) for argument in arguments)
        forbidden = {"DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY",
                     "PROVISIONING_PROFILE_SPECIFIER", "OTHER_CODE_SIGN_FLAGS",
                     "CODE_SIGNING_ALLOWED", "CODE_SIGNING_REQUIRED"}
        self.assertFalse(forbidden.intersection(settings))
        self.assertEqual(settings["MEEA_TEAM_ID"], self.team)
        self.assertEqual(settings["MEEA_PROFILE_UUID"], self.profile["UUID"])

    def test_archive_errors_publish_only_fixed_categories(self):
        cases = [
            ("error: SyntheticLibrary does not support provisioning profiles. PRIVATE_CANARY",
             "profile assigned to an unsupported target"),
            ("error: No profiles for PRIVATE_CANARY were found.",
             "matching provisioning profile not found"),
            ("error: PRIVATE_CANARY unknown failure", None),
        ]
        for output, category in cases:
            with self.subTest(category=category), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(signing.SigningError) as caught:
                    signing.command("Device archive", [sys.executable, "-c",
                                    "import sys; print(sys.argv[1]); sys.exit(1)", output], Path(directory))
                message = str(caught.exception)
                self.assertNotIn("PRIVATE_CANARY", message)
                self.assertNotIn("SyntheticLibrary", message)
                if category:
                    self.assertIn(category, message)
                else:
                    self.assertEqual(message, "Device archive failed; no raw signing log was published.")

    def test_apple_diagnostics_omit_private_values_and_bound_error_codes(self):
        output = ("ITMS-90683: Missing purpose string NSHealthUpdateUsageDescription "
                  "in PRIVATE_CANARY.bundle; user PRIVATE_CANARY@example.invalid")
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            with self.assertRaises(signing.SigningError) as caught:
                signing.command("Apple package validation", [sys.executable, "-c",
                                "import sys; print(sys.argv[1]); sys.exit(1)", output], state)
            message = str(caught.exception)
            self.assertIn("ITMS-90683", message)
            self.assertIn("Info.plist key NSHealthUpdateUsageDescription", message)
            self.assertNotIn("PRIVATE_CANARY", message)
            self.assertNotIn("Missing purpose string", message)
            log = state / "command.log"
            log.write_text("PRIVATE_CANARY unknown error")
            self.assertEqual(signing.apple_failure_hint(log), "")
            log.write_text(" ".join("ITMS-" + str(10000 + value) for value in range(20)))
            self.assertEqual(signing.apple_failure_hint(log).count("ITMS-"), 8)

    def test_identifier_rejects_shell_or_path_content(self):
        for value in ["../secret", "abc;echo private", "0123456789\n", None]:
            with self.assertRaises(signing.SigningError):
                signing.require_identifier(value, r"[A-Z0-9]{10}", "Invalid identifier.")


if __name__ == "__main__":
    unittest.main()
