import Foundation

/// User-tunable settings (backed by UserDefaults so the Settings UI binds directly).
public struct MirrorSettings {
    static var d: UserDefaults { .standard }
    public static var quality: String { d.string(forKey: "quality") ?? "auto" }      // auto | high | balanced | data
    public static var codec: String { d.string(forKey: "codec") ?? "h265" }
    /// Display pacing: smooth (absorbs ~98% of network jitter), balanced (~95%), or immediate.
    public static var pacing: Pacing { d.string(forKey: "pacing").flatMap(Pacing.init(rawValue:)) ?? .smooth }
    /// Media transport while on USB: "adb" (default) or "direct" (experiment: Wi-Fi relay even when wired).
    public static var usbTransport: String { d.string(forKey: "usbTransport") ?? "adb" }
    /// 0 = automatic: the phone's native rate (up to 120 Hz) on fast paths, 60 on slow ones.
    public static var maxFps: Int { d.object(forKey: "maxFps") as? Int ?? 0 }
    public static var audio: Bool { d.object(forKey: "audio") as? Bool ?? true }
    public static var clipboardSync: Bool { d.object(forKey: "clipboardSync") as? Bool ?? true }
    public static var screenOffWhileMirroring: Bool { d.object(forKey: "screenOff") as? Bool ?? false }
    public static var stayAwake: Bool { d.object(forKey: "stayAwake") as? Bool ?? false }
    public static var showTouches: Bool { d.object(forKey: "showTouches") as? Bool ?? false }
    public static var autoSwitchPaths: Bool { d.object(forKey: "autoSwitchPaths") as? Bool ?? true }
    public static var lockPhoneOnDisconnect: Bool { d.object(forKey: "lockOnDisconnect") as? Bool ?? false }
}
