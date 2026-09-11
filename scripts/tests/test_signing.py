import base64
import copy
import datetime as dt
import hashlib
import importlib.util
from pathlib import Path
import unittest

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

    def test_identifier_rejects_shell_or_path_content(self):
        for value in ["../secret", "abc;echo private", "0123456789\n", None]:
            with self.assertRaises(signing.SigningError):
                signing.require_identifier(value, r"[A-Z0-9]{10}", "Invalid identifier.")


if __name__ == "__main__":
    unittest.main()
