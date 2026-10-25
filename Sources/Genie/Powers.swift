import AppKit

/// The genie's powers: things he can actually do on your Mac.
/// Used both by the free built-in commands and by Claude (as tools).
@MainActor
final class Powers {
    private let brain: GenieBrain

    init(brain: GenieBrain) {
        self.brain = brain
    }

    static let helpText = """
    I can: open Safari · quit Spotify · search cute cats · open youtube · focus 25 · nap. \
    Add a Claude API key from the 🧞 menu and I can chat about anything!
    """

    static func isYes(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["y", "yes", "yeah", "yep", "sure", "ok", "okay", "do it", "go", "please"].contains(t)
    }

    // MARK: - Built-in commands (free, instant, no AI)

    /// Handles simple commands. Returns nil if the text isn't one (so Claude can take it).
    func handleLocally(_ input: String, hasClaude: Bool) async -> String? {
        var text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
        for filler in ["hey genie, ", "hey genie ", "genie, ", "genie ", "please ", "can you ", "could you "]
        where text.hasPrefix(filler) {
            text.removeFirst(filler.count)
        }
        let words = text.split(separator: " ").count

        if let rest = text.dropPrefix(["open ", "launch ", "start ", "go to "]), !rest.contains("focus"), !rest.contains("timer") {
            // Long requests ("open my project in Xcode and run it") are for Claude.
            guard words <= 4 || !hasClaude else { return nil }
            if MacActions.findApp(named: rest) != nil { return await openApp(rest).0 }
            if MacActions.knownSite(rest) != nil || !hasClaude { return await openWebsite(rest).0 }
            return nil
        }
        if let rest = text.dropPrefix(["quit ", "close "]), words <= 4 {
            return await quitApp(rest).0
        }
        if let rest = text.dropPrefix(["hide "]), words <= 4 {
            return hideApp(rest).0
        }
        if let rest = text.dropPrefix(["search for ", "search ", "google ", "look up "]) {
            return await openWebsite(rest, forceSearch: true).0
        }
        if text.contains("stop focus") || text.contains("stop the timer") || text.contains("stop timer")
            || text.contains("cancel timer") {
            brain.stopFocus(completed: false)
            return "Okay, timer stopped."
        }
        if text.contains("focus") || text.contains("pomodoro"), words <= 6 {
            let minutes = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first ?? 25
            brain.startFocus(minutes: minutes)
            return "Let's do this! \(min(180, max(1, minutes))) minutes of focus. I'll be reading next to you 📚"
        }
        if ["nap", "sleep", "go to sleep", "take a nap", "go nap"].contains(text) {
            brain.nap()
            return "Zzz…"
        }
        if ["come here", "follow me", "follow my cursor", "follow"].contains(text) {
            brain.followCursor(seconds: 10)
            return "Right behind you! ✨"
        }
        if !hasClaude, ["hi", "hello", "hey", "yo", "sup"].contains(text) {
            return "Hello, master of this Mac! ✨ " + Self.helpText
        }
        return nil
    }

    // MARK: - Tools for Claude

    func run(tool: String, input: [String: Any]) async -> (String, Bool) {
        switch tool {
        case "open_app":
            return await openApp(input["name"] as? String ?? "")
        case "open_website":
            return await openWebsite(input["url_or_search"] as? String ?? "")
        case "quit_app":
            return await quitApp(input["name"] as? String ?? "")
        case "hide_app":
            return hideApp(input["name"] as? String ?? "")
        case "list_open_apps":
            return (MacActions.openAppNames().joined(separator: ", "), false)
        case "start_focus_timer":
            let minutes = (input["minutes"] as? Int) ?? 25
            brain.startFocus(minutes: minutes)
            return ("Focus timer started for \(minutes) minutes.", false)
        case "stop_focus_timer":
            brain.stopFocus(completed: false)
            return ("Focus timer stopped.", false)
        case "take_a_nap":
            brain.nap()
            return ("The genie is napping now.", false)
        default:
            return ("Unknown tool: \(tool)", true)
        }
    }

    // MARK: - Actions (with animation)

    func openApp(_ name: String) async -> (String, Bool) {
        guard let url = MacActions.findApp(named: name) else {
            return ("I couldn't find an app called “\(name)”.", true)
        }
        let appName = MacActions.appName(for: url)
        await brain.performTap(at: MacActions.dockIconCenter(for: appName) ?? brain.defaultTapSpot)
        do {
            try await MacActions.openApp(at: url)
            return ("Poof! \(appName) is open ✨", false)
        } catch {
            return ("I tried, but \(appName) wouldn't open: \(error.localizedDescription)", true)
        }
    }

    func openWebsite(_ query: String, forceSearch: Bool = false) async -> (String, Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Nothing to open.", true) }
        let url = forceSearch ? MacActions.searchURL(trimmed) : MacActions.websiteURL(for: trimmed)
        let browser = MacActions.defaultBrowserName ?? "Safari"
        await brain.performTap(at: MacActions.dockIconCenter(for: browser) ?? brain.defaultTapSpot)
        NSWorkspace.shared.open(url)
        let label = forceSearch ? "Searching for “\(trimmed)” 🔎" : "Opening \(url.host ?? trimmed) ✨"
        return (label, false)
    }

    func quitApp(_ name: String) async -> (String, Bool) {
        guard let app = MacActions.runningApp(named: name), app != NSRunningApplication.current else {
            return ("“\(name)” isn't open.", true)
        }
        let appName = app.localizedName ?? name
        // Closing an app can lose unsaved work, so always ask first.
        guard await brain.ask("Quit \(appName)? 🤔") else {
            return ("You said no, so I left \(appName) open.", false)
        }
        await brain.performTap(at: MacActions.dockIconCenter(for: appName) ?? brain.defaultTapSpot)
        return app.terminate() ? ("Bye bye, \(appName) 👋", false) : ("\(appName) didn't want to quit.", true)
    }

    func hideApp(_ name: String) -> (String, Bool) {
        guard let app = MacActions.runningApp(named: name) else { return ("“\(name)” isn't open.", true) }
        app.hide()
        return ("\(app.localizedName ?? name) is hidden 🙈", false)
    }
}

private extension String {
    /// If the string starts with one of the prefixes, returns the rest (trimmed).
    func dropPrefix(_ prefixes: [String]) -> String? {
        for prefix in prefixes where hasPrefix(prefix) {
            let rest = dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }
}
