import AgentProtocol
import Darwin
import Foundation
@testable import MirrorKit
import Testing

@Suite(.serialized)
@MainActor
struct AgentTests {
    private func server(path: String) -> AgentServer {
        AgentServer(controller: MirrorController(devices: DeviceManager()), path: path)
    }

    @Test func testToolCatalogHasUniqueNamesAndValidSchemas() throws {
        let names = AgentTools.all.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in AgentTools.all {
            #expect(JSONSerialization.isValidJSONObject(tool.schema))
            let properties = try #require(tool.schema["properties"] as? [String: Any])
            for required in tool.schema["required"] as? [String] ?? [] {
                #expect(properties[required] != nil)
            }
            if tool.isAction {
                #expect(properties["screenshot"] != nil)
                #expect(properties["settle"] != nil)
            }
        }
        #expect(AgentTools.actionNames.isSubset(of: Set(names)))
        #expect(AgentServer.actions == AgentTools.actionNames)
    }

    @Test func testSocketRoundTripPermissionsAndReconnect() throws {
        let path = "/tmp/am-test-\(UUID().uuidString).sock"
        let server = server(path: path)
        try server.start()
        defer { server.stop() }
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let client = AgentClient()
        try client.connect(path: path)
        for _ in 0..<3 {
            #expect(try client.call("wait", ["ms": 0])["ok"] as? Bool == true)
        }
        try client.connect(path: path)
        #expect(try client.call("wait", ["ms": 0])["ok"] as? Bool == true)
        #expect(throws: (any Error).self) { try server.start() }
    }

    @Test func testSocketPathsRejectTruncationAndEmbeddedNUL() {
        for path in [String(repeating: "x", count: 104), "/tmp/invalid\0suffix"] {
            #expect(throws: (any Error).self) { try server(path: path).start() }
            #expect(throws: (any Error).self) { try AgentClient().connect(path: path) }
        }
    }

    @Test func testNegativeTextMatchIndexFailsBeforeAccessingPhone() {
        do {
            _ = try server(path: "/tmp/unused.sock").handleObservation(
                "tap_element", ["query": "Settings", "index": -1]
            )
            Issue.record("Expected a negative index error")
        } catch {
            #expect(String(describing: error).contains("index must be nonnegative"))
        }
    }
}
