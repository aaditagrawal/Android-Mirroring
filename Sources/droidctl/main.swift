import AgentProtocol
import Foundation

// droidctl — command-line and MCP access to the phone mirrored by Android Mirroring.
//
//   droidctl mcp                      run as an MCP server (stdio)
//   droidctl status | info
//   droidctl screenshot [-o out.jpg] [--max 1280] [--png]
//   droidctl tap X Y | swipe X1 Y1 X2 Y2 [MS] | type TEXT | key NAME
//   droidctl ui [FILTER] | tap-text QUERY | launch APP | apps [FILTER]
//   droidctl call METHOD '{"json":"params"}'

setvbuf(stdout, nil, _IOLBF, 0)

func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

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

// MARK: - MCP server

final class MCPServer {
    var client: AgentClient?

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            if id == nil { continue } // notification (e.g. notifications/initialized)
            let response: [String: Any]
            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String ?? "2025-06-18"
                response = result(id, [
                    "protocolVersion": requested,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "android-mirroring", "version": "1.0.0"],
                    "instructions": """
                    Controls the user's Android phone through Android Mirroring (live, low-latency).
                    Typical loop: screenshot → decide → tap/swipe/type_text/press_key → screenshot.
                    Coordinates are pixels in the most recent screenshot. ui_tree gives exact element bounds and \
                    tap_element taps by visible text. launch_app opens apps by name. The phone does not need to be \
                    locked or idle; the user may be watching the mirror window.
                    """,
                ])
            case "ping":
                response = result(id, [:])
            case "tools/list":
                let tools = AgentTools.all.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] as [String: Any] }
                response = result(id, ["tools": tools])
            case "tools/call":
                response = result(id, callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
            default:
                response = ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "method not found: \(method)"]]
            }
            send(response)
        }
    }

    private func result(_ id: Any?, _ r: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": r] }

    private func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }

    private func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        guard AgentTools.named(name) != nil else {
            return ["content": [["type": "text", "text": "Unknown tool \(name)"]], "isError": true]
        }
        do {
            let r = try call(name, args)
            if name == "screenshot", let img = r["image"] as? String {
                let w = r["width"] as? Int ?? 0, h = r["height"] as? Int ?? 0
                return ["content": [
                    ["type": "image", "data": img, "mimeType": r["mime"] as? String ?? "image/jpeg"],
                    ["type": "text", "text": "Screenshot \(w)x\(h) px (tap coordinates use this grid)."],
                ]]
            }
            if let out = r["output"] as? String, r.count == 1 {
                return ["content": [["type": "text", "text": out]]]
            }
            if r.count == 1, r["ok"] as? Bool == true {
                return ["content": [["type": "text", "text": "ok"]]]
            }
            return ["content": [["type": "text", "text": jsonString(r)]]]
        } catch {
            return ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true]
        }
    }

    /// Calls the app, reconnecting once if the app restarted.
    private func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        if client == nil { client = try connectClient() }
        do {
            return try client!.call(method, params)
        } catch AgentError.message(let m) where m.contains("connection closed") || m.contains("write failed") {
            client = try connectClient()
            return try client!.call(method, params)
        }
    }
}

// MARK: - CLI

func usage() -> Never {
    print("""
    droidctl — control the phone mirrored by Android Mirroring

    MCP:
      droidctl mcp                          Run as an MCP server over stdio

    Commands:
      status                                Connection status
      info                                  Device, battery, stream details
      screenshot [-o FILE] [--max N] [--png]  Save a screenshot (default ./screenshot.jpg)
      tap X Y                               Tap (screenshot pixel coordinates)
      double-tap X Y
      long-press X Y [MS]
      swipe X1 Y1 X2 Y2 [MS]
      scroll DY [X Y]                       Mouse-wheel scroll (positive = down)
      type TEXT...                          Type text (any Unicode)
      key NAME [--long]                     home back recents enter delete tab volume_up power …
      ui [FILTER]                           List on-screen elements with bounds
      tap-text QUERY                        Tap the element matching text / id / description
      wait-for QUERY [TIMEOUT_MS]           Wait for an element to appear
      launch APP                            Launch by package or label
      apps [FILTER]                         List apps
      open URL                              Open a URL / deep link
      current                               Foreground app
      notifications                         Current notifications
      clipboard [TEXT]                      Read, or set, the phone clipboard
      unlock                                Wake + unlock with the saved PIN
      screen on|off                         Phone display power (mirroring continues)
      shell CMD...                          adb shell
      install APK                           Install an APK
      push FILE [REMOTE]                    Copy a file to the phone
      pull REMOTE [LOCAL]                   Copy a file from the phone
      show | hide                           Show/hide the mirror window
      call METHOD [JSON]                    Raw API call
      tools                                 List API tools (JSON)

    Coordinates refer to the last screenshot (long edge \(AgentAPI.defaultMaxDimension) px by default).
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()

if cmd == "mcp" {
    MCPServer().run()
    exit(0)
}
if cmd == "tools" {
    print(jsonString(AgentTools.all.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }))
    exit(0)
}
if cmd == "-h" || cmd == "--help" || cmd == "help" { usage() }

func d(_ s: String) -> Double {
    guard let v = Double(s) else { eprint("not a number: \(s)"); exit(2) }
    return v
}

do {
    let client = try connectClient()
    func run(_ m: String, _ p: [String: Any] = [:]) throws -> [String: Any] { try client.call(m, p) }
    func printResult(_ r: [String: Any]) {
        if r.count == 1, r["ok"] as? Bool == true { return }
        print(jsonString(r))
    }

    switch cmd {
    case "status": printResult(try run("status"))
    case "info": printResult(try run("device_info"))
    case "screenshot":
        var out = "screenshot.jpg", maxDim = AgentAPI.defaultMaxDimension, png = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-o": i += 1; out = args[i]
            case "--max": i += 1; maxDim = Int(args[i]) ?? maxDim
            case "--png": png = true
            default: out = args[i]
            }
            i += 1
        }
        if out.hasSuffix(".png") { png = true }
        let r = try run("screenshot", ["max_dimension": maxDim, "format": png ? "png" : "jpeg"])
        guard let b64 = r["image"] as? String, let data = Data(base64Encoded: b64) else { throw AgentError.message("no image") }
        try data.write(to: URL(fileURLWithPath: out))
        print("\(out) \(r["width"] ?? 0)x\(r["height"] ?? 0)")
    case "tap":
        guard args.count >= 2 else { usage() }
        printResult(try run("tap", ["x": d(args[0]), "y": d(args[1])]))
    case "double-tap":
        guard args.count >= 2 else { usage() }
        printResult(try run("double_tap", ["x": d(args[0]), "y": d(args[1])]))
    case "long-press":
        guard args.count >= 2 else { usage() }
        printResult(try run("long_press", ["x": d(args[0]), "y": d(args[1]), "duration_ms": args.count > 2 ? d(args[2]) : 600]))
    case "swipe":
        guard args.count >= 4 else { usage() }
        printResult(try run("swipe", ["x1": d(args[0]), "y1": d(args[1]), "x2": d(args[2]), "y2": d(args[3]),
                                      "duration_ms": args.count > 4 ? d(args[4]) : 300]))
    case "scroll":
        guard args.count >= 1 else { usage() }
        var p: [String: Any] = ["dy": d(args[0])]
        if args.count >= 3 { p["x"] = d(args[1]); p["y"] = d(args[2]) }
        printResult(try run("scroll", p))
    case "type":
        printResult(try run("type_text", ["text": args.joined(separator: " ")]))
    case "key":
        guard let k = args.first else { usage() }
        printResult(try run("press_key", ["key": k, "long_press": args.contains("--long")]))
    case "ui":
        var p: [String: Any] = [:]
        if let f = args.first { p["filter"] = f }
        let r = try run("ui_tree", p)
        for e in r["elements"] as? [[String: Any]] ?? [] {
            let label = (e["text"] as? String) ?? (e["desc"] as? String) ?? (e["id"] as? String) ?? ""
            let c = e["center"] as? [Int] ?? []
            var flags: [String] = []
            for f in ["clickable", "editable", "scrollable", "focused", "selected"] where e[f] as? Bool == true { flags.append(f) }
            if let ch = e["checked"] as? Bool { flags.append(ch ? "checked" : "unchecked") }
            print(String(format: "%5d,%-5d  %@  [%@] %@", c.first ?? 0, c.last ?? 0, (e["class"] as? String ?? "").padding(toLength: 18, withPad: " ", startingAt: 0), flags.joined(separator: ","), label))
        }
    case "tap-text":
        guard !args.isEmpty else { usage() }
        printResult(try run("tap_element", ["query": args.joined(separator: " ")]))
    case "wait-for":
        guard let q = args.first else { usage() }
        printResult(try run("wait_for", ["query": q, "timeout_ms": args.count > 1 ? d(args[1]) : 10000]))
    case "launch":
        printResult(try run("launch_app", ["app": args.joined(separator: " ")]))
    case "apps":
        let r = try run("list_apps", args.isEmpty ? [:] : ["filter": args.joined(separator: " ")])
        for a in r["apps"] as? [[String: Any]] ?? [] {
            print("\((a["label"] as? String ?? "").padding(toLength: 32, withPad: " ", startingAt: 0)) \(a["package"] ?? "")")
        }
    case "open":
        guard let u = args.first else { usage() }
        printResult(try run("open_url", ["url": u]))
    case "current": printResult(try run("current_app"))
    case "notifications":
        let r = try run("notifications")
        for n in r["notifications"] as? [[String: Any]] ?? [] {
            print("[\(n["app"] ?? "")] \(n["title"] ?? "") — \(n["text"] ?? "")")
        }
    case "clipboard":
        if args.isEmpty { print((try run("get_clipboard"))["text"] as? String ?? "") }
        else { printResult(try run("set_clipboard", ["text": args.joined(separator: " ")])) }
    case "unlock": printResult(try run("unlock"))
    case "screen":
        printResult(try run("screen_power", ["on": args.first != "off"]))
    case "shell":
        print((try run("shell", ["command": args.joined(separator: " ")]))["output"] as? String ?? "", terminator: "")
    case "install":
        guard let pth = args.first else { usage() }
        printResult(try run("install_apk", ["path": (pth as NSString).expandingTildeInPath]))
    case "push":
        guard let pth = args.first else { usage() }
        var p: [String: Any] = ["path": (pth as NSString).expandingTildeInPath]
        if args.count > 1 { p["remote_path"] = args[1] }
        printResult(try run("push_file", p))
    case "pull":
        guard let r = args.first else { usage() }
        var p: [String: Any] = ["remote_path": r]
        if args.count > 1 { p["path"] = args[1] }
        printResult(try run("pull_file", p))
    case "show": printResult(try run("show_window", ["visible": true]))
    case "hide": printResult(try run("show_window", ["visible": false]))
    case "call":
        guard let m = args.first else { usage() }
        var p: [String: Any] = [:]
        if args.count > 1, let data = args[1].data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { p = obj }
        let r = try run(m, p)
        if var r2 = Optional(r), r2["image"] != nil { r2["image"] = "<\((r["image"] as? String)?.count ?? 0) base64 chars>"; print(jsonString(r2)) }
        else { print(jsonString(r)) }
    default:
        usage()
    }
} catch {
    eprint("droidctl: \(error)")
    exit(1)
}
