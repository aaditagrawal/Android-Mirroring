# Architecture

The Swift package has three reusable boundaries and four executable targets.
The app owns windows and presentation; MirrorKit owns the phone session; the
shared agent protocol keeps MCP and CLI clients independent of UI and decoding.

| Target | Owns | Depends on |
| --- | --- | --- |
| `AgentProtocol` | API configuration, tool schemas, Unix-socket client | Foundation |
| `MirrorKit` | ADB, device discovery, scrcpy, media, session, agent server | AgentProtocol, macOS frameworks |
| `AndroidMirroring` | Windows, settings, input translation, Metal display, platform integration | MirrorKit, AgentProtocol |
| `droidctl` | CLI dispatch, app startup, MCP stdio framing | AgentProtocol |
| `mirror-bench` | Opt-in phone performance experiments | MirrorKit |
| `mirror-selftest` | Protocol, OCR, settling, and deterministic pacing checks | MirrorKit |
| `MirrorKitTests` | Swift Testing protocol and local API regression tests | MirrorKit, AgentProtocol |

## Source map

```text
Sources/
  AgentProtocol/
    AgentProtocol.swift       API paths and bundle identity
    AgentTools.swift          Single catalog of tools, schemas, and action names
    AgentClient.swift         Newline-delimited JSON over a Unix socket
  AndroidMirroring/
    main.swift                App lifecycle, menus, status item, windows
    AppModel.swift            Connect UI actions to services
    DevicesView.swift         Pairing and device selection
    MirrorView.swift           Native input and text handling
    MirrorWindowController.swift
    VideoRenderer.swift       Metal display link and NV12 rendering
    Settings/                 One view per pane, reusable row/card components
    Platform/                 Keychain and own-window capture helpers
  MirrorKit/
    ADB/                      ADB server protocol, sockets, file sync
    Scrcpy/                   Session, wire control encoding, transport negotiation
    Media/                    Video/audio decode, latest frame, OCR, frame pacing
    Devices/                  Device identity, discovery, known paths, health
    Session/                  Lifecycle/failover, settings, input and gestures
    Android/                  Keycodes, UI trees, app and notification queries
    Agent/                    Socket lifecycle, routing, coordinates, input,
                              observation and device tool handlers
  droidctl/                   CLI, help, app connection, MCP server
android/relay/                Token-authenticated direct TCP bridge on Android
Resources/                    Pinned Android runtime payloads and checksums
Tests/MirrorKitTests/         Device-free regression checks
```

## Video and control paths

ADB starts the version-matched scrcpy server on the phone. USB normally carries
media and control through ADB. On network paths, the app tries its own TCP relay
on known phone addresses, then falls back to ADB. The relay receives a random
per-session authentication token over ADB. Direct TCP is unencrypted; see
[SECURITY.md](../SECURITY.md).

VideoToolbox decodes H.265/H.264 into IOSurface-backed NV12 pixel buffers. The
latest decoded frame goes to `FrameStore` for screenshots and OCR and to
`FramePacer` for display scheduling. A `CAMetalDisplayLink` selects frames using
their capture timestamps and observed arrival jitter. Metal reads the NV12
planes through a texture cache and converts them to RGB while scaling. If Metal
initialization fails, the view can use an `AVSampleBufferDisplayLayer` fallback.

Input uses the persistent scrcpy control socket. Network relay control messages
include timestamps so Android can replay their spacing. This code path avoids
launching an `adb` process per event. File installation and pairing still use
the external `adb` executable where needed.

## Ownership and concurrency

- AppKit, SwiftUI state, and published session state belong on the main thread.
- `MirrorController` serializes session startup and reconnect work on its session
  queue. A lock protects the current session reference for decoder/agent access.
- Socket readers and the Metal display link have dedicated threads. FrameStore,
  pacing, and statistics use locks around shared state.
- Agent connections run on separate threads; requests within a connection run
  in order. Handlers are split by responsibility as extensions of the same server,
  retaining the existing state owner and caches. They do not add queues to the
  video or gesture paths.
- Multiple agent clients can send overlapping actions. There is no exclusive
  phone lease. Coordinate outside the app when sharing a phone with other tools.

The package uses Swift 5 language mode with a Swift 6 toolchain. Existing
`@unchecked Sendable` types rely on explicit synchronization; the codebase is
not a completed strict-concurrency migration. Release MirrorKit currently keeps
its existing `-Ounchecked` optimization setting. Treat changes to buffer indexing
or synchronization as performance-sensitive and validate them carefully.

## Agent loop

The app listens on a local, user-only Unix socket. `droidctl` speaks this API
directly or translates MCP stdio requests into it. The tool catalog is the shared
source of action names and parameter schemas.

An action can wait for `FrameStore`'s luma signature to stop changing and encode
the settled frame in the same response. OCR results are cached by frame counter;
UI tree and app queries have separate caches. Coordinate helpers translate
screenshot pixels, normalized coordinates, and Android display coordinates.

These are implementation choices, not latency guarantees. Use the
[performance procedure](development.md#performance-work) to measure a change.
