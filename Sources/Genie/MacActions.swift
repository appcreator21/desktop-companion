import AppKit
import ApplicationServices

/// Talks to macOS: finds apps, windows and Dock icons, opens and quits things.
/// Everything returns AppKit coordinates (origin at the bottom-left of the main screen).
enum MacActions {
    struct WindowInfo {
        let id: CGWindowID
        let frame: CGRect
        let owner: String
    }

    // MARK: - Windows

    /// Normal app windows on screen, frontmost first. Doesn't need any permission.
    static func windows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != myPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 240, bounds.height > 160,
                  let number = info[kCGWindowNumber as String] as? Int
            else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            return WindowInfo(id: CGWindowID(number), frame: toAppKit(bounds), owner: owner)
        }
    }

    /// Converts a rect from screen coordinates with a top-left origin (CoreGraphics / Accessibility).
    static func toAppKit(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Finding apps

    private static let aliases: [String: String] = [
        "chrome": "google chrome",
        "vscode": "visual studio code",
        "vs code": "visual studio code",
        "settings": "system settings",
        "preferences": "system settings",
        "system preferences": "system settings",
        "word": "microsoft word",
        "excel": "microsoft excel",
        "powerpoint": "microsoft powerpoint",
        "outlook": "microsoft outlook",
        "teams": "microsoft teams",
        "app store": "app store",
    ]

    static func canonical(_ raw: String) -> String {
        var name = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for prefix in ["the ", "my "] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        for suffix in [" app", " application"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        return aliases[name] ?? name
    }

    static func findApp(named raw: String) -> URL? {
        let wanted = canonical(raw)
        guard !wanted.isEmpty else { return nil }
        if wanted == "finder" { return URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app") }

        if let running = runningApp(named: wanted), let url = running.bundleURL { return url }

        let apps = allApps()
        func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        if let exact = apps.first(where: { name($0) == wanted }) { return exact }
        if let prefix = apps.first(where: { name($0).hasPrefix(wanted) }) { return prefix }
        if wanted.count >= 3, let partial = apps.first(where: { name($0).contains(wanted) }) { return partial }
        return nil
    }

    private static func allApps() -> [URL] {
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var result: [URL] = []
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folder),
                                                          includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    result.append(item)
                } else if let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    // One level deeper, for folders like "/Applications/Adobe Photoshop/".
                    result.append(contentsOf: inner.filter { $0.pathExtension == "app" })
                }
            }
        }
        return result
    }

    static func runningApp(named raw: String) -> NSRunningApplication? {
        let wanted = canonical(raw)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { ($0.localizedName ?? "").lowercased() == wanted }
            ?? apps.first { ($0.localizedName ?? "").lowercased().contains(wanted) }
    }

    static func openAppNames() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
    }

    static func appName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Opening things

    static func openApp(at url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private static let knownSites: [String: String] = [
        "youtube": "youtube.com", "gmail": "mail.google.com", "google": "google.com",
        "netflix": "netflix.com", "github": "github.com", "reddit": "reddit.com",
        "twitter": "x.com", "x": "x.com", "instagram": "instagram.com", "tiktok": "tiktok.com",
        "claude": "claude.ai", "amazon": "amazon.com", "google maps": "maps.google.com",
        "wikipedia": "wikipedia.org", "twitch": "twitch.tv", "spotify web": "open.spotify.com",
    ]

    static func knownSite(_ raw: String) -> URL? {
        knownSites[canonical(raw)].flatMap { URL(string: "https://" + $0) }
    }

    /// Turns "youtube", "apple.com" or "best pizza near me" into a URL.
    static func websiteURL(for raw: String) -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let url = URL(string: text) { return url }
        if let site = knownSite(text) { return site }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text) { return url }
        return searchURL(text)
    }

    static func searchURL(_ query: String) -> URL {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    static var defaultBrowserName: String? {
        guard let probe = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return appName(for: app)
    }

    // MARK: - Dock (needs Accessibility permission)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Center of an app's Dock icon, so the genie can fly over and tap it.
    static func dockIconCenter(for name: String) -> CGPoint? {
        guard isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let wanted = name.lowercased()
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let lists = attribute(dockElement, kAXChildrenAttribute) as? [AXUIElement] else { return nil }

        for list in lists {
            guard let items = attribute(list, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for item in items {
                guard let title = (attribute(item, kAXTitleAttribute) as? String)?.lowercased(),
                      title == wanted || title.contains(wanted) || wanted.contains(title),
                      !title.isEmpty,
                      let positionValue = attribute(item, kAXPositionAttribute),
                      let sizeValue = attribute(item, kAXSizeAttribute)
                else { continue }
                var origin = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                let frame = toAppKit(CGRect(origin: origin, size: size))
                return CGPoint(x: frame.midX, y: frame.midY)
            }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

// MARK: - Closing windows (the red ✕)

extension MacActions {
    struct CloseTarget {
        let appName: String
        /// Where the red close button is (AppKit coordinates).
        let point: CGPoint
        /// The real button, when we have Accessibility access.
        let button: AXUIElement?
    }

    /// Finds the red close button on an app's front window.
    static func closeButton(forApp raw: String) -> CloseTarget? {
        guard let app = runningApp(named: raw), app != NSRunningApplication.current else { return nil }
        let name = app.localizedName ?? raw
        let pid = app.processIdentifier

        if isTrusted {
            let element = AXUIElementCreateApplication(pid)
            let window = attribute(element, kAXFocusedWindowAttribute)
                ?? (attribute(element, kAXWindowsAttribute) as? [AXUIElement])?.first
            if let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                let win = window as! AXUIElement
                if let close = attribute(win, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID() {
                    let button = close as! AXUIElement
                    if let frame = frame(of: button) {
                        return CloseTarget(appName: name, point: CGPoint(x: frame.midX, y: frame.midY), button: button)
                    }
                }
            }
        }

        // No Accessibility access: guess from the window list. The red dot sits ~20pt in, ~16pt down.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let info = list.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        let frame = toAppKit(bounds)
        return CloseTarget(appName: name, point: CGPoint(x: frame.minX + 20, y: frame.maxY - 16), button: nil)
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return toAppKit(CGRect(origin: origin, size: size))
    }
}

// MARK: - Running scripts (AppleScript and shell)

extension MacActions {
    /// Runs a program off the main thread and returns its combined output and exit code.
    static func runProcess(_ executable: String, _ args: [String], input: String? = nil,
                           timeout: Double = 60) async -> (output: String, status: Int32) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            var env = ProcessInfo.processInfo.environment
            let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
            env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
            process.environment = env

            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            let inPipe = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
            do { try process.run() } catch { return ("Couldn't run: \(error.localizedDescription)", -1) }
            if let input {
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count > 4000 { text = String(text.prefix(4000)) + "\n…(cut off)" }
            return (text, process.terminationStatus)
        }.value
    }

    static func runAppleScript(_ source: String) async -> (output: String, status: Int32) {
        await runProcess("/usr/bin/osascript", ["-"], input: source)
    }

    static func runShell(_ command: String) async -> (output: String, status: Int32) {
        await runProcess("/bin/zsh", ["-lc", command])
    }

    /// The app named in `tell application "X"`, so the genie can fly over to it.
    static func appTold(in script: String) -> String? {
        guard let range = script.range(of: #"tell application "([^"]+)""#, options: .regularExpression) else { return nil }
        let match = script[range]
        return match.split(separator: "\"").dropFirst().first.map(String.init)
    }
}
