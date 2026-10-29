#!/usr/bin/env python3
"""Prepare an extension-enabled Blink IPA for iLoader 2.4.1 signing."""

import argparse
import hashlib
import plistlib
import re
import shutil
from pathlib import Path
from zipfile import BadZipFile, LargeZipFile, ZipFile


def prepare(source: Path, destination: Path, team_id: str) -> None:
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ValueError("Team ID must contain exactly 10 uppercase letters or digits")
    app_plist = "Payload/Blink.app/Info.plist"
    provider_plist = "Payload/Blink.app/PlugIns/BlinkFileProviderExtension.appex/Info.plist"
    ui_plist = "Payload/Blink.app/PlugIns/BlinkFileProviderExtensionUI.appex/Info.plist"

    with ZipFile(source) as archive:
        names = archive.namelist()
        for name in (app_plist, provider_plist, ui_plist):
            if names.count(name) != 1:
                raise ValueError(f"Expected exactly one {name}")
        if archive.testzip() is not None:
            raise ValueError("Input IPA failed its ZIP integrity check")

        app = plistlib.loads(archive.read(app_plist))
        provider_data = archive.read(provider_plist)
        provider = plistlib.loads(provider_data)
        bundle_id = app.get("CFBundleIdentifier")
        if not isinstance(bundle_id, str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
            raise ValueError("Invalid main bundle identifier")
        for name in (provider_plist, ui_plist):
            identifier = plistlib.loads(archive.read(name)).get("CFBundleIdentifier")
            if not isinstance(identifier, str) or not identifier.startswith(bundle_id + "."):
                raise ValueError(f"Extension identifier is not a child of the app: {name}")
        extension = provider.get("NSExtension", {})
        if extension.get("NSExtensionPointIdentifier") != "com.apple.fileprovider-nonui":
            raise ValueError("Unexpected File Provider extension")
        if not isinstance(extension.get("NSExtensionFileProviderDocumentGroup"), str):
            raise ValueError("File Provider has no document group")
        extension["NSExtensionFileProviderDocumentGroup"] = f"group.{bundle_id}.{team_id}"
        plist_format = plistlib.FMT_BINARY if provider_data.startswith(b"bplist00") else plistlib.FMT_XML
        replacement = plistlib.dumps(provider, fmt=plist_format, sort_keys=False)

        # Refuse to overwrite an existing IPA. Preserve each archive entry's
        # attributes (including executable bits and symlinks) when copying.
        with destination.open("xb") as output:
            try:
                with ZipFile(output, "w") as result:
                    result.comment = archive.comment
                    for info in archive.infolist():
                        if info.filename == provider_plist:
                            result.writestr(info, replacement)
                        else:
                            with archive.open(info) as src, result.open(info, "w") as dst:
                                shutil.copyfileobj(src, dst)
            except BaseException:
                destination.unlink(missing_ok=True)
                raise

    with ZipFile(destination) as result:
        if result.testzip() is not None:
            destination.unlink(missing_ok=True)
            raise ValueError("Output IPA failed its ZIP integrity check")
    digest = hashlib.sha256()
    with destination.open("rb") as output:
        for chunk in iter(lambda: output.read(1024 * 1024), b""):
            digest.update(chunk)
    print(f"Prepared {destination}\nSHA-256: {digest.hexdigest()}")
    print("Install this IPA using iLoader with the same Apple account.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("team_id", help="10-character Apple Developer Team ID (not a password)")
    args = parser.parse_args()
    try:
        prepare(args.source, args.destination, args.team_id)
    except (OSError, ValueError, BadZipFile, LargeZipFile) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
