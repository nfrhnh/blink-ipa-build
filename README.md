# blink-ipa-build

Builds an **unsigned** Blink Shell IPA from its GPL-3.0 source on a GitHub Actions macOS runner.

- Builder script: vendored copy of `NewsGuyTor/Blink-Shell-GPL-Builder` (`build-blink-shell-gpl.sh`).
- Blink source: `blinksh/blink`, GPL-3.0.
- Output: `dist/Blink-unsigned-<version>.ipa`, uploaded as a workflow artifact.

Run it from the Actions tab (workflow_dispatch) and pick the Blink release tag.

The IPA is unsigned — install it with your own signing tool (iloader / SideStore / Sideloadly).
Nothing here is distributed as a binary commit.

## Experimental iLoader build with File Provider

Select `extensions=keep` and `shim=none` in Actions. The build keeps the File
Provider extensions and resolves the shared group using the installed app's
bundle identifier. It removes the subscription and hosted Build entries from
Settings and the hosted Build page from the walkthrough. The existing
subscription gate patch is retained; the purchase SDK and other upstream
subscription code are still present. This is not a complete removal of those
dependencies.

This mode is experimental and has not been tested on a device. It targets
iLoader 2.4.1's group naming and extension-signing behavior. Before installing,
use Python 3.11 or newer to prepare the unsigned IPA locally:

```sh
python3 prepare_iloader.py Blink-unsigned-v18.4.2.ipa Blink-iloader.ipa TEAMID1234
```

Replace `TEAMID1234` with the 10-character Team ID of the Apple account used
by iLoader; never provide an Apple password or signing certificate. The command
updates the File Provider's group declaration and refuses to overwrite an
existing output. Sign and install the resulting IPA using the same account.

The previous build used a private fallback directory and disabled migration.
This build uses a real shared group and **does not migrate the old data**.
Back up existing hosts, keys, and files before installing; do not assume that
installing it over the current app preserves access to those data. Test the
main app, SSH, keys, and File Provider on a device before relying on it.
