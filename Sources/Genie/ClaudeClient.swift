import Foundation

enum GenieError: LocalizedError {
    case noKey
    case api(status: Int, message: String)
    case claudeCode(String)

    var errorDescription: String? {
        switch self {
        case let .claudeCode(message):
            return message
        case .noKey:
            return "I need a Claude API key for that. Add one from the 🧞 menu."
        case let .api(status, message):
            switch status {
            case 401: return "That API key didn't work. Set a new one from the 🧞 menu."
            case 429: return "I'm out of breath (rate limited). Try again in a moment."
            case 500...599: return "My magic lamp is overloaded right now. Try again soon."
            default: return "Something went wrong (\(status)): \(message)"
            }
        }
    }
}

/// Talks to Claude over the Messages API and runs the genie's tools in a loop.
/// Swift has no official Anthropic SDK, so this uses plain URLSession + JSON.
@MainActor
final class ClaudeClient {
    static let keychainAccount = "anthropic-api-key"
    static let model = "claude-opus-5-5"

    /// The conversation so far. Assistant turns are stored exactly as the API returned them.
    private var messages: [[String: Any]] = []

    private var apiKey: String? {
        if let key = Keychain.load(account: Self.keychainAccount), !key.isEmpty { return key }
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty { return key }
        return nil
    }

    var hasKey: Bool { apiKey != nil }

    /// Sends a message, lets Claude use tools as many times as it needs, and returns the final reply.
    func send(_ text: String,
              runTool: (String, [String: Any]) async -> (String, Bool)) async throws -> String {
        guard let key = apiKey else { throw GenieError.noKey }
        let checkpoint = messages.count
        messages.append(["role": "user", "content": text])

        do {
            for _ in 0..<8 {
                let response = try await post(key: key)
                let content = response["content"] as? [[String: Any]] ?? []
                messages.append(["role": "assistant", "content": content])

                switch (response["stop_reason"] as? String) ?? "" {
                case "refusal":
                    return "Hmm, that's one wish I can't grant."
                case "tool_use":
                    var results: [[String: Any]] = []
                    for block in content where block["type"] as? String == "tool_use" {
                        let id = block["id"] as? String ?? ""
                        let name = block["name"] as? String ?? ""
                        let input = block["input"] as? [String: Any] ?? [:]
                        let (output, isError) = await runTool(name, input)
                        results.append(["type": "tool_result", "tool_use_id": id,
                                        "content": output, "is_error": isError])
                    }
                    // All results go back together in one message.
                    messages.append(["role": "user", "content": results])
                default:
                    let reply = content
                        .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return reply.isEmpty ? "Done! ✨" : reply
                }
            }
            return "Phew, that was a lot of magic. I did what I could!"
        } catch {
            // Drop the half-finished turn so the conversation stays valid.
            messages.removeSubrange(checkpoint..<messages.count)
            throw error
        }
    }

    private func post(key: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // If a safety check declines a request, the API retries it on a fallback model.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": Self.systemPrompt,
            "tools": Self.tools,
            "messages": messages,
            // Low effort keeps the genie quick and cheap for chat.
            "output_config": ["effort": "low"],
            "fallbacks": "default",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            throw GenieError.api(status: status, message: message)
        }
        return json
    }

    // MARK: - Prompt and tools

    private static let systemPrompt = """
    You are Genie, a cheerful little blue genie who lives on the user's Mac desktop. You float around \
    the screen, nap on the Dock, and grant wishes by actually doing things on the Mac with your tools.

    Your replies appear in a small speech bubble, so keep them to one or two short sentences, plain \
    text, no markdown. A light, playful genie flavor is welcome (an occasional ✨), but be genuinely \
    helpful first.

    When the user asks you to do something on the Mac, use your tools instead of explaining how. \
    Quitting an app asks the user to confirm automatically, so just call quit_app. If a tool fails, \
    say so plainly. If something is beyond your tools, say what you can't do yet.
    """

    private static let tools: [[String: Any]] = [
        tool("open_app", "Open (launch) a Mac app by name, e.g. Safari, Spotify, Xcode, Notes.",
             ["name": ["type": "string", "description": "The app's name"]]),
        tool("open_website", "Open a website or run a web search in the default browser.",
             ["url_or_search": ["type": "string",
                                "description": "A URL, a site name like 'youtube', or search words"]]),
        tool("quit_app", "Quit a running app. The user is asked to confirm first.",
             ["name": ["type": "string", "description": "The app's name"]]),
        tool("hide_app", "Hide a running app's windows.",
             ["name": ["type": "string", "description": "The app's name"]]),
        tool("list_open_apps", "List the apps that are currently running.", [:]),
        tool("start_focus_timer", "Start a focus (pomodoro) timer. The genie reads quietly nearby until it ends.",
             ["minutes": ["type": "integer", "description": "Length in minutes, usually 25"]]),
        tool("stop_focus_timer", "Stop the focus timer early.", [:]),
        tool("take_a_nap", "Make the genie fly to the Dock and take a nap.", [:]),
        tool("close_window", "Fly over and click the red close button on an app's front window.",
             ["name": ["type": "string", "description": "The app's name"]]),
        tool("run_applescript", "Run AppleScript with osascript to control any app or the system. Returns the output.",
             ["script": ["type": "string", "description": "Full AppleScript source"]]),
        tool("run_shell", "Run a zsh command in the user's home folder (60s limit). Returns the output.",
             ["command": ["type": "string", "description": "The shell command"]]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": Array(properties.keys),
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }
}
