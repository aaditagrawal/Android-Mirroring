# Connections and troubleshooting

## USB and wireless pairing

For USB, enable USB debugging and accept the phone's authorization dialog.
Use a cable that carries data. An `unauthorized` device cannot be mirrored until
the phone accepts the Mac's ADB key.

For Android 11 or later, enable Wireless debugging in Developer options.
Phones → QR Code advertises a pairing service. Scan it using **Pair device with
QR code** on the phone. Pairing by code uses the address, port, and six-digit code
in **Pair device with pairing code**. After pairing, use the connection endpoint
from the main Wireless debugging screen. That port may differ from the pairing
port and can change when wireless debugging restarts.

The app discovers ADB services with Bonjour and remembers successful endpoints.
If discovery fails, enter the connection address manually. The Mac may need
Local Network access in System Settings.

Older phones can use USB first, then `adb -s DEVICE_SERIAL tcpip 5555`, followed
by a connection to `PHONE_IP:5555`. This enables a network debugging endpoint.
Use a trusted network and disable it when no longer needed. Android vendor
behavior and access policies vary.

## Tailscale and path switching

Install and authorize Tailscale on both devices, then connect to the phone's
Tailscale address and a reachable ADB port. Tailscale does not enable ADB itself.
The tailnet's access policy must allow the connection. Some phones stop wireless
debugging when Wi-Fi disconnects, so availability over cellular is device-specific.

The app groups paths by phone identity and prefers healthy USB or lower-cost
network paths. It probes active paths and restarts the stream when switching;
there can be a visible interruption. Settings → General controls automatic
switching and backup connections. Shared remote ADB servers leave backup-link
creation off by default.

Automatic quality uses native resolution at 20 Mbps on USB, native at 16 Mbps
on a fast network, and a 1600-pixel long edge at 6 Mbps on slow paths. Actual rate
depends on screen activity and the encoder. Phone refresh rate, Wi-Fi contention,
and power-saving settings affect latency and motion.

## A phone attached to another computer

Keep the remote ADB server on loopback and tunnel it. For example:

```sh
ssh -N -L 15037:127.0.0.1:5037 your-adb-host
```

Set Settings → General → Advanced → ADB server to `tcp:127.0.0.1:15037` and
relaunch. An `ADB_SERVER_SOCKET` environment variable also works when no saved
setting overrides it. Do not expose the remote server on a public interface.

## Common problems

| Symptom | Check |
| --- | --- |
| No phone listed | Run `adb devices -l`; check the cable, connection port, and network route. |
| Unauthorized | Unlock Android and accept its debugging prompt. Revoke and reauthorize debugging keys only if the prompt is stuck. |
| No audio | Audio forwarding requires Android 11+. Start with the phone unlocked; apps may block audio capture. |
| Black content | Android apps can protect video or sensitive windows from capture. |
| UI tree fails | Another automation service may hold UiAutomation. Try OCR or coordinates instead. |
| HEVC fails | Try H.264 under Picture → Advanced. |
| Old remote server selected | Clear General → Advanced → ADB server and relaunch. |
| Agent cannot connect | Confirm the app is running, the phone is connected, and client/app socket overrides match. |

Logs are under `~/Library/Logs/AndroidMirroring/mirroring.log`. Redact addresses,
serials, app names, messages, and other private details before sharing logs.
