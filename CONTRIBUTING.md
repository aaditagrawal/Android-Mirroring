# Contributing

Start with the [development guide](docs/development.md) and
[architecture](docs/architecture.md). The app is a Swift package with no external
Swift dependencies. A phone is not required for the normal checks.

Before submitting a change, run:

```sh
scripts/check-resources.sh
scripts/test.sh
swift run -c release mirror-selftest
scripts/build-app.sh
scripts/check-cli.sh
```

Keep changes focused. Document behavior changes in the relevant guide. New agent
tools need a schema in `AgentTools.swift`, a handler, and tests. Changes to video,
transport, or gesture timing need comparable before/after measurements. Report
resolution, codec, frame rate, Mac, phone, and connection type. Synthetic pacing
statistics alone do not establish end-to-end latency.

Hardware tests can open apps or send gestures. Choose a spare phone or coordinate
an exclusive window with its owner. Do not run them on a shared device by default.
Remove personal data before attaching logs or screenshots to issues.

For forks, push and open pull requests against your own `origin`. Only fetch or
pull from upstream unless the upstream owner has authorized a write.

## Commit attribution

Keep the contributor as the commit author. For work assisted by Codex, add this
trailer after a blank line in the commit message:

```text
Co-authored-by: Codex <codex@openai.com>
```

This applies to new commits. Do not rewrite someone else's history to add it.
