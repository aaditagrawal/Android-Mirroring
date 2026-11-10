# Homebrew distribution

This repository can act as a personal Homebrew tap. It includes a source formula
for `HEAD` and generates a cask from a real release archive. A native app belongs
in Homebrew Cask for a normal binary installation; the source formula is for this
project's tap, not submission to `homebrew/core`.

The public repository is [aaditagrawal/Android-Mirroring](https://github.com/aaditagrawal/Android-Mirroring).
Source installs build from its `main` branch.

## Install from source

```sh
brew install --cask android-platform-tools
brew tap aaditagrawal/android-mirroring https://github.com/aaditagrawal/Android-Mirroring
# If Homebrew asks you to trust this third-party formula, review it first:
# brew trust --formula aaditagrawal/android-mirroring/android-mirroring
brew install --HEAD aaditagrawal/android-mirroring/android-mirroring
open "$(brew --prefix android-mirroring)/libexec/Android Mirroring.app"
```

The explicit tap URL is needed because the repository is not named with the
usual `homebrew-` prefix. The formula needs macOS 14+ and a Swift 6+ Xcode or
Command Line Tools installation. It builds the same release bundle as the manual
build, with SwiftPM's nested sandbox disabled for Homebrew.

Homebrew keeps the app under its managed prefix and links `droidctl` onto its
PATH. It does not overwrite an app in `/Applications`. The formula's caveats show
an optional Finder shortcut. Run `droidctl mcp` through Homebrew's stable bin path
when configuring agents. The app recognizes a matching Homebrew CLI symlink and
uses it in setup snippets so those paths survive upgrades.

ADB is a separate cask. A formula cannot depend on a cask, so install
`android-platform-tools` separately as shown above. `brew uninstall android-mirroring`
removes the Homebrew app and CLI; user settings and paired-phone data remain.

## Prepare a binary cask

After building, signing, and notarizing a release bundle through your release
process, package that exact bundle:

```sh
scripts/package-release.sh --no-build
scripts/generate-cask.sh aaditagrawal/Android-Mirroring build/Android-Mirroring-1.0.0-arm64.zip
```

`package-release.sh` verifies the app signature, reads its actual version and
architecture, and creates a ZIP with the app at its root and a SHA-256 sidecar.
Without `--no-build`, it first makes an ad-hoc source build. That local archive is
useful for validation but does not establish a notarized public release.

The cask generator computes the real ZIP checksum and writes
`build/homebrew/Casks/android-mirroring.rb`. It declares the app, `droidctl` binary,
Android platform-tools dependency, minimum macOS version, and the actual CPU
architecture. A universal bundle produces an unrestricted architecture cask.
A single-architecture archive is not advertised as supporting both Mac types.

1. Upload the exact ZIP to a GitHub release tagged `vVERSION` in your own repo.
2. Confirm the public download's SHA-256 matches the local sidecar.
3. Copy the generated definition to `Casks/android-mirroring.rb` and run
   `brew style` and `brew audit --cask --online` against the published artifact.
4. Commit the cask only after that URL works. Users can then install with
   `brew install --cask aaditagrawal/android-mirroring/android-mirroring`.

Do not install the formula and cask at the same time; both provide `droidctl`.
There is deliberately no active cask with an invented download URL or checksum
before the first release. To support separate Intel and Apple silicon downloads
in one cask later, add architecture-specific URLs and hashes from both artifacts.

## Validation

```sh
brew style Formula/android-mirroring.rb
scripts/build-app.sh --homebrew
scripts/check-cli.sh
scripts/package-release.sh --no-build
scripts/generate-cask.sh aaditagrawal/Android-Mirroring build/Android-Mirroring-1.0.0-arm64.zip
brew style build/homebrew/Casks/android-mirroring.rb
```

The formula has a device-free Homebrew `test do` block that reads the tool catalog
and sends an MCP ping to the installed CLI. After publishing the source:

```sh
brew test --HEAD aaditagrawal/android-mirroring/android-mirroring
```

See Homebrew's [formula cookbook](https://docs.brew.sh/Formula-Cookbook),
[Swift guidance](https://docs.brew.sh/Language-Specific-Formulae#swift), and
[cask cookbook](https://docs.brew.sh/Cask-Cookbook) for the packaging conventions.
