# Third-party notices

Original code in this repository is available under the [MIT license](LICENSE).

## scrcpy server

`Resources/scrcpy-server` is the unmodified Android server from
[scrcpy v5.0.1](https://github.com/Genymobile/scrcpy/releases/tag/v5.0.1), by
Genymobile and the scrcpy contributors. It is distributed under the Apache
License 2.0. The full license is in [Resources/scrcpy-LICENSE](Resources/scrcpy-LICENSE)
and is copied into every app bundle.

- Source: <https://github.com/Genymobile/scrcpy/tree/v5.0.1/server>
- Binary: <https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1>
- SHA-256: `764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`

The macOS client speaks the scrcpy protocol. It does not bundle scrcpy's desktop
client, SDL, or FFmpeg. Protocol and server upgrades must be reviewed together.

## Android relay

`Resources/relay.jar` is this project's own DEX payload, compiled from
[android/relay/src/Relay.java](android/relay/src/Relay.java), under the repository's
MIT license. Rebuild instructions are in [docs/development.md](docs/development.md).
The prebuilt payload lets contributors build the Mac app without an Android SDK.

[Resources/SHA256SUMS](Resources/SHA256SUMS) records the distributed payloads and
scrcpy license. Run `scripts/check-resources.sh` to check them.

## Tools and platform frameworks

ADB and Tailscale are discovered on the user's system and are not bundled.
AppKit, SwiftUI, Metal, VideoToolbox, Vision, and the other Apple frameworks are
provided by macOS. Android SDK classes used to compile the relay are provided by
Android at runtime.
