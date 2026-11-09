import AgentProtocol
import CoreGraphics
import Foundation

extension AgentServer {
    func handleObservation(_ method: String, _ p: [String: Any]) throws -> [String: Any] {
        let c = controller
        switch method {
        case "screenshot":
            var r: [String: Any] = [:]
            if p["wait_for_idle"] as? Bool ?? true {
                let st = c.frames.waitForSettle(quiet: 0.15, timeout: 1.5)
                r["settle_ms"] = st.ms
                if !st.settled { r["still_changing"] = true }
            }
            return r.merging(try captureScreenshot(p), uniquingKeysWith: { _, b in b })

        case "screen_text":
            let lines = try recognizeText()
            let dev = try deviceSize()
            if let q = p["query"] as? String, !q.isEmpty {
                let matches = TextRecognizer.find(q, in: lines.texts)
                return ["matches": try matches.map { m in try textEntry(m.line.text, m.box, lines.scale, dev, p) }, "count": matches.count]
            }
            return ["lines": try lines.texts.map { try textEntry($0.text, $0.box, lines.scale, dev, p) }, "count": lines.texts.count]

        case "batch":
            guard let steps = p["actions"] as? [[String: Any]], !steps.isEmpty else { throw ADBError("missing parameter 'actions' (array of {\"tool\": ..., ...args})") }
            var results: [[String: Any]] = []
            for (i, step) in steps.enumerated() {
                guard let tool = step["tool"] as? String else { throw ADBError("actions[\(i)] has no 'tool'") }
                guard tool != "batch", tool != "screenshot" else { throw ADBError("actions[\(i)]: '\(tool)' is not allowed in a batch") }
                var args = step; args.removeValue(forKey: "tool"); args.removeValue(forKey: "screenshot")
                if args["space"] == nil, let sp = p["space"] { args["space"] = sp }
                // Let each step's effect finish before the next one, except for the last
                // (the batch's own settle/screenshot handles that).
                if i < steps.count - 1, args["settle"] == nil, AgentServer.actions.contains(tool) { args["settle"] = true }
                do {
                    var r = try dispatch(tool, args)
                    r.removeValue(forKey: "image")
                    results.append(["tool": tool, "result": r])
                } catch {
                    throw ADBError("actions[\(i)] (\(tool)) failed: \(error) — \(results.count) earlier step(s) completed")
                }
            }
            return ["completed": results.count, "results": results]

        case "ui_tree":
            let nodes = try cachedUITree()
            let (sx, sy) = try uiScale()
            let filter = (p["filter"] as? String)?.lowercased()
            let all = p["all"] as? Bool ?? false
            var out: [[String: Any]] = []
            for n in nodes {
                if let f = filter, n.matches(f) == nil { continue }
                if !all && filter == nil && n.label.isEmpty && !n.interactive { continue }
                if n.bounds.width <= 0 || n.bounds.height <= 0 { continue }
                let devRect = CGRect(x: n.bounds.minX * sx, y: n.bounds.minY * sy, width: n.bounds.width * sx, height: n.bounds.height * sy)
                let r = try fromDevice(devRect, p)
                var e: [String: Any] = ["bounds": [Int(r.minX), Int(r.minY), Int(r.maxX), Int(r.maxY)],
                                        "center": [Int(r.midX), Int(r.midY)]]
                if !n.text.isEmpty { e["text"] = n.text }
                if !n.desc.isEmpty { e["desc"] = n.desc }
                if !n.resourceId.isEmpty { e["id"] = n.resourceId.split(separator: "/").last.map(String.init) ?? n.resourceId }
                e["class"] = n.className.split(separator: ".").last.map(String.init) ?? n.className
                if n.clickable { e["clickable"] = true }
                if n.longClickable { e["long_clickable"] = true }
                if n.scrollable { e["scrollable"] = true }
                if n.editable { e["editable"] = true }
                if n.focused { e["focused"] = true }
                if n.selected { e["selected"] = true }
                if let ch = n.checked { e["checked"] = ch }
                if !n.enabled { e["enabled"] = false }
                out.append(e)
            }
            let fg = nodes.first?.package ?? ""
            return ["elements": out, "count": out.count, "package": fg]

        case "tap_element":
            let q = try requireString(p, "query")
            let source = p["source"] as? String ?? "auto"
            let idx = Int(num(p, "index") ?? 0)
            guard idx >= 0 else { throw ADBError("index must be nonnegative") }
            let long = p["long_press"] as? Bool ?? false
            let dev = try deviceSize()

            // 1. On-screen text via OCR (~100 ms, no UiAutomation needed). Exact / prefix matches only
            //    in auto mode, so an icon's content description in the UI tree can still win.
            var ocrMatches: [TextMatch] = []
            var ocrScale: CGFloat = 1
            if source != "ui" {
                let lines = try recognizeText()
                ocrScale = lines.scale
                ocrMatches = TextRecognizer.find(q, in: lines.texts)
                let strong = source == "ocr" ? ocrMatches : ocrMatches.filter { $0.score <= 1 }
                if idx < strong.count {
                    let m = strong[idx]
                    let x = Double(m.box.midX * ocrScale), y = Double(m.box.midY * ocrScale)
                    if long { c.longPress(x: x, y: y, ms: 600) } else { c.tap(x: x, y: y) }
                    let e = try textEntry(m.line.text, m.box, ocrScale, dev, p)
                    return ["tapped": m.line.text, "center": e["center"]!, "matches": strong.count, "source": "ocr"]
                }
                if source == "ocr" { throw ADBError("no on-screen text matching '\(q)' (found \(ocrMatches.count))") }
            }

            // 2. Accessibility tree (text, content description, resource id).
            var treeError: Error?
            if let nodes = try? cachedUITree() {
                let matches = nodes.compactMap { n -> (Int, UINode)? in
                    guard n.bounds.width > 0, let score = n.matches(q) else { return nil }
                    return (score * 2 + (n.clickable ? 0 : 1), n)
                }.sorted { $0.0 < $1.0 }.map(\.1)
                if idx < matches.count {
                    let n = matches[idx]
                    let (sx, sy) = try uiScale()
                    let x = n.center.x * sx, y = n.center.y * sy
                    if long { c.longPress(x: x, y: y, ms: 600) } else { c.tap(x: x, y: y) }
                    let r = try fromDevice(CGRect(x: n.bounds.minX * sx, y: n.bounds.minY * sy, width: n.bounds.width * sx, height: n.bounds.height * sy), p)
                    return ["tapped": n.label.isEmpty ? n.resourceId : n.label, "center": [Int(r.midX), Int(r.midY)], "matches": matches.count, "source": "ui"]
                }
            } else if source == "ui" {
                _ = try cachedUITree() // rethrow the real error
            } else {
                treeError = ADBError("accessibility tree unavailable")
            }

            // 3. Weaker OCR matches (query appears inside a longer line).
            if source == "auto" && idx < ocrMatches.count {
                let m = ocrMatches[idx]
                let x = Double(m.box.midX * ocrScale), y = Double(m.box.midY * ocrScale)
                if long { c.longPress(x: x, y: y, ms: 600) } else { c.tap(x: x, y: y) }
                let e = try textEntry(m.line.text, m.box, ocrScale, dev, p)
                return ["tapped": m.line.text, "center": e["center"]!, "matches": ocrMatches.count, "source": "ocr"]
            }
            throw ADBError("nothing matching '\(q)' on screen" + (treeError != nil ? " (OCR only; the accessibility tree is held by another automation tool)" : ""))

        case "wait_for":
            let q = try requireString(p, "query")
            let gone = p["gone"] as? Bool ?? false
            let source = p["source"] as? String ?? "ocr"
            let deadline = Date().addingTimeInterval((num(p, "timeout_ms") ?? 10_000) / 1000)
            let t0 = Date()
            var lastTree = Date.distantPast
            while Date() < deadline {
                var found = false
                if source != "ui" { found = !TextRecognizer.find(q, in: try recognizeText().texts).isEmpty }
                // The tree also sees content descriptions; it is slow, so poll it at most once a second.
                if !found, source != "ocr", Date().timeIntervalSince(lastTree) > 1 {
                    lastTree = Date()
                    found = ((try? cachedUITree()) ?? []).contains { $0.matches(q) != nil }
                }
                if found != gone { return ["ok": true, "waited_ms": Int(Date().timeIntervalSince(t0) * 1000)] }
                // Next check when the screen changes (or after 250 ms).
                c.frames.waitForFrame(after: c.frames.frameCounter, timeout: 0.25)
            }
            throw ADBError("timed out waiting for '\(q)'\(gone ? " to disappear" : "")")

        default:
            throw ADBError("unknown observation method '\(method)'")
        }
    }

    // MARK: Observation helpers

    /// Input methods that change the screen. They accept `screenshot` (return the settled screen
    /// in the same response, saving the agent a round trip) and `settle` (just wait for it).
    static let actions = AgentTools.actionNames
    /// Actions whose visible effect can take a while to start (app start, intents).
    private static let slowToReact: Set<String> = ["launch_app", "open_url", "unlock", "rotate"]

    func dispatch(_ method: String, _ p: [String: Any]) throws -> [String: Any] {
        guard AgentServer.actions.contains(method) else { return try handle(method, p) }
        let wantShot = p["screenshot"] as? Bool ?? false
        let wantSettle = p["settle"] as? Bool ?? wantShot
        let frames = controller.frames
        let before = frames.frameCounter
        var r = try handle(method, p)
        if wantSettle {
            let st = frames.waitForSettle(after: before, reactTimeout: AgentServer.slowToReact.contains(method) ? 1.5 : 0.35,
                                          quiet: 0.2, timeout: 3)
            r["settle_ms"] = st.ms
            if !st.changed { r["screen_changed"] = false }
            if !st.settled { r["still_changing"] = true }
        }
        if wantShot {
            var sp: [String: Any] = [:]
            if let m = p["max_dimension"] { sp["max_dimension"] = m }
            r.merge(try captureScreenshot(sp), uniquingKeysWith: { _, b in b })
        }
        return r
    }

    /// Debug hook: switch display pacing (the mirror view follows the setting).
    func setPacing(_ v: Any?) throws {
        guard let v else { return }
        guard let s = v as? String, let mode = Pacing(rawValue: s) else {
            throw ADBError("pacing must be one of: " + Pacing.allCases.map(\.rawValue).joined(separator: ", "))
        }
        UserDefaults.standard.set(mode.rawValue, forKey: "pacing")
    }

    func captureScreenshot(_ p: [String: Any]) throws -> [String: Any] {
        let c = controller
        let maxDim = Int(num(p, "max_dimension") ?? Double(AgentAPI.defaultMaxDimension))
        let format = FrameStore.Format(rawValue: p["format"] as? String ?? "jpeg") ?? .jpeg
        guard let enc = c.frames.encoded(format: format, maxDimension: maxDim == 0 ? nil : maxDim, quality: 0.75) else {
            throw ADBError("no frame available yet")
        }
        shotLock.lock(); shotSize = CGSize(width: enc.width, height: enc.height); shotLock.unlock()
        let dev = try deviceSize()
        return ["image": enc.data.base64EncodedString(), "mime": format == .png ? "image/png" : "image/jpeg",
                "width": enc.width, "height": enc.height, "device_width": Int(dev.width), "device_height": Int(dev.height)]
    }

    /// OCR of the current frame, cached per frame. `scale` maps image pixels to device pixels.
    func recognizeText() throws -> (texts: [ScreenText], scale: CGFloat) {
        let frames = controller.frames
        let counter = frames.frameCounter
        ocrLock.lock(); defer { ocrLock.unlock() }
        if let c = ocrCache, c.counter == counter { return (c.texts, c.scale) }
        let dev = try deviceSize()
        // Native video resolution; Vision handles ~1-2k px images in ~100-200 ms.
        guard let img = frames.cgImage(maxDimension: 2400) else { throw ADBError("no frame available yet") }
        let texts = try TextRecognizer.recognize(img)
        let scale = dev.width / CGFloat(img.width)
        ocrCache = (counter, texts, scale)
        return (texts, scale)
    }

    func textEntry(_ text: String, _ box: CGRect, _ scale: CGFloat, _ dev: CGSize, _ p: [String: Any]) throws -> [String: Any] {
        let r = try fromDevice(CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale), p)
        return ["text": text, "center": [Int(r.midX), Int(r.midY)], "bounds": [Int(r.minX), Int(r.minY), Int(r.maxX), Int(r.maxY)]]
    }

    /// uiautomator dumps take ~1-2 s; reuse the last one while the screen hasn't changed.
    func cachedUITree() throws -> [UINode] {
        let frames = controller.frames
        let counter = frames.frameCounter
        cacheLock.lock()
        if let t = treeCache, t.counter == counter { cacheLock.unlock(); return t.nodes }
        cacheLock.unlock()
        let nodes = try DeviceQueries(adb: controller.adb, serial: try requireSerial()).uiTree()
        cacheLock.lock(); treeCache = (counter, nodes); cacheLock.unlock()
        return nodes
    }

}
