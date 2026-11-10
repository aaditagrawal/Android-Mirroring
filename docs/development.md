# Development

## Requirements and builds

Use macOS 14+ and Swift 6+ with Swift Testing support. Current Xcode or its
Command Line Tools supply the required frameworks. The test script runs Swift
Testing without XCTest and discovers the testing macro plugin on toolchains that
store it in a subdirectory.
The package uses Swift 5
language mode and has no external Swift dependencies.

```sh
swift build
scripts/check-resources.sh
scripts/test.sh
swift run -c release mirror-selftest
scripts/build-app.sh
scripts/check-cli.sh
```

`scripts/build-app.sh` builds both shipping executables, copies the Android
payloads and license notices, creates the app icon and Info.plist, and applies an
ad-hoc signature. `--install` replaces the installed app. Builds target the host
architecture by default; an Apple silicon build is not a universal binary.
The GitHub workflow runs these device-free checks on a macOS runner.
`scripts/package-release.sh --no-build` packages the bundle as a ZIP and a DMG;
`scripts/check-dmg.sh PATH` verifies the installer by mounting it read-only.

## Tests

`scripts/test.sh` covers wire packets, UTF-8 truncation, device parsing, transport
classification, tool schema consistency, and actual local socket round trips,
permissions, reconnects, and invalid paths. It does not start ADB or use a phone.

`mirror-selftest` also exercises Vision OCR on generated text, luma signatures,
settle timing, and frame pacing with deterministic network jitter. It prints
measured timings and fails on incorrect behavior or broad timing bounds. A busy
or background-throttled Mac can affect timing checks. The full suite has a 90-second deadline and prints each test before it runs.
Use `--only pacing,settle-signature,touch` to isolate checks when diagnosing a
framework failure; a subset pass does not cover the omitted checks.
The `--pacing` option prints
an aggregate simulation across several fixed seeds; it is not an end-to-end
phone benchmark.

`scripts/check-cli.sh` checks help, tool lists, MCP initialization, notifications,
ping, and error responses. It only requests operations that need no app or phone.

## Android payloads

The checked-in scrcpy server is tied to the protocol version in
`ScrcpySession.serverVersion`. Verify it with `scripts/check-resources.sh` before
bundling. Source and download links are in [third-party notices](../THIRD_PARTY_NOTICES.md).
Do not replace the binary without reviewing its matching protocol implementation.

The direct relay is this project's Java code. To rebuild it, install JDK 17+
and Android SDK packages `platforms;android-35` and `build-tools;35.0.0`, then:

```sh
ANDROID_HOME="$HOME/Library/Android/sdk" android/relay/build.sh
shasum -a 256 Resources/relay.jar
```

`ANDROID_SDK_ROOT` is accepted when `ANDROID_HOME` is unset. Optional
`ANDROID_PLATFORM` and `ANDROID_BUILD_TOOLS` select different installed versions.
Compilation failures stop the script. Review the resulting JAR and update its
entry in `Resources/SHA256SUMS` deliberately. Toolchain versions can change binary
hashes, so a rebuild is not assumed to be byte-for-byte identical.

## Performance work

Keep representative hardware measurements separate from synthetic tests. Get an
exclusive testing window on a chosen phone first. The benchmark's `latency`,
`smooth`, and `all` modes launch Android Settings on a virtual display and send
input there. `passive` streams without scripted input, and uses the physical
display unless `PERF_VD` is set.

```sh
swift build -c release --product mirror-bench
scripts/perf.sh DEVICE_SERIAL passive 10
scripts/perf.sh DEVICE_SERIAL all 10
PERF_LABEL=baseline scripts/perf.sh DEVICE_SERIAL all 10
```

`perf.sh` runs the benchmark through launchd to avoid inherited background
scheduling. Results go under `.build/perf/` unless `PERF_LOGDIR` or `PERF_OUT`
overrides them. Compare identical workloads with `scripts/perf-sweep.sh`. Its
summary uses `uv run --no-project python`, so install uv if you use that helper.
The benchmark source lists its `PERF_*` configuration variables.

`present-test.sh` temporarily changes the installed app's virtual-display and
pacing settings and restarts it. `usb-experiment.sh WIFI_HOST` also opens test
sessions and changes the selected connection. These are manual lab tools, not
CI checks. Read their scripts before using them on a normal workspace.

Record the Mac model, display refresh rate, phone and Android version, network,
codec, resolution, bitrate, and frame cap with results. Compare latency,
frame cadence, and dropped/repeated presentations. Time to decode a changed
frame does not include the Mac display's final scanout.

## Screenshots

README images are real captures of the app's Picture and Shortcuts settings panes,
with no connected phone content. `debug_window` can capture the app's own windows
through the local API. Capture only a session you control. Review images at
native resolution before committing, including paths, phone names, accounts,
notifications, and screen content. Keep temporary captures and benchmark output
in `.build/`, not documentation folders.
