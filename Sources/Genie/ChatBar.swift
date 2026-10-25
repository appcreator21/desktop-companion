import AppKit
import SwiftUI

/// The dark frosted chat bar along the bottom of the screen.
@MainActor
final class ChatController: ObservableObject {
    static let panelSize = CGSize(width: 600, height: 80)

    @Published var text = ""
    @Published var isBusy = false
    @Published var focusToken = 0

    var onSubmit: ((String) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    private let panel: NSPanel
    private var previousApp: NSRunningApplication?

    init(panel: NSPanel) {
        self.panel = panel
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front != NSRunningApplication.current { previousApp = front }

        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(NSPoint(x: screen.midX - Self.panelSize.width / 2, y: screen.minY + 16))
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKey()
        focusToken += 1
        onVisibilityChange?(true)
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        onVisibilityChange?(false)
        // Give focus back to the app you were using.
        previousApp?.activate()
        previousApp = nil
    }

    func submit() {
        onSubmit?(text)
    }
}

struct ChatBarView: View {
    @ObservedObject var chat: ChatController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button("Exit") { chat.hide() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.14)))

            TextField("", text: $chat.text,
                      prompt: Text("Make a wish…  (try “open Spotify” or “help me focus”)")
                        .foregroundColor(.white.opacity(0.45)))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit { chat.submit() }

            if chat.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 560, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.55))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .frame(width: ChatController.panelSize.width, height: ChatController.panelSize.height)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
        .onChange(of: chat.focusToken) { _, _ in focused = true }
        .onExitCommand { chat.hide() }
    }
}
