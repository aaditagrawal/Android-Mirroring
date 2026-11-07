import Foundation

/// Android MotionEvent actions.
public enum MotionAction: UInt8 {
    case down = 0, up = 1, move = 2, cancel = 3, pointerDown = 5, pointerUp = 6, hoverMove = 7
}

/// Android KeyEvent actions.
public enum KeyAction: UInt8 { case down = 0, up = 1 }

/// Pointer ids understood specially by the scrcpy server.
public enum PointerID {
    public static let mouse: UInt64 = UInt64(bitPattern: -1)
    public static let genericFinger: UInt64 = UInt64(bitPattern: -2)
    public static let virtualFinger: UInt64 = UInt64(bitPattern: -3)
}

public struct DevicePoint: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
    public init(x: Int32, y: Int32) { self.x = x; self.y = y }
    public init(_ x: Double, _ y: Double) { self.x = Int32(x.rounded()); self.y = Int32(y.rounded()) }
}

/// Serializer for scrcpy 5.x control messages (client → device). Wire format mirrors
/// app/src/control_msg.c in scrcpy v5.0.1.
public enum ControlMessage {
    public static let injectTextMaxLength = 300
    public static let clipboardMaxLength = (1 << 18) - 14

    enum T: UInt8 {
        case injectKeycode = 0, injectText = 1, injectTouch = 2, injectScroll = 3, backOrScreenOn = 4
        case expandNotificationPanel = 5, expandSettingsPanel = 6, collapsePanels = 7
        case getClipboard = 8, setClipboard = 9, setDisplayPower = 10, rotateDevice = 11
        case openHardKeyboardSettings = 15, startApp = 16, resetVideo = 17
        case resizeDisplay = 21, scanFile = 22
    }

    static func position(_ buf: inout [UInt8], _ p: DevicePoint, _ w: UInt16, _ h: UInt16) {
        buf.appendBE(p.x); buf.appendBE(p.y); buf.appendBE(w); buf.appendBE(h)
    }

    static func u16fp(_ f: Float) -> UInt16 {
        let v = UInt32(max(0, min(1, f)) * 65536)
        return UInt16(min(v, 0xFFFF))
    }

    static func i16fp(_ f: Float) -> Int16 {
        let c = max(-1, min(1, f))
        let v = Int32(c * 32768)
        return Int16(max(-0x8000, min(0x7FFF, v)))
    }

    public static func keycode(_ action: KeyAction, _ keycode: Int32, repeatCount: Int32 = 0, meta: Int32 = 0) -> [UInt8] {
        var b: [UInt8] = [T.injectKeycode.rawValue, action.rawValue]
        b.appendBE(keycode); b.appendBE(repeatCount); b.appendBE(meta)
        return b
    }

    /// Text is truncated at a UTF-8 boundary to the server's limit.
    public static func text(_ s: String) -> [UInt8] {
        let bytes = utf8Truncated(s, max: injectTextMaxLength)
        var b: [UInt8] = [T.injectText.rawValue]
        b.appendBE(UInt32(bytes.count)); b += bytes
        return b
    }

    public static func touch(_ action: MotionAction, pointer: UInt64, at p: DevicePoint, screen: (UInt16, UInt16),
                             pressure: Float = 1, actionButton: Int32 = 0, buttons: Int32 = 0) -> [UInt8] {
        var b: [UInt8] = [T.injectTouch.rawValue, action.rawValue]
        b.appendBE(pointer)
        position(&b, p, screen.0, screen.1)
        b.appendBE(u16fp(action == .up ? 0 : pressure))
        b.appendBE(actionButton); b.appendBE(buttons)
        return b
    }

    /// hscroll/vscroll in [-16, 16].
    public static func scroll(at p: DevicePoint, screen: (UInt16, UInt16), h: Float, v: Float, buttons: Int32 = 0) -> [UInt8] {
        var b: [UInt8] = [T.injectScroll.rawValue]
        position(&b, p, screen.0, screen.1)
        b.appendBE(i16fp(h / 16)); b.appendBE(i16fp(v / 16)); b.appendBE(buttons)
        return b
    }

    public static func backOrScreenOn(_ action: KeyAction) -> [UInt8] { [T.backOrScreenOn.rawValue, action.rawValue] }
    public static func expandNotifications() -> [UInt8] { [T.expandNotificationPanel.rawValue] }
    public static func expandSettings() -> [UInt8] { [T.expandSettingsPanel.rawValue] }
    public static func collapsePanels() -> [UInt8] { [T.collapsePanels.rawValue] }
    public static func rotateDevice() -> [UInt8] { [T.rotateDevice.rawValue] }
    public static func resetVideo() -> [UInt8] { [T.resetVideo.rawValue] }

    /// copyKey: 0 none, 1 copy, 2 cut — injected before reading the clipboard.
    public static func getClipboard(copyKey: UInt8 = 0) -> [UInt8] { [T.getClipboard.rawValue, copyKey] }

    public static func setClipboard(sequence: UInt64, text: String, paste: Bool) -> [UInt8] {
        let bytes = utf8Truncated(text, max: clipboardMaxLength)
        var b: [UInt8] = [T.setClipboard.rawValue]
        b.appendBE(sequence); b.append(paste ? 1 : 0)
        b.appendBE(UInt32(bytes.count)); b += bytes
        return b
    }

    public static func setDisplayPower(_ on: Bool) -> [UInt8] { [T.setDisplayPower.rawValue, on ? 1 : 0] }

    /// name: package name, "?label" to search by app label, "+" prefix to force-stop first.
    public static func startApp(_ name: String) -> [UInt8] {
        let bytes = utf8Truncated(name, max: 255)
        return [T.startApp.rawValue, UInt8(bytes.count)] + bytes
    }

    public static func scanFile(_ path: String) -> [UInt8] {
        let bytes = utf8Truncated(path, max: 4096)
        var b: [UInt8] = [T.scanFile.rawValue]
        b.appendBE(UInt32(bytes.count)); b += bytes
        return b
    }

    static func utf8Truncated(_ s: String, max: Int) -> [UInt8] {
        var bytes = Array(s.utf8)
        if bytes.count <= max { return bytes }
        var end = max
        // back off continuation bytes (10xxxxxx)
        while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        bytes.removeSubrange(end...)
        return bytes
    }
}

/// Messages from the device on the control socket.
public enum DeviceMessage {
    case clipboard(String)
    case ackClipboard(UInt64)
    case uhidOutput(id: UInt16, data: Data)
}
