# Agent access

The app serves newline-delimited JSON on a Unix socket at
`~/Library/Application Support/AndroidMirroring/agent.sock`. The socket has mode
`0600`. Set `ANDROID_MIRRORING_SOCKET` in both the app and client environments to
use another path; keep the UTF-8 path shorter than 104 bytes.

`droidctl` launches the installed app if needed. The app still needs a paired,
reachable phone. Closing the mirror window keeps the session running by default;
Settings → General can disable that behavior.

## MCP setup

For clients that accept an MCP server JSON configuration:

```json
{
  "mcpServers": {
    "android": {
      "command": "/Applications/Android Mirroring.app/Contents/MacOS/droidctl",
      "args": ["mcp"]
    }
  }
}
```

For Claude Code:

```sh
claude mcp add android -s user -- "/Applications/Android Mirroring.app/Contents/MacOS/droidctl" mcp
```

If installed under `~/Applications`, use that absolute path instead. Settings →
Agents generates snippets for the running app's location. Restart the MCP client
after adding a server.

## Tools and coordinates

Run `droidctl tools` for the current JSON schemas. The catalog lives in
[AgentTools.swift](../Sources/AgentProtocol/AgentTools.swift).

| Group | Tools |
| --- | --- |
| Observe | `screenshot`, `screen_text`, `ui_tree`, `wait_for`, `current_app`, `device_info`, `status` |
| Input | `tap`, `double_tap`, `long_press`, `swipe`, `scroll`, `pinch`, `type_text`, `press_key`, `tap_element`, `batch` |
| Apps | `launch_app`, `list_apps`, `open_url` |
| Phone | `notifications`, `open_notifications`, `get_clipboard`, `set_clipboard`, `unlock`, `screen_power`, `rotate` |
| Files and shell | `install_apk`, `push_file`, `pull_file`, `shell` |
| Session | `wait`, `show_window` |

Coordinates default to pixels in the most recent screenshot, whose long edge
is 1280 pixels by default. Pass `space: "device"` for video-frame pixels or
`space: "normalized"` for fractions from 0 to 1. If several clients request
different screenshot sizes, use an explicit coordinate space to avoid ambiguity.

MCP actions return a screenshot by default. `screenshot: false` skips it;
`settle: true` still waits for visible changes to finish. Raw API and CLI calls
do not add screenshots to actions unless requested. A `still_changing` response
means the settling deadline expired, so the returned image may be mid-animation.

`tap_element` searches local Vision OCR first, then Android's UI tree for content
descriptions and resource IDs. Other automation tools can occupy Android's single
UiAutomation connection; screenshots and OCR continue working in that case.

## CLI examples

Use the bundled full path, or install the optional symlink from Settings.

```sh
droidctl screenshot --png -o phone.png
droidctl screenshot --max 0 -o full-resolution.jpg
droidctl launch com.android.settings
droidctl text
droidctl tap-text "Display"
droidctl swipe 300 1000 300 300 250
droidctl type "hello"
droidctl key enter
droidctl ui
droidctl batch '[{"tool":"tap_element","query":"Search"},{"tool":"type_text","text":"display","submit":true}]'
droidctl call tap '{"x":0.5,"y":0.5,"space":"normalized","screenshot":false}'
```

Agents can execute shell commands and access phone data with ADB's privileges.
Read [SECURITY.md](../SECURITY.md) and coordinate with other users of the phone
before running tasks. Hidden `debug_*` calls are development hooks, not stable
MCP tools.
