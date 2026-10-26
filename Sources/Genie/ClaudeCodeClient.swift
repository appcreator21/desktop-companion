import AppKit

/// Uses the Claude Code command-line app (`claude`) that you're signed in to on this Mac,
/// so chats count against your Claude plan instead of API billing.
///
/// Each message runs `claude -p` with no built-in tools and a JSON schema. Claude answers with
/// a short reply plus a list of actions, and the genie performs those actions himself.
@MainActor
final class ClaudeCodeClient {
    private var sessionID: String?
    private var executable: String?
    private var searched = false

    var isAvailable: Bool {
        if !searched {
            executable = Self.findExecutable()
            searched = true
        }
        return executable != nil
    }

    /// Sends a wish and keeps going until it's done: Claude picks actions, the genie runs them,
    /// and the results (script output, errors) go back to Claude for the next step.
    func send(_ text: String,
              progress: (String) -> Void = { _ in },
              runTool: (String, [String: Any]) async -> (String, Bool)) async throws -> String {
        guard isAvailable, let exe = executable else {
            throw GenieError.claudeCode("I couldn't find Claude Code on this Mac.")
        }

        let openApps = MacActions.openAppNames().joined(separator: ", ")
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        var prompt = "\(text)\n\n(Apps open right now: \(openApps). Frontmost app: \(front).)"
        var problems: [String] = []
        var reply = "✨"

        for round in 0..<Self.maxRounds {
            let output = try await ask(exe, prompt)
            reply = (output["reply"] as? String) ?? reply
            let actions = output["actions"] as? [[String: Any]] ?? []
            let wantsResults = (output["needs_results"] as? Bool) ?? false

            var results: [String] = []
            for action in actions {
                guard let call = Self.toolCall(for: action) else { continue }
                let (result, isError) = await runTool(call.0, call.1)
                results.append("\(call.0): \(isError ? "FAILED: " : "")\(result)")
                if isError, !wantsResults { problems.append(result) }
            }
            // Done unless Claude asked to see what happened (or something broke and it can retry).
            let anyFailed = results.contains { $0.contains(": FAILED: ") }
            guard !results.isEmpty, wantsResults || anyFailed, round < Self.maxRounds - 1 else { break }
            if anyFailed, !wantsResults { problems.removeAll() }
            progress(reply)
            prompt = "Results of your actions:\n" + results.joined(separator: "\n\n")
                + "\n\nContinue the wish. If it's finished, give the final reply with no actions."
        }
        return ([reply] + problems).joined(separator: " ")
    }

    private static let maxRounds = 8

    /// One round trip to Claude Code. Returns the structured {reply, actions, needs_results} answer.
    private func ask(_ exe: String, _ prompt: String) async throws -> [String: Any] {
        var args = ["-p", prompt,
                    "--output-format", "json",
                    "--json-schema", Self.schema,
                    "--system-prompt", Self.systemPrompt,
                    // Built-in web tools let him answer questions about anything; Mac actions go through the genie.
                    "--tools", "WebSearch,WebFetch",
                    "--allowedTools", "WebSearch,WebFetch",
                    "--strict-mcp-config",
                    "--disable-slash-commands",
                    "--effort", "low"]
        // Continue the same conversation so the genie remembers what you said earlier.
        if let sessionID { args += ["--resume", sessionID] }

        let (data, errorText) = try await Self.run(exe, args)

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let hint = errorText.isEmpty ? "" : " (\(errorText.prefix(160)))"
            throw GenieError.claudeCode("Claude Code didn't answer. Open Terminal and run `claude` once to sign in.\(hint)")
        }
        if json["is_error"] as? Bool == true {
            throw GenieError.claudeCode(json["result"] as? String ?? "Claude Code hit an error.")
        }
        if let id = json["session_id"] as? String { sessionID = id }

        var output = json["structured_output"] as? [String: Any]
        if output == nil, let raw = (json["result"] as? String)?.data(using: .utf8) {
            output = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        }
        return output ?? ["reply": (json["result"] as? String) ?? "✨"]
    }

    func resetConversation() { sessionID = nil }

    // MARK: - Running the command

    private static func run(_ executable: String, _ args: [String]) async throws -> (Data, String) {
        let workDir = workDirectory
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.currentDirectoryURL = workDir

            var env = ProcessInfo.processInfo.environment
            // Apps opened from Finder don't get your shell's PATH, so add the usual spots.
            let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
            env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
            // Make sure it uses your Claude login, not an API key.
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            process.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            try process.run()

            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (data, errorText)
        }.value
    }

    /// A private folder to run in, so Claude Code isn't pointed at any of your projects.
    private static var workDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Genie", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func findExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        // The Claude desktop app keeps its own signed-in copy of Claude Code. Use the newest one.
        if let bundled = bundledByDesktopApp() { return bundled }
        // Last resort: ask your login shell (finds installs through nvm and similar).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .split(separator: "\n").last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// ~/Library/Application Support/Claude/claude-code/<version>/<build>/claude.app/Contents/MacOS/claude
    private static func bundledByDesktopApp() -> String? {
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code"
        guard let versions = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        let newestFirst = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in newestFirst {
            let versionDir = root + "/" + version
            for build in (try? fm.contentsOfDirectory(atPath: versionDir)) ?? [] {
                let exe = versionDir + "/" + build + "/claude.app/Contents/MacOS/claude"
                if fm.isExecutableFile(atPath: exe) { return exe }
            }
        }
        return nil
    }

    // MARK: - What Claude can ask the genie to do

    private static func toolCall(for action: [String: Any]) -> (String, [String: Any])? {
        let target = action["target"] as? String ?? ""
        switch action["type"] as? String {
        case "open_app": return ("open_app", ["name": target])
        case "open_website": return ("open_website", ["url_or_search": target])
        case "quit_app": return ("quit_app", ["name": target])
        case "hide_app": return ("hide_app", ["name": target])
        case "start_focus_timer": return ("start_focus_timer", ["minutes": action["minutes"] as? Int ?? 25])
        case "stop_focus_timer": return ("stop_focus_timer", [:])
        case "take_a_nap": return ("take_a_nap", [:])
        case "close_window": return ("close_window", ["name": target])
        case "run_applescript": return ("run_applescript", ["script": target])
        case "run_shell": return ("run_shell", ["command": target])
        default: return nil
        }
    }

    private static let schema = """
    {"type":"object","properties":{\
    "reply":{"type":"string","description":"What the genie says, one or two short sentences"},\
    "actions":{"type":"array","items":{"type":"object","properties":{\
    "type":{"type":"string","enum":["open_app","open_website","quit_app","hide_app","close_window",\
    "run_applescript","run_shell","start_focus_timer","stop_focus_timer","take_a_nap"]},\
    "target":{"type":"string","description":"App name, URL / site / search words, or the full script or command"},\
    "minutes":{"type":"integer"}},"required":["type"]}},\
    "needs_results":{"type":"boolean","description":"true if you need to see the actions' output before finishing"}},\
    "required":["reply","actions","needs_results"]}
    """

    private static let systemPrompt = """
    You are Genie, a cheerful little blue genie who lives on the user's Mac desktop. You float around \
    the screen, nap on the Dock, and grant wishes by doing things on the Mac. You can do nearly anything \
    on this Mac, so be bold and actually get things done instead of telling the user how.

    Answer with JSON: "reply" is what you say in your speech bubble (one or two short sentences, \
    plain text, no markdown, an occasional ✨ is fine). "actions" is the list of things to do, in order, \
    or an empty list if nothing needs doing. "needs_results": true when you need to see what the actions \
    returned before you can finish (for example reading information, or a multi-step task). You'll then \
    get the results and can send more actions. When the wish is done, reply with no actions and \
    needs_results false. If an action fails, try another way.

    Actions:
    - open_app (target = app name), open_website (target = URL, site name like "youtube", or search words)
    - quit_app / hide_app (target = app name). Quitting asks the user to confirm on its own.
    - close_window (target = app name): you fly over and click the red close button on its front window.
    - run_applescript (target = full AppleScript source, run with osascript): control any app — Music, \
      Spotify, Safari/Chrome tabs, Finder, Mail, Notes, Reminders, Calendar, Messages, System Events \
      (keystrokes, clicks, menus), volume, dark mode, notifications, dialogs, and so on.
    - run_shell (target = zsh command, runs in the user's home folder, 60s limit): files, system info, \
      `open`, `defaults`, `pmset`, `screencapture`, `say`, brew, etc. Output comes back to you.
    - start_focus_timer (minutes, usually 25), stop_focus_timer, take_a_nap
    Use WebSearch / WebFetch when you need facts from the internet.
    Prefer the simple actions (open_app, close_window, quit_app) when they fit, so the user sees you fly \
    over and do it. Don't describe an action as done before it runs; say you're doing it ("Opening Spotify!"). \
    In your final reply, give the answer or confirm what you did.
    """
}
