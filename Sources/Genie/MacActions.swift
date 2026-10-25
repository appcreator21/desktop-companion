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
