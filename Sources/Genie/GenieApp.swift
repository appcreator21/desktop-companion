import AppKit
import Carbon.HIToolbox

@main
enum GenieMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar app: no Dock icon, no main menu.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var brain: GenieBrain!
    private var chat: ChatController!
    private var powers: Powers!
    private let claude = ClaudeClient()
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The genie's own little floating window.
        let genieWindow = Panels.overlay(size: NSSize(width: Layout.width, height: Layout.height))
        brain = GenieBrain(window: genieWindow)
        genieWindow.contentView = FirstMouseHostingView(rootView: GenieRootView(brain: brain))
        genieWindow.orderFrontRegardless()

        powers = Powers(brain: brain)

        // The chat bar along the bottom of the screen.
        let chatPanel = Panels.chat(size: NSSize(width: ChatController.panelSize.width,
                                                 height: ChatController.panelSize.height))
        chat = ChatController(panel: chatPanel)
        chatPanel.contentView = FirstMouseHostingView(rootView: ChatBarView(chat: chat))
        chat.onSubmit = { [weak self] text in self?.handle(text) }
        chat.onVisibilityChange = { [weak self] visible in
            self?.brain.chatVisibilityChanged(visible, barFrame: chatPanel.frame)
        }

        brain.onTap = { [weak self] in self?.chat.toggle() }

        setupMenu()
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.chat.toggle()
        }

        brain.start()
        brain.say("Hi! I'm your genie ✨ Press ⌥Space or click me to make a wish.")
    }

    // MARK: - Chat handling

    private func handle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Typing "yes" / "no" answers a pending question (e.g. "Quit Spotify?").
        if brain.hasPendingQuestion {
            chat.text = ""
            brain.answer(Powers.isYes(trimmed))
            return
        }
        guard !chat.isBusy else { return }

        chat.text = ""
        chat.isBusy = true
        brain.beginThinking()
        Task {
            let reply = await respond(to: trimmed)
            brain.endThinking()
            chat.isBusy = false
            brain.say(reply)
        }
    }

    private func respond(to text: String) async -> String {
        // Simple commands run instantly and for free, no AI needed.
        if let local = await powers.handleLocally(text, hasClaude: claude.hasKey) {
            return local
        }
        guard claude.hasKey else { return Powers.helpText }
        do {
            return try await claude.send(text) { name, input in
                await self.powers.run(tool: name, input: input)
            }
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Menu bar

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🧞"

        let menu = NSMenu()
        add(menu, "Talk to Genie  (⌥Space)", #selector(talk))
        add(menu, "Focus for 25 minutes", #selector(focus25))
        add(menu, "Stop focus timer", #selector(stopFocus))
        add(menu, "Follow my cursor", #selector(follow))
        add(menu, "Nap / wake up", #selector(nap))
        menu.addItem(.separator())
        add(menu, "Set Claude API key…", #selector(setKey))
        add(menu, "Grant Accessibility access…", #selector(grantAccess))
        menu.addItem(.separator())
        add(menu, "Quit Genie", #selector(quit))
        statusItem.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    @objc private func talk() { chat.show() }
    @objc private func focus25() { brain.startFocus(minutes: 25) }
    @objc private func stopFocus() { brain.stopFocus(completed: false) }
    @objc private func follow() { brain.followCursor(seconds: 10) }
    @objc private func nap() { brain.toggleNap() }
    @objc private func grantAccess() { MacActions.requestAccessibility() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func setKey() {
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = "Paste a key from console.anthropic.com. It's saved in your Mac's Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.save(key, account: ClaudeClient.keychainAccount)
        brain.say("Got it! Now I can really grant wishes ✨")
    }
}
