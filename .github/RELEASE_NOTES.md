## What's new in 1.0.1

- An iPhone Mirroring-style outline and attached toolbar, rendered as one
  continuous Liquid Glass surface on macOS 26 or later.
- Controls reveal near the top of the phone and hide while reading or scrolling.
- Expanded windows reclaim the reserved toolbar gap while preserving the phone's
  proportions. The outline stays outside the video, and older macOS versions use
  a standard-material fallback.

## Installation

Precompiled **Apple silicon** build for macOS 14 or later.

1. Download the `arm64.dmg` asset, open it, and drag Android Mirroring to Applications.
2. Install ADB with `brew install --cask android-platform-tools`.
3. Open the app and pair your Android phone. No Xcode or Swift installation is needed.

The app includes `droidctl` for CLI and MCP agent access. See the
[README](https://github.com/aaditagrawal/Android-Mirroring#readme) for setup.

This build is **ad-hoc signed and not Apple-notarized**. macOS may block the
downloaded app. The ZIP is an alternative containing the same app; `.sha256`
files provide checksums. No Intel binary is included in this release.
