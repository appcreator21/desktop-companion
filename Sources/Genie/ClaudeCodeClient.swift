import Foundation

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

    func send(_ text: String,
              runTool: (String, [String: Any]) async -> (String, Bool)) async throws -> String {
        guard isAvailable, let exe = executable else {
            throw GenieError.claudeCode("I couldn't find Claude Code on this Mac.")
        }

        let openApps = MacActions.openAppNames().joined(separator: ", ")
        let prompt = "\(text)\n\n(Apps open right now: \(openApps))"

        var args = ["-p", prompt,
                    "--output-format", "json",
                    "--json-schema", Self.schema,
                    "--system-prompt", Self.systemPrompt,
                    "--tools", "",
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
        let reply = (output?["reply"] as? String) ?? (json["result"] as? String) ?? "✨"
        let actions = output?["actions"] as? [[String: Any]] ?? []

        var problems: [String] = []
        for action in actions {
            guard let call = Self.toolCall(for: action) else { continue }
            let (result, isError) = await runTool(call.0, call.1)
            if isError { problems.append(result) }
        }
        return ([reply] + problems).joined(separator: " ")
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
        default: return nil
        }
    }

    private static let schema = """
    {"type":"object","properties":{\
    "reply":{"type":"string","description":"What the genie says, one or two short sentences"},\
    "actions":{"type":"array","items":{"type":"object","properties":{\
    "type":{"type":"string","enum":["open_app","open_website","quit_app","hide_app",\
    "start_focus_timer","stop_focus_timer","take_a_nap"]},\
    "target":{"type":"string","description":"App name, or URL / site name / search words"},\
    "minutes":{"type":"integer"}},"required":["type"]}}},\
    "required":["reply","actions"]}
    """

    private static let systemPrompt = """
    You are Genie, a cheerful little blue genie who lives on the user's Mac desktop. You float around \
    the screen, nap on the Dock, and grant wishes by doing things on the Mac.

    Answer with JSON: "reply" is what you say in your speech bubble (one or two short sentences, \
    plain text, no markdown, an occasional ✨ is fine). "actions" is the list of things to do, in order, \
    or an empty list if nothing needs doing:
    - open_app (target = app name), open_website (target = URL, site name like "youtube", or search words)
    - quit_app / hide_app (target = app name). Quitting asks the user to confirm on its own.
    - start_focus_timer (minutes, usually 25), stop_focus_timer, take_a_nap
    Only use those actions. If the user wants something they can't do, say so in the reply. \
    Don't describe an action as done; say you're doing it ("Opening Spotify!").
    """
}
