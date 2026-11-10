Precompiled **Apple silicon** build for macOS 14 or later.

1. Download the `arm64.dmg` asset, open it, and drag Android Mirroring to Applications.
2. Install ADB with `brew install --cask android-platform-tools`.
3. Open the app and pair your Android phone. No Xcode or Swift installation is needed.

The app includes `droidctl` for CLI and MCP agent access. See the
[README](https://github.com/aaditagrawal/Android-Mirroring#readme) for setup.

This build is **ad-hoc signed and not Apple-notarized**. macOS may block the
downloaded app. The ZIP is an alternative containing the same app; `.sha256`
files provide checksums. No Intel binary is included in this release.
