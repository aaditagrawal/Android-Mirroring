import Foundation
@testable import MirrorKit
import Testing

struct ProtocolTests {
    @Test func testTouchPacketEncodesCoordinatesAndPressure() {
        let packet = ControlMessage.touch(.down, pointer: PointerID.genericFinger,
                                          at: DevicePoint(x: 100, y: 200), screen: (1080, 2340))
        #expect(packet.count == 32)
        #expect(Array(packet[10..<18]) == [0, 0, 0, 100, 0, 0, 0, 200])
        #expect(Array(packet[18..<22]) == [0x04, 0x38, 0x09, 0x24])
        #expect(Array(packet[22..<24]) == [0xFF, 0xFF])
    }

    @Test func testTextTruncationPreservesUTF8() {
        for value in ["é", "📱", "a📱"] {
            let packet = ControlMessage.text(String(repeating: value, count: 300))
            let length = packet[1..<5].reduce(0) { $0 * 256 + Int($1) }
            #expect(length <= 300)
            #expect(length == packet.count - 5)
            #expect(String(bytes: packet[5...], encoding: .utf8) != nil)
        }
    }

    @Test func testMixedAnnexBStartCodes() {
        let bytes: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9]
        let ranges = bytes.withUnsafeBufferPointer { VideoDecoder.splitNALs($0.baseAddress!, $0.count) }
        #expect(ranges == [4..<7, 10..<12, 16..<19])
    }

    @Test func testDeviceParsingPreservesOfflineEntries() {
        let devices = ADBClient.parseDevices("192.0.2.10:5555 device model:ExamplePhone transport_id:14\nemulator-5554 offline\n")
        #expect(devices.count == 2)
        #expect(devices[0].model == "ExamplePhone")
        #expect(devices[0].isOnline)
        #expect(!devices[1].isOnline)
    }

    @Test func testTransportClassification() {
        #expect(TransportKind.infer(serial: "100.64.0.10:5555", usb: nil) == .tailscale)
        #expect(TransportKind.infer(serial: "192.0.2.10:5555", usb: nil) == .lan)
        #expect(TransportKind.infer(serial: "adb-example._adb-tls-connect._tcp", usb: nil) == .wirelessDebugging)
        #expect(TransportKind.infer(serial: "EXAMPLE", usb: "1-1") == .usb)
    }
}
