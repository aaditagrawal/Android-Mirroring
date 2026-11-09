import Foundation

func check(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "CLI smoke check", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func run(_ executable: String, _ arguments: [String], input: String = "") throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.standardError
    try process.run()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

let executable = CommandLine.arguments[1]
let (helpStatus, help) = try run(executable, ["--help"])
try check(helpStatus == 0 && help.contains("screenshot"), "CLI help failed")
let (toolsStatus, toolsJSON) = try run(executable, ["tools"])
let tools = try JSONSerialization.jsonObject(with: Data(toolsJSON.utf8)) as! [[String: Any]]
try check(toolsStatus == 0 && !tools.isEmpty, "CLI tool catalog is empty")
let requests = """
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"ping"}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"missing_tool","arguments":{}}}
{"jsonrpc":"2.0","id":5,"method":"missing_method"}

"""
let (mcpStatus, output) = try run(executable, ["mcp"], input: requests)
let replies = try output.split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
}
try check(mcpStatus == 0 && replies.count == 5, "MCP framing or notification handling failed")
try check(replies.map { $0["id"] as? Int } == [1, 2, 3, 4, 5], "MCP response IDs changed")
let initialization = replies[0]["result"] as? [String: Any]
try check(initialization?["protocolVersion"] as? String == "2025-06-18", "MCP initialization failed")
let listed = (replies[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]]
try check(listed?.compactMap { $0["name"] as? String } == tools.compactMap { $0["name"] as? String }, "CLI and MCP tools diverged")
try check((replies[3]["result"] as? [String: Any])?["isError"] as? Bool == true, "Unknown tool did not fail")
try check((replies[4]["error"] as? [String: Any])?["code"] as? Int == -32601, "Unknown method did not fail")
print("CLI and MCP checks passed (\(tools.count) tools; no phone used)")
