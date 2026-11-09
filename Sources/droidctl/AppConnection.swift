import AgentProtocol
import Foundation

/// Connect to the app, launching it in the background if needed.
func connectClient() throws -> AgentClient {
    let c = AgentClient()
    do {
        try c.connect()
        return c
    } catch AgentError.notRunning {
        launchApp()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if (try? c.connect()) != nil { return c }
        }
        throw AgentError.message("Android Mirroring did not start (is it installed in /Applications?)")
    }
}

func launchApp() {
    // Prefer the app bundle that contains this binary, then the installed app.
    var candidates: [String] = []
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app" { candidates.append(bundle.path) }
    candidates += ["/Applications/Android Mirroring.app", NSHomeDirectory() + "/Applications/Android Mirroring.app"]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        p.arguments = ["-g", path]
    } else {
        p.arguments = ["-g", "-b", AgentAPI.bundleIdentifier]
    }
    try? p.run()
    p.waitUntilExit()
}

func jsonString(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
          let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "\(obj)" }
    return String(decoding: d, as: UTF8.self)
}
