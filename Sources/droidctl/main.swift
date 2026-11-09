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
if cmd == "-h" || cmd == "--help" || cmd == "help" { usage(exitCode: 0) }

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
            case "-o":
                guard i + 1 < args.count else { usage() }
                i += 1; out = args[i]
            case "--max":
                guard i + 1 < args.count, let value = Int(args[i + 1]), value >= 0 else { usage() }
                i += 1; maxDim = value
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
    case "text":
        let r = try run("screen_text", args.isEmpty ? [:] : ["query": args.joined(separator: " ")])
        for e in (r["lines"] ?? r["matches"]) as? [[String: Any]] ?? [] {
            let c = e["center"] as? [Int] ?? []
            print(String(format: "%5d,%-5d  ", c.first ?? 0, c.last ?? 0) + (e["text"] as? String ?? ""))
        }
    case "batch":
        guard let j = args.first, let data = j.data(using: .utf8),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { usage() }
        printResult(try run("batch", ["actions": steps]))
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
