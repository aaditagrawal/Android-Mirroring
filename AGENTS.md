# Repository guidance

Read [docs/architecture.md](docs/architecture.md) before changing module boundaries.

- Keep the decoder, renderer, frame pacer, and input socket paths free of new
  subprocesses, per-frame dispatches, and unbounded queues.
- Keep UI on the main thread. Agent handlers and blocking ADB work run off it.
  Respect the existing locks when sharing frames, sockets, or session state.
- Keep tool names and schemas in `Sources/AgentProtocol/AgentTools.swift`.
- Use `scripts/test.sh`, `swift run -c release mirror-selftest`, and
  `scripts/build-app.sh` for validation. Hardware tests need an explicitly selected
  phone and exclusive time to use it. Never take over another active session.
- Use Bun for JavaScript and uv for Python. Neither is required for the app build.
- Remove personal data from documentation, logs, fixtures, and screenshots.
- Add `Co-authored-by: Codex <codex@openai.com>` to commits assisted by Codex.
  Keep the human author and do not rewrite existing history to add trailers.
- In a fork, writes target the owner's `origin`. Upstream interaction is limited
  to fetch/pull unless the owner explicitly authorizes more. Any `gh` write must
  name the owner's repository explicitly with `--repo`.
