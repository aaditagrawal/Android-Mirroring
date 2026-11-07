# Android Mirroring

A native macOS app for using your Android phone from your Mac, like Apple's iPhone Mirroring, over wireless ADB. It is built for low latency on Wi-Fi and over Tailscale, and it gives AI agents full, fast control of the phone.

![icon](docs/icon.png)

## What you get

| | iPhone Mirroring | Android Mirroring |
|---|---|---|
| See & control the phone in a Mac window | ✓ | ✓ (H.265/H.264 hardware decode, up to 120 fps) |
| Phone stays locked / private while mirroring | phone must be locked | optional: **turn the phone screen off** while mirroring; or keep using the phone at the same time |
| Keyboard, trackpad, gestures | ✓ | ✓ two-finger scroll becomes a real finger swipe with fling, pinch-to-zoom, IME/emoji input, ⌥-word editing |
| Home / App Switcher shortcuts | ⌘1 / ⌘2 | ⌘1 Home, ⌘2 Recents, ⌘3 Notifications, ⌘4 Quick Settings, Esc / ⌘[ / right-click Back |
| Phone notifications on the Mac | ✓ | ✓ click one to open that app on the phone |
| Phone audio on the Mac | ✓ | ✓ (Opus, Android 11+) |
| Clipboard | Universal Clipboard | two-way sync, ⌘C/⌘X/⌘V go through the phone clipboard |
| Drag & drop | files | drop an **.apk to install**, any other file → phone's Downloads |
| Works away from home | no (same Apple ID nearby) | **yes, over Tailscale**, with automatic failover between USB / Wi-Fi / Tailscale |
| AI agent control | no | **MCP server + CLI** (`droidctl`): screenshots in ~10 ms from the live stream, taps, swipes, typing, UI tree, app launch, notifications… |

## Install

```bash
scripts/build-app.sh --install     # builds a release .app into /Applications
```

You need the Xcode Command Line Tools and `adb` (`brew install android-platform-tools`). The app finds `adb` in Homebrew, the Android SDK, or `PATH`, and talks to the ADB server directly through its socket protocol.

## Connecting a phone

1. On the phone, turn on **Developer options › Wireless debugging**, or plug in USB once and run `adb tcpip 5555`.
2. Open Android Mirroring. Then either:
   - **Pair by QR code** (Phones window ⇧⌘P → QR Code): on the phone, tap *Pair device with QR code* and scan.
   - **Pairing code**: the app discovers the phone over Bonjour; type the 6-digit code.
   - **IP address**: `phone-ip:5555`, or the phone's **Tailscale** address. Android devices on your tailnet are listed for one-click connection.
3. The first time this Mac connects, the phone asks *"Allow USB debugging?"*. Unlock it, tick *Always allow from this computer*, and tap **Allow**.

After that the app reconnects automatically. It remembers every address your phone has been reachable at.

## Making the connection better

Wireless ADB on its own is fragile: the Wireless debugging port changes, Wi-Fi roams, and the link drops when you leave home. Android Mirroring adds:

- **Multi-path with hot standby.** Each phone is identified by its hardware serial, not its address. All of its paths (USB, Wi-Fi `ip:5555`, the Wireless debugging mDNS service, and its Tailscale `100.x` address) are kept connected at the same time. A path's latency is probed every 3 s while you mirror.
- **Failover in about a second.** If the active path fails a health probe twice, or the stream drops, the stream restarts on the next-best healthy path. The scrcpy server is cached on the phone, so a restart takes about 0.4 s. Retries back off exponentially.
- **Automatic upgrade.** When a better path has stayed healthy for 4 s (you got home, or plugged in a cable), the stream moves to it. The order is USB, then Wi-Fi, then Wireless debugging, then Tailscale.
- **Adaptive quality.** *Automatic* uses native resolution at 12 Mbps on Wi-Fi, 20 Mbps over USB, and 1600 px at 6 Mbps over Tailscale or any path above 60 ms RTT.
- **Tailscale means it works anywhere.** When the phone leaves Wi-Fi, Tailscale carries the ADB connection over mobile data, so the session survives.

**Why not Bluetooth?** ADB cannot run over Bluetooth on current Android. The only Bluetooth option is PAN tethering, which carries IP at about 1–2 Mbps with high latency. That is far below what a usable video stream needs. Wi-Fi, USB, and Tailscale (Wi-Fi or cellular underneath) give strictly better redundancy.

## Performance design

- **Native Swift, no Electron, no ffmpeg.** Video is decoded by VideoToolbox in hardware, synchronously on the network thread, and shown through `AVSampleBufferDisplayLayer` with `DisplayImmediately`. There is no frame queue, so decode adds about 2–4 ms.
- **No subprocesses on the hot path.** The app speaks the ADB server protocol over its socket. Video, audio, and control sockets open straight through the transport (`localabstract:` service), so no `adb forward` ports are needed. An ADB request costs under 1 ms instead of a 20–40 ms `adb` process launch.
- **Input over the scrcpy control socket**, with `TCP_NODELAY` and one write per event. That's about 1 ms of local overhead per touch, compared with roughly 300 ms for `adb shell input tap`.
- **Agent screenshots come from the last decoded frame**: a GPU downscale plus JPEG encode, about 10 ms, versus about 500 ms or more for `screencap`.
- **App Nap is disabled** and agent threads run at user-interactive QoS, so gestures keep exact timing while the window is hidden.

## For AI agents

The app serves a local API on a Unix socket (`~/Library/Application Support/AndroidMirroring/agent.sock`, mode 0600). The bundled `droidctl` exposes it as an **MCP server** and as a **CLI**. If the app isn't running, `droidctl` launches it in the background.

**Claude Code**

```bash
claude mcp add android -s user -- "/Applications/Android Mirroring.app/Contents/MacOS/droidctl" mcp
```

**Other MCP clients**

```json
{ "mcpServers": { "android": { "command": "/Applications/Android Mirroring.app/Contents/MacOS/droidctl", "args": ["mcp"] } } }
```

Tools: `screenshot`, `tap`, `double_tap`, `long_press`, `swipe`, `scroll`, `pinch`, `type_text`, `press_key`, `ui_tree`, `tap_element`, `wait_for`, `launch_app`, `list_apps`, `open_url`, `current_app`, `device_info`, `get_clipboard`, `set_clipboard`, `notifications`, `open_notifications`, `unlock`, `screen_power`, `rotate`, `shell`, `install_apk`, `push_file`, `pull_file`, `wait`, `status`, `show_window`.

Coordinates are pixels of the most recent screenshot (long edge 1280 px by default); pass `"space": "device"` or `"normalized"` for other spaces. Agents don't need the window to be visible, and you can keep using the phone while they work. Unlike iPhone Mirroring, the phone doesn't need to be locked.

**CLI**

```bash
droidctl screenshot -o phone.jpg      # 591x1280
droidctl launch WhatsApp
droidctl tap-text "New chat"
droidctl type "hello 👋" && droidctl key enter
droidctl ui                            # on-screen elements with centers
droidctl notifications
droidctl swipe 300 1000 300 300 250
```

Settings › Agents has a copy button for each of these, plus an option to symlink `droidctl` into `/usr/local/bin`.

## Keyboard & mouse

| Input | Action |
|---|---|
| Click / drag | Tap / swipe |
| Two-finger scroll | Finger swipe (with natural fling) |
| Pinch | Pinch zoom |
| Right-click, Esc, ⌘[ | Back |
| Middle-click, ⌘1 | Home |
| ⌘2 | Recent apps |
| ⌘3 / ⌘4 | Notifications / Quick settings |
| ⌘↑ / ⌘↓ | Volume |
| ⌘R / ⌘L | Rotate / Lock |
| ⌥⌘O | Phone screen off (mirroring continues) |
| ⇧⌘S | Screenshot to Desktop (also copied) |
| ⌘0 / ⌘+ / ⌘− | Pixel-exact size / bigger / smaller |
| ⌥⌘T | Keep window on top |
| ⌘-drag, or drag the hover bar | Move the window |

## Project layout

```
Sources/MirrorKit/        core library
  ADB/                    ADB server-protocol client, sockets, sync push/pull
  Scrcpy/                 scrcpy 5.0.1 session + control-message encoder
  Media/                  VideoToolbox decoder, Opus/AAC audio, frame store
  Devices/                DeviceManager: identity, multi-path, standby links, mDNS
  Session/                MirrorController: lifecycle, failover, input & gestures
  Android/                keycodes, UI tree / notifications / app-list queries
  Agent/                  Unix-socket agent API server
Sources/AgentProtocol/    shared tool schemas + socket client
Sources/AndroidMirroring/ the app (AppKit + SwiftUI)
Sources/droidctl/         CLI + MCP stdio server
Sources/mirror-bench/     streaming benchmark (no input injected)
Sources/mirror-selftest/  protocol/unit self-tests (swift run mirror-selftest)
Resources/scrcpy-server   scrcpy v5.0.1 server (Apache-2.0, sha256 764eb6f7…bc536)
```

## Troubleshooting

- **"Unauthorized"**: unlock the phone and accept the debugging prompt. If no prompt appears, open Developer options and revoke USB debugging authorizations, then reconnect.
- **UI tree unavailable**: another automation tool on the phone (Appium, Maestro, agent-device…) is holding the phone's single UiAutomation connection. Screenshots and coordinates still work.
- **No audio**: needs Android 11+, and on some phones the screen must be unlocked when mirroring starts.
- **Using an ADB server on another machine** (phone plugged in elsewhere): tunnel its port 5037 and set Settings › Connection › ADB server, for example `tcp:127.0.0.1:15037`.
- Logs: `~/Library/Logs/AndroidMirroring/mirroring.log`.

## Credits

The on-device video/audio/control server is [scrcpy](https://github.com/Genymobile/scrcpy) by Genymobile (Apache License 2.0, see `Resources/scrcpy-LICENSE`). Everything else (the macOS client, decoder pipeline, connection manager, UI, and agent API) is written for this app.
