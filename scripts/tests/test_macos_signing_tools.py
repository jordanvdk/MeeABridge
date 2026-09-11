import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("sign_and_upload", Path(__file__).parents[1] / "sign_and_upload.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


@unittest.skipUnless(sys.platform == "darwin", "Requires native macOS signing tools; no Apple account or certificate needed.")
class MacSigningToolsTests(unittest.TestCase):
    def test_modern_codesign_entitlements_are_read_as_xml(self):
        with tempfile.TemporaryDirectory(prefix="meea-signing-probe-") as directory:
            root = Path(directory)
            source = root / "probe.c"
            binary = root / "probe"
            entitlements = root / "entitlements.plist"
            source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
            entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
            subprocess.run(["xcrun", "clang", str(source), "-o", str(binary)], check=True, capture_output=True)
            subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(binary)], check=True, capture_output=True)
            decoded = signing.read_signed_entitlements(binary, root)
            self.assertIs(decoded["com.apple.security.app-sandbox"], True)


if __name__ == "__main__":
    unittest.main()
