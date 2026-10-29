# blink-ipa-build

Builds an **unsigned** Blink Shell IPA from its GPL-3.0 source on a GitHub Actions macOS runner.

- Builder script: vendored copy of `NewsGuyTor/Blink-Shell-GPL-Builder` (`build-blink-shell-gpl.sh`).
- Blink source: `blinksh/blink`, GPL-3.0.
- Output: `dist/Blink-unsigned-<version>.ipa`, uploaded as a workflow artifact.

Run it from the Actions tab (workflow_dispatch) and pick the Blink release tag.

The IPA is unsigned — install it with your own signing tool (iloader / SideStore / Sideloadly).
Nothing here is distributed as a binary commit.
