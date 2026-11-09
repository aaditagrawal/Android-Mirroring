# Security

Android Mirroring runs ADB commands with the authority granted by the paired
phone. Only connect trusted phones and authorize trusted Macs.

The agent API is a local Unix socket with mode `0600`. Every process running as
your macOS user can potentially call it. MCP tools include shell commands, APK
installation, file transfers, clipboard access, and phone unlocking. Connect only
agent clients you trust. There is no per-tool permission prompt or sandbox.

The optional unlock PIN is stored in macOS Keychain. Clipboard sharing and
notification forwarding copy phone data onto the Mac and can be disabled in
Settings. Logs may contain device names, addresses, package names, and error text.

The direct TCP relay authenticates with a random per-session token supplied over
ADB. The relay itself does **not encrypt** video, audio, or control data. Use it on
a trusted LAN or through Tailscale. Pairing via Wireless debugging does not add
TLS to the separate relay connection. The core library can force media through
ADB with `StreamOptions.transport = .adb`.

Keep the ADB server on loopback. For a phone attached to another computer, tunnel
the server over SSH rather than exposing port 5037 to a network. Never commit ADB
keys, phone PINs, signing credentials, or recordings of private phone content.

For a vulnerability, contact the maintainer privately through the repository
owner's profile, or use GitHub private vulnerability reporting when enabled.
Do not include private data or exploitable details in a public bug report.
