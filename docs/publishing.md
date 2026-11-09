# GitHub publication

The checkout is prepared for a first push. Creating the GitHub repository and
publishing it are separate steps. No remote URL, release badge, download link,
or signing identity is assumed in the README.

## First push

1. Review the MIT license choice and the bundled scrcpy license and notices.
2. Run the checks in [CONTRIBUTING.md](../CONTRIBUTING.md). Review the README
   screenshots and `git diff --check`. Confirm no private files are staged.
3. Inspect both current files and branch history for credentials, phone content,
   personal addresses, and recordings. `.gitignore` does not remove old commits.
   If older history should remain private, publish a reviewed source snapshot
   in a fresh repository instead of rewriting this working checkout.
4. Create an empty repository in your own GitHub account. Keep its default branch
   consistent with this checkout, which uses `main`.
5. Add that owned repository as `origin`, verify it, then push only the intended
   branch. Do not push orchestration/checkpoint refs with `--mirror` or `--all`.

```sh
git remote add origin git@github.com:YOUR_ACCOUNT/Android-Mirroring.git
git remote -v
git push -u origin main
```

If an `origin` already exists, inspect it rather than overwriting it. In a fork,
all pushes, PRs, comments, and other writes target the owner's `origin`. Only
fetch or pull upstream unless its owner explicitly authorizes other actions.
For every GitHub CLI write, specify the owned repository with `--repo`.

After the first push, confirm the macOS workflow actually passes on GitHub.
Enable branch protection and private vulnerability reporting as appropriate for
the repository. Local validation cannot establish hosted CI results.

## Release preparation

The build script currently labels bundles `1.0.0` and builds for the current Mac's
architecture. Before advertising a downloadable release:

- Choose a release version and update the bundle and MCP server version together.
- Test on supported macOS versions and representative Android phones. Include
  pairing, audio, clipboard, reconnects, and agent access. Report gaps honestly.
- Decide whether to distribute separate architectures or a tested universal app.
- Use a Developer ID identity and notarization for a normal public macOS download.
  Ad-hoc local signing is not notarization. Keep signing secrets out of Git.
- Include the license and third-party notices in the distributed bundle.
- Create an archive, verify its extracted signature, record SHA-256, and publish
  release notes that describe tested behavior and remaining limits.

This repository supplies a build and validation workflow, not an automated signed
release pipeline.

## Homebrew

The source formula uses `aaditagrawal/Android-Mirroring`. Follow [Homebrew distribution](homebrew.md)
for the tap, release ZIP, and checksummed cask. Publish the binary before adding
an active cask definition.

## Codex attribution

New commits assisted by Codex include:

```text
Co-authored-by: Codex <codex@openai.com>
```

The human remains the commit author. Existing history is preserved rather than
rewritten just to add attribution.
