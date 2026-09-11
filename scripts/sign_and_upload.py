#!/usr/bin/env python3
"""Sign a reviewed GitHub revision and optionally upload it without publishing signing logs."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import uuid

CREDENTIALS = (
    "APPLE_TEAM_ID", "APPLE_DISTRIBUTION_P12_BASE64", "APPLE_DISTRIBUTION_P12_PASSWORD",
    "APPLE_PROVISIONING_PROFILE_BASE64", "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY",
)


class SigningError(Exception):
    """Messages in this class must contain only fixed, safe diagnostics."""


def require_identifier(value, pattern, message):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise SigningError(message)
    return value


def decode_secret(value):
    try:
        if not value or len(value) > 2 * 1024 * 1024:
            raise ValueError()
        result = base64.b64decode("".join(value.split()), validate=True)
        if not result or len(result) > 1024 * 1024:
            raise ValueError()
        return result
    except (ValueError, TypeError):
        raise SigningError("A signing file is missing or is not bounded, valid base64.") from None


def checked_profile(profile, team, bundle, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    try:
        profile_id = str(uuid.UUID(profile["UUID"]))
        expires = profile["ExpirationDate"]
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=dt.timezone.utc)
        entitlements = profile["Entitlements"]
        valid = (
            team in profile["TeamIdentifier"]
            and expires > now
            and entitlements.get("application-identifier") == team + "." + bundle
            and entitlements.get("com.apple.developer.team-identifier") == team
            and entitlements.get("com.apple.developer.healthkit") is True
            and entitlements.get("get-task-allow") is False
            and entitlements.get("beta-reports-active") is True
            and "ProvisionedDevices" not in profile
            and not profile.get("ProvisionsAllDevices", False)
        )
        certificates = profile["DeveloperCertificates"]
        valid = valid and isinstance(certificates, list) and bool(certificates)
        valid = valid and all(isinstance(c, bytes) and 0 < len(c) <= 100_000 for c in certificates)
        if not valid:
            raise ValueError()
        return profile_id, {hashlib.sha1(c).hexdigest().upper() for c in certificates}
    except (KeyError, TypeError, ValueError, AttributeError):
        raise SigningError("The profile must be an unexpired App Store profile for this team, exact app ID and HealthKit capability.") from None


def state_directory():
    runner = Path(os.environ["RUNNER_TEMP"]).resolve()
    run_id = require_identifier(os.environ.get("GITHUB_RUN_ID"), r"[1-9][0-9]*", "Invalid run identity.")
    attempt = require_identifier(os.environ.get("GITHUB_RUN_ATTEMPT"), r"[1-9][0-9]*", "Invalid run attempt.")
    state = runner / ("meea-signing-" + run_id + "-" + attempt)
    if state.is_symlink() or state.resolve().parent != runner:
        raise SigningError("Invalid temporary signing directory.")
    return state


def write_private(path, content):
    with path.open("xb") as output:
        os.chmod(path, 0o600)
        output.write(content)


def archive_signing_settings(team, identity, profile_id, keychain):
    # Only the app target maps these custom values to standard signing settings.
    # Command-line standard settings would also reach Swift package targets.
    return ["MEEA_TEAM_ID=" + team, "MEEA_SIGNING_IDENTITY=" + identity,
            "MEEA_PROFILE_UUID=" + profile_id, "MEEA_KEYCHAIN_PATH=" + str(keychain)]


def diagnostic_tail(log):
    try:
        with log.open("rb") as source:
            source.seek(max(0, log.stat().st_size - 2 * 1024 * 1024))
            return source.read(2 * 1024 * 1024).lower()
    except OSError:
        return b""


def archive_failure_hint(log):
    # Read a bounded tail and emit only fixed categories, never log fragments.
    output = diagnostic_tail(log)
    categories = (
        (b"does not support provisioning profiles", "profile assigned to an unsupported target"),
        (b"no profiles for", "matching provisioning profile not found"),
        (b"no profile for team", "matching provisioning profile not found"),
        (b"requires a provisioning profile", "matching provisioning profile not found"),
        (b"doesn't include signing certificate", "profile and signing certificate mismatch"),
    )
    for marker, category in categories:
        if marker in output:
            return " (" + category + ")"
    return ""


def apple_failure_hint(log):
    output = diagnostic_tail(log)
    # These are public diagnostic identifiers, never arbitrary JSON values or
    # snippets. All other text, including account/app values, remains private.
    codes = sorted({value.decode("ascii").upper()
                    for value in re.findall(rb"\bitms-[0-9]{5}\b", output)})[:8]
    fields = ("NSHealthUpdateUsageDescription", "NSHealthShareUsageDescription",
              "NSSiriUsageDescription", "NSMicrophoneUsageDescription",
              "CFBundleIconName", "CFBundleIcons", "CFBundleVersion",
              "CFBundleShortVersionString", "CFBundleIdentifier", "MinimumOSVersion")
    hints = ["Info.plist key " + field for field in fields if field.lower().encode() in output]
    categories = (
        (b"unable to authenticate", "Apple authentication failed"),
        (b"failed to authenticate", "Apple authentication failed"),
        (b"authentication failed", "Apple authentication failed"),
        (b"could not find a private key", "upload key lookup failed"),
        (b"invalid provisioning profile", "Apple rejected the provisioning profile"),
        (b"missing code-signing certificate", "Apple reported a missing signing certificate"),
        (b"invalid signature", "Apple rejected the signature"),
        (b"required icon", "required app icon metadata"),
        (b"agreement", "Apple account agreement"),
        (b"service unavailable", "Apple service unavailable"),
        (b"timed out", "Apple request timed out"),
        (b"not authorized", "Apple authorization failed"),
        (b"not supported", "unsupported Apple tool operation"),
    )
    hints.extend(category for marker, category in categories if marker in output)
    details = codes + list(dict.fromkeys(hints))[:8]
    return " (" + "; ".join(details) + ")" if details else ""


def encrypted_diagnostic_path():
    state = state_directory()
    return state.parent / (state.name.replace("meea-signing-", "meea-encrypted-diagnostic-", 1) + ".json")


def checked_envelope(path, context):
    # The encryptor is trusted reviewed code; this rejects partial/malformed output.
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 3 * 1024 * 1024:
        raise ValueError()
    data = path.read_bytes()
    envelope = json.loads(data)
    fields = {"version", "algorithm", "context", "wrappedKey", "nonce", "ciphertext", "tag"}
    if (set(envelope) != fields or type(envelope["version"]) is not int
            or envelope["version"] != 1 or envelope["algorithm"] != "RSA-OAEP-256+A256GCM"
            or envelope["context"] != context):
        raise ValueError()
    sizes = {"wrappedKey": (384, 1024), "nonce": (12, 12),
             "ciphertext": (0, 2 * 1024 * 1024), "tag": (16, 16)}
    for field, (minimum, maximum) in sizes.items():
        decoded = base64.b64decode(envelope[field], validate=True)
        if not minimum <= len(decoded) <= maximum:
            raise ValueError()
    return data


def preserve_apple_diagnostic(label, state, child_env):
    encoded = os.environ.get("DIAGNOSTIC_PUBLIC_KEY_BASE64")
    stages = {"Apple package validation": "validation", "Apple upload": "upload"}
    if not encoded or label not in stages:
        return
    published = None
    try:
        if state.resolve() != state_directory():
            raise ValueError()
        if len(encoded) > 12000:
            raise ValueError()
        key = base64.b64decode(encoded, validate=True)
        if not 1 <= len(key) <= 8192:
            raise ValueError()
        key_path = state / "diagnostic-public.der"
        write_private(key_path, key)
        context = "run=" + os.environ["GITHUB_RUN_ID"] + ";attempt=" + os.environ["GITHUB_RUN_ATTEMPT"] + ";stage=" + stages[label]
        candidate = state / "diagnostic-sealed.pending"
        result = subprocess.run(["swift", str(Path(__file__).with_name("EncryptSigningDiagnostic.swift")),
                                 str(key_path), str(state / "command.log"), str(candidate), context],
                                env=child_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=120, check=False)
        if result.returncode != 0:
            raise ValueError()
        data = checked_envelope(candidate, context)
        destination = encrypted_diagnostic_path()
        # Exclusive creation: never replace an existing file or follow a symlink.
        with destination.open("xb") as output:
            published = destination
            os.chmod(destination, 0o600)
            output.write(data)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write("encrypted_diagnostic=true\n")
        print("Encrypted Apple diagnostic prepared for the one-day attachment.", flush=True)
    except Exception:
        if published is not None:
            try:
                published.unlink(missing_ok=True)
            except OSError:
                pass  # No success output was emitted; attachment remains disabled.
        print("Encrypted Apple diagnostic unavailable; no diagnostic attachment prepared.", flush=True)


def command(label, args, state, *, cwd=None, timeout=900, structured=False):
    # Child build tools never inherit the original credential environment.
    child_env = {k: v for k, v in os.environ.items() if k not in CREDENTIALS}
    log = state / "command.log"
    with log.open("wb") as output:
        os.chmod(log, 0o600)
        try:
            result = subprocess.run(args, cwd=cwd, env=child_env, stdout=output,
                                    stderr=subprocess.DEVNULL if structured else subprocess.STDOUT, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise SigningError(label + " could not finish; no raw signing log was published.") from None
    if result.returncode != 0:
        hint = archive_failure_hint(log) if label == "Device archive" else ""
        if label in ("Apple package validation", "Apple upload"):
            hint = apple_failure_hint(log)
            preserve_apple_diagnostic(label, state, child_env)
        raise SigningError(label + " failed" + hint + "; no raw signing log was published.")
    # Small structured commands need their output; build log contents are never printed.
    with log.open("rb") as source:
        return source.read(2 * 1024 * 1024)


def read_signed_entitlements(app, state):
    data = command("Archive entitlement verification", ["codesign", "--display", "--entitlements", "-", "--xml", str(app)], state, structured=True)
    try:
        return plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException):
        raise SigningError("Could not read the signed archive entitlements as XML.") from None


def cleanup():
    state = state_directory()
    if not state.exists():
        return
    journal_path = state / "cleanup.json"
    journal = json.loads(journal_path.read_text()) if journal_path.exists() else {}
    failed = False
    original = journal.get("original_keychains")
    if original is not None:
        result = subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        failed = failed or result.returncode != 0
    keychain = state / "distribution.keychain-db"
    if keychain.exists():
        result = subprocess.run(["security", "delete-keychain", str(keychain)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        failed = failed or result.returncode != 0
    # Delete only files created by this run; never erase a whole shared key/profile directory.
    allowed = {
        Path.home() / "private_keys": r"AuthKey_[A-Z0-9]{10}\.p8",
        Path.home() / "Library/MobileDevice/Provisioning Profiles": r"[0-9a-f-]{36}\.mobileprovision",
        Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles": r"[0-9a-f-]{36}\.mobileprovision",
    }
    for name in journal.get("created_files", []):
        path = Path(name)
        pattern = allowed.get(path.parent)
        if pattern is None or re.fullmatch(pattern, path.name) is None:
            raise SigningError("Refusing an unexpected cleanup path.")
        path.unlink(missing_ok=True)
    if failed:
        raise SigningError("Signing keychain cleanup did not complete; the hosted runner must be discarded.")
    shutil.rmtree(state)


def run():
    if sys.platform != "darwin" or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch" or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise SigningError("Signed builds require a manual workflow run from main on a hosted Mac.")
    upload = os.environ.get("UPLOAD_TO_TESTFLIGHT")
    if upload not in ("true", "false"):
        raise SigningError("The upload option must be true or false.")
    required = CREDENTIALS if upload == "true" else CREDENTIALS[:4]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SigningError("Missing environment secrets: " + ", ".join(missing))
    team = require_identifier(os.environ["APPLE_TEAM_ID"], r"[A-Z0-9]{10}", "Invalid Apple team identifier.")
    bundle = require_identifier(os.environ.get("APP_BUNDLE_ID"), r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}", "Set APP_BUNDLE_ID to the registered explicit app identifier.")
    sequence = require_identifier(os.environ.get("GITHUB_RUN_NUMBER"), r"[1-9][0-9]{0,3}", "The build sequence must be between 1 and 9999.")
    attempt = require_identifier(os.environ.get("GITHUB_RUN_ATTEMPT"), r"[1-9][0-9]{0,1}", "The build attempt must be between 1 and 99.")
    build_number = sequence + "." + attempt
    state = state_directory()
    state.mkdir(mode=0o700, exist_ok=False)
    journal = {"created_files": []}
    journal_path = state / "cleanup.json"

    def save_journal():
        journal_path.write_text(json.dumps(journal), encoding="utf-8")
        os.chmod(journal_path, 0o600)

    def install_owned(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            raise SigningError("A signing file already exists on the runner; refusing to replace it.") from None
        with os.fdopen(descriptor, "wb") as output:
            journal["created_files"].append(str(path))
            save_journal()
            output.write(data)

    save_journal()
    try:
        head = command("Revision check", ["git", "rev-parse", "HEAD"], state).decode().strip()
        if head != os.environ.get("GITHUB_SHA"):
            raise SigningError("The checkout does not match the manually selected revision.")
        version = command("Xcode check", ["xcodebuild", "-version"], state).decode()
        match = re.search(r"Xcode (\d+)", version)
        if not match or int(match.group(1)) < 26:
            raise SigningError("App Store Connect uploads require Xcode 26 or later.")
        profile_data = decode_secret(os.environ["APPLE_PROVISIONING_PROFILE_BASE64"])
        profile_path = state / "input.mobileprovision"
        write_private(profile_path, profile_data)
        # security cms emits decoded XML; capture it privately, never to public job logs.
        decoded = command("Profile decoding", ["security", "cms", "-D", "-i", str(profile_path)], state, structured=True)
        try:
            profile = plistlib.loads(decoded)
        except (ValueError, plistlib.InvalidFileException):
            raise SigningError("Could not decode the provisioning profile.") from None
        profile_id, profile_certificates = checked_profile(profile, team, bundle)
        for folder in ("Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"):
            install_owned(Path.home() / folder / (profile_id + ".mobileprovision"), profile_data)

        p12 = state / "distribution.p12"
        write_private(p12, decode_secret(os.environ["APPLE_DISTRIBUTION_P12_BASE64"]))
        keychain = state / "distribution.keychain-db"
        password = secrets.token_urlsafe(48)
        original = command("Keychain inventory", ["security", "list-keychains", "-d", "user"], state).decode()
        journal["original_keychains"] = shlex.split(original)
        save_journal()
        command("Create signing keychain", ["security", "create-keychain", "-p", password, str(keychain)], state)
        command("Set keychain lifetime", ["security", "set-keychain-settings", "-lut", "21600", str(keychain)], state)
        command("Unlock signing keychain", ["security", "unlock-keychain", "-p", password, str(keychain)], state)
        command("Import distribution identity", ["security", "import", str(p12), "-P", os.environ["APPLE_DISTRIBUTION_P12_PASSWORD"], "-k", str(keychain), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], state)
        command("Authorize Apple signing tools", ["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain)], state)
        command("Select signing keychain", ["security", "list-keychains", "-d", "user", "-s", str(keychain), *journal["original_keychains"]], state)
        identities = command("Verify signing identity", ["security", "find-identity", "-v", "-p", "codesigning", str(keychain)], state).decode()
        matches = profile_certificates.intersection(re.findall(r"\b[A-F0-9]{40}\b", identities))
        if len(matches) != 1:
            raise SigningError("The P12 must contain exactly one valid signing identity allowed by the profile.")
        identity = next(iter(matches))
        print("Signing inputs verified; building device archive.", flush=True)
        archive = state / "MeeABridge.xcarchive"
        command("Device archive", ["xcodebuild", "-project", "MeeABridge.xcodeproj", "-scheme", "MeeABridge", "-configuration", "Release", "-destination", "generic/platform=iOS", "-archivePath", str(archive), "-derivedDataPath", str(state / "DerivedData"), "PRODUCT_BUNDLE_IDENTIFIER=" + bundle, "CURRENT_PROJECT_VERSION=" + build_number, *archive_signing_settings(team, identity, profile_id, keychain), "archive"], state, timeout=1200)
        app = archive / "Products/Applications/MeeABridge.app"
        command("Archive signature verification", ["codesign", "--verify", "--deep", "--strict", str(app)], state)
        info = plistlib.loads((app / "Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != bundle or info.get("CFBundleVersion") != build_number:
            raise SigningError("The archive identity does not match the requested build.")
        signed_entitlements = read_signed_entitlements(app, state)
        if (signed_entitlements.get("application-identifier") != team + "." + bundle
                or signed_entitlements.get("com.apple.developer.healthkit") is not True
                or signed_entitlements.get("get-task-allow", False) is not False):
            raise SigningError("The signed archive does not have the expected app identity and HealthKit entitlements.")
        options = {
            "method": "app-store-connect", "destination": "export", "signingStyle": "manual",
            "teamID": team, "signingCertificate": identity, "provisioningProfiles": {bundle: profile_id},
            "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
            "testFlightInternalTestingOnly": True,
        }
        export_options = state / "ExportOptions.plist"
        write_private(export_options, plistlib.dumps(options))
        exported = state / "Export"
        command("App Store export", ["xcodebuild", "-exportArchive", "-archivePath", str(archive), "-exportPath", str(exported), "-exportOptionsPlist", str(export_options)], state)
        packages = list(exported.glob("*.ipa"))
        if len(packages) != 1:
            raise SigningError("The export did not produce exactly one iPhone package.")
        if upload == "true":
            key_id = require_identifier(os.environ["ASC_KEY_ID"], r"[A-Z0-9]{10}", "Invalid App Store Connect key identifier.")
            try:
                issuer = str(uuid.UUID(os.environ["ASC_ISSUER_ID"]))
            except ValueError:
                raise SigningError("Invalid App Store Connect issuer identifier.") from None
            key = os.environ["ASC_PRIVATE_KEY"].strip()
            if not key.startswith("-----BEGIN PRIVATE KEY-----") or not key.endswith("-----END PRIVATE KEY-----") or len(key) > 16_384:
                raise SigningError("The App Store Connect key must be a bounded PKCS8 private key.")
            install_owned(Path.home() / "private_keys" / ("AuthKey_" + key_id + ".p8"), (key + "\n").encode())
            common = ["--file", str(packages[0]), "--type", "ios", "--apiKey", key_id, "--apiIssuer", issuer, "--output-format", "json"]
            command("Apple package validation", ["xcrun", "altool", "--validate-app", *common], state)
            print("Apple package validation passed; uploading to App Store Connect.", flush=True)
            command("Apple upload", ["xcrun", "altool", "--upload-app", *common], state, timeout=900)
            print("Upload accepted. Apple processing and internal TestFlight availability still require confirmation.", flush=True)
        else:
            print("Signed archive and export passed. Upload was disabled; no installable artifact was published.", flush=True)
        summary = Path(os.environ["GITHUB_STEP_SUMMARY"])
        with summary.open("a", encoding="utf-8") as output:
            output.write("Signed build " + build_number + " completed. " + ("Apple accepted the upload; verify processing and internal tester access in App Store Connect." if upload == "true" else "Upload was disabled.") + "\n")
    finally:
        cleanup()


def interrupted(_signal, _frame):
    raise SigningError("The signing run was interrupted.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        cleanup() if args.cleanup else run()
    except SigningError as error:
        print("::error::" + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Unknown exceptions may include file contents or signing/account details.
        print("::error::Distribution failed unexpectedly; no private diagnostic contents were published.", file=sys.stderr)
        sys.exit(1)
