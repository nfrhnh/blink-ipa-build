import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from prepare_iloader import prepare


class PrepareILoaderTests(unittest.TestCase):
    def test_rewrites_only_provider_group_and_preserves_entry_attributes(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "input.ipa"
            output = Path(temp) / "output.ipa"
            app = "Payload/Blink.app/Info.plist"
            provider = "Payload/Blink.app/PlugIns/BlinkFileProviderExtension.appex/Info.plist"
            ui = "Payload/Blink.app/PlugIns/BlinkFileProviderExtensionUI.appex/Info.plist"
            executable = "Payload/Blink.app/Blink"
            with zipfile.ZipFile(source, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr(app, plistlib.dumps({"CFBundleIdentifier": "sh.blink.blinkshell"}))
                archive.writestr(provider, plistlib.dumps({"CFBundleIdentifier": "sh.blink.blinkshell.provider", "NSExtension": {
                    "NSExtensionPointIdentifier": "com.apple.fileprovider-nonui",
                    "NSExtensionFileProviderDocumentGroup": "group.sh.blink",
                }}))
                archive.writestr(ui, plistlib.dumps({"CFBundleIdentifier": "sh.blink.blinkshell.providerui"}))
                binary = zipfile.ZipInfo(executable)
                binary.external_attr = 0o100755 << 16
                archive.writestr(binary, b"test binary")

            prepare(source, output, "ABCD123456")
            with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as result:
                self.assertEqual(original.namelist(), result.namelist())
                for name in original.namelist():
                    self.assertEqual(original.getinfo(name).external_attr, result.getinfo(name).external_attr)
                    if name != provider:
                        self.assertEqual(original.read(name), result.read(name))
                extension = plistlib.loads(result.read(provider))["NSExtension"]
                self.assertEqual(extension["NSExtensionFileProviderDocumentGroup"],
                                 "group.sh.blink.blinkshell.ABCD123456")
                self.assertIsNone(result.testzip())
            with self.assertRaises(FileExistsError):
                prepare(source, output, "ABCD123456")

    def test_rejects_invalid_team_before_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output.ipa"
            with self.assertRaises(ValueError):
                prepare(Path(temp) / "input.ipa", output, "invalid")
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
