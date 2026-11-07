import Foundation
import MirrorKit

var failures = 0
func expect(_ ok: Bool, _ line: Int = #line) { if !ok { failures += 1; print("FAIL line \(line)") } }

enum Tests {
    static func touchLayout() {
        let b = ControlMessage.touch(.down, pointer: PointerID.genericFinger, at: DevicePoint(x: 100, y: 200), screen: (1080, 2340))
        expect(b.count == 32)
        expect(b[0] == 2)
        expect(b[1] == 0)
        expect(Array(b[2..<10]) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
        expect(Array(b[10..<14]) == [0, 0, 0, 100])
        expect(Array(b[18..<20]) == [0x04, 0x38])
        expect(Array(b[22..<24]) == [0xFF, 0xFF])
    }

    static func scrollLayout() {
        let b = ControlMessage.scroll(at: DevicePoint(x: 1, y: 2), screen: (10, 20), h: 16, v: -16)
        expect(b.count == 21)
        expect(Array(b[13..<15]) == [0x7F, 0xFF])
        expect(Array(b[15..<17]) == [0x80, 0x00])
    }

    static func keycodeLayout() {
        expect(ControlMessage.keycode(.up, AKey.home) == [0, 1, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    static func utf8Truncation() {
        let b = ControlMessage.text(String(repeating: "é", count: 200)) // 400 bytes
        let len = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
        expect(len == 300)
        expect(String(bytes: b[5...], encoding: .utf8) != nil)
    }

    static func nalSplit() {
        let data: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9]
        let r = data.withUnsafeBufferPointer { VideoDecoder.splitNALs($0.baseAddress!, $0.count) }
        expect(r == [4..<7, 10..<12, 16..<19])
    }

    static func transportKind() {
        expect(TransportKind.infer(serial: "100.64.0.10:5555", usb: nil) == .tailscale)
        expect(TransportKind.infer(serial: "192.168.1.4:5555", usb: nil) == .lan)
        expect(TransportKind.infer(serial: "adb-R5CX-abc._adb-tls-connect._tcp", usb: nil) == .wirelessDebugging)
        expect(TransportKind.infer(serial: "R5CX123", usb: "1-1") == .usb)
    }

    static func devicesParsing() {
        let text = "100.64.0.10:5555      device product:pa3qxins model:SM_S938B device:pa3q transport_id:14\nemulator-5554 offline\n"
        let d = ADBClient.parseDevices(text)
        expect(d.count == 2)
        expect(d[0].model == "SM_S938B")
        expect(d[0].isOnline)
        expect(!d[1].isOnline)
    }
}

let all: [(String, () -> Void)] = [("touch", Tests.touchLayout), ("scroll", Tests.scrollLayout), ("keycode", Tests.keycodeLayout),
    ("utf8", Tests.utf8Truncation), ("nal", Tests.nalSplit), ("transport", Tests.transportKind), ("devices", Tests.devicesParsing)]
for (name, f) in all { f(); print("ran \(name)") }
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
