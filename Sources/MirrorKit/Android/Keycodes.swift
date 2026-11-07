import Foundation

/// The subset of android.view.KeyEvent keycodes this app uses.
public enum AKey {
    public static let home: Int32 = 3
    public static let back: Int32 = 4
    public static let call: Int32 = 5
    public static let endCall: Int32 = 6
    public static let dpadUp: Int32 = 19
    public static let dpadDown: Int32 = 20
    public static let dpadLeft: Int32 = 21
    public static let dpadRight: Int32 = 22
    public static let dpadCenter: Int32 = 23
    public static let volumeUp: Int32 = 24
    public static let volumeDown: Int32 = 25
    public static let power: Int32 = 26
    public static let camera: Int32 = 27
    public static let tab: Int32 = 61
    public static let space: Int32 = 62
    public static let enter: Int32 = 66
    public static let del: Int32 = 67          // backspace
    public static let menu: Int32 = 82
    public static let search: Int32 = 84
    public static let mediaPlayPause: Int32 = 85
    public static let mediaNext: Int32 = 87
    public static let mediaPrevious: Int32 = 88
    public static let pageUp: Int32 = 92
    public static let pageDown: Int32 = 93
    public static let escape: Int32 = 111
    public static let forwardDel: Int32 = 112
    public static let moveHome: Int32 = 122
    public static let moveEnd: Int32 = 123
    public static let volumeMute: Int32 = 164
    public static let appSwitch: Int32 = 187
    public static let brightnessDown: Int32 = 220
    public static let brightnessUp: Int32 = 221
    public static let sleep: Int32 = 223
    public static let wakeup: Int32 = 224
    public static let assist: Int32 = 219
    public static let voiceAssist: Int32 = 231
    public static let allApps: Int32 = 284
    public static let notification: Int32 = 83
    public static let a: Int32 = 29
    public static let c: Int32 = 31
    public static let v: Int32 = 50
    public static let x: Int32 = 52
    public static let z: Int32 = 54

    // Meta state flags
    public static let metaShiftOn: Int32 = 0x1
    public static let metaAltOn: Int32 = 0x2
    public static let metaCtrlOn: Int32 = 0x1000
    public static let metaCtrlLeftOn: Int32 = 0x2000
    public static let metaMetaOn: Int32 = 0x10000

    /// Named keys accepted by the agent API / CLI.
    public static let named: [String: Int32] = [
        "home": home, "back": back, "recents": appSwitch, "app_switch": appSwitch, "overview": appSwitch,
        "enter": enter, "return": enter, "delete": del, "backspace": del, "forward_delete": forwardDel,
        "tab": tab, "space": space, "escape": escape, "esc": escape,
        "up": dpadUp, "down": dpadDown, "left": dpadLeft, "right": dpadRight, "center": dpadCenter,
        "volume_up": volumeUp, "volume_down": volumeDown, "mute": volumeMute, "power": power,
        "menu": menu, "search": search, "camera": camera, "play_pause": mediaPlayPause,
        "next": mediaNext, "previous": mediaPrevious, "page_up": pageUp, "page_down": pageDown,
        "move_home": moveHome, "move_end": moveEnd, "wakeup": wakeup, "sleep": sleep,
        "assist": assist, "all_apps": allApps, "notifications": notification,
        "brightness_up": brightnessUp, "brightness_down": brightnessDown, "call": call, "end_call": endCall,
    ]
}
