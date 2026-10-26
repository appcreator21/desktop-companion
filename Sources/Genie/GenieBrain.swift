import AppKit
import SwiftUI

enum Layout {
    /// Size of the genie's window: speech bubble on top, genie below.
    static let width: CGFloat = 300
    static let height: CGFloat = 320
    /// The genie drawing is a square at the bottom of the window.
    static let figure: CGFloat = 170
    static let maxSpeed: CGFloat = 520
    /// Where his pointing hand is, relative to his center (facing right, AppKit coordinates).
    static let handOffset = CGPoint(x: 35, y: -33)
}

enum Pose: Equatable {
    case idle, flying, sleeping, thinking, talking, tapping, focusing, happy
}

/// The lamp he lives in until you rub it awake.
enum LampState: Equatable {
    case none
    case waiting
    /// Pouring out of the lamp; the value is when it started (seconds since reference date).
    case emerging(Double)
}

struct Bubble: Equatable {
    let id = UUID()
    var text: String
    var buttons: [String] = []
}

/// Decides what the genie does and moves his window around the screen.
/// Positions use AppKit screen coordinates (origin at the bottom-left of the main screen).
@MainActor
final class GenieBrain: ObservableObject {
    @Published private(set) var pose: Pose = .idle
    @Published private(set) var bubble: Bubble?
    @Published private(set) var lean: Double = 0
    @Published private(set) var facing: CGFloat = 1
    @Published private(set) var look: CGPoint = .zero
    @Published private(set) var focusRemaining: Int?
    @Published private(set) var lampState: LampState = .waiting
    /// 0…1, how much you've rubbed the lamp so far (it glows and shakes more).
    @Published private(set) var lampRub: Double = 0

    var onTap: (() -> Void)?
    var hasPendingQuestion: Bool { question != nil }
    var isFocusing: Bool { focusEnd != nil }
    var isInLamp: Bool { lampState != .none }

    private enum Activity {
        case idle
        case wandering
        case perching(window: CGWindowID, fraction: CGFloat)
        case following(until: Date)
        case sleeping
        case busy
        case dragging
        case inLamp
    }

    private let window: NSWindow
    private var position: CGPoint
    private var lastWindowOrigin = CGPoint(x: -1, y: -1)
    private var velocity = CGVector.zero
    private var target: CGPoint?
    private var arrival: CheckedContinuation<Bool, Never>?
    private var activity: Activity = .inLamp
    private var lastRubX: CGFloat?
    private var rubDirection: CGFloat = 0
    private var rubTravel: CGFloat = 0
    private var nextDecision = Date().addingTimeInterval(5)
    private var nextPerchCheck = Date()
    private var lastTick = CACurrentMediaTime()
    private var timer: Timer?
    private var dragOffset = CGPoint.zero
    private var hoverStart: Date?
    private var poseOverride: Pose?
    private var poseToken = UUID()
    private var isThinking = false
    private var bubbleToken = UUID()
    private var question: CheckedContinuation<Bool, Never>?
    private var questionToken = UUID()
    private var chatPerch: CGPoint?
    private var isChatOpen = false
    private var focusEnd: Date?

    init(window: NSWindow) {
        self.window = window
        position = Self.lampSpot
    }

    /// Bottom-right corner of the main screen, just above the Dock.
    private static var lampSpot: CGPoint {
        let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return CGPoint(x: f.maxX - 150, y: f.minY + Layout.figure / 2)
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Frame loop

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        let mouse = NSEvent.mouseLocation

        updateBehavior(mouse: mouse)
        move(dt: CGFloat(dt))
        updateAppearance(mouse: mouse)

        let origin = CGPoint(x: (position.x - Layout.width / 2).rounded(),
                             y: (position.y - Layout.figure / 2).rounded())
        if origin != lastWindowOrigin {
            window.setFrameOrigin(origin)
            lastWindowOrigin = origin
        }
        updateMousePassThrough(mouse: mouse)
    }

    private func updateBehavior(mouse: CGPoint) {
        let now = Date()

        if let end = focusEnd {
            let remaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
            if remaining != focusRemaining { focusRemaining = remaining }
            if remaining == 0 { stopFocus(completed: true) }
        }

        switch activity {
        case .idle, .wandering:
            if case .wandering = activity, target == nil { activity = .idle }
            if shouldNap { goToSleep(); return }
            if now > nextDecision, canWander { decide() }

        case let .perching(windowID, fraction):
            if shouldNap { goToSleep(); return }
            if now > nextPerchCheck {
                nextPerchCheck = now.addingTimeInterval(0.4)
                // Stay on the window while it's one of the front few; move with it.
                if let win = MacActions.windows().prefix(4).first(where: { $0.id == windowID }),
                   let spot = perchPoint(on: win.frame, fraction: fraction) {
                    target = spot
                } else {
                    activity = .idle
                    nextDecision = now.addingTimeInterval(2)
                }
            }
            if now > nextDecision, canWander { decide() }

        case let .following(until):
            target = clamp(CGPoint(x: mouse.x + 80, y: mouse.y + 30))
            if now > until {
                activity = .idle
                target = nil
                nextDecision = now.addingTimeInterval(6)
            }

        case .sleeping:
            // Hover over him for a moment to wake him up (like petting a cat).
            if genieRect.contains(mouse) {
                if hoverStart == nil { hoverStart = now }
                if let start = hoverStart, now.timeIntervalSince(start) > 1.2 { wake() }
            } else {
                hoverStart = nil
            }

        case .busy, .dragging:
            break

        case .inLamp:
            updateRubbing(mouse: mouse)
        }
    }

    private var canWander: Bool { !isChatOpen && focusEnd == nil && !isThinking }

    private var shouldNap: Bool { canWander && userIdleSeconds > 180 }

    private var userIdleSeconds: Double {
        let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let keys = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return min(mouse, keys)
    }

    private func move(dt: CGFloat) {
        if case .dragging = activity { return }
        guard let target else {
            velocity.dx *= 0.85
            velocity.dy *= 0.85
            return
        }
        let dx = target.x - position.x
        let dy = target.y - position.y
        let distance = hypot(dx, dy)
        if distance < 3 {
            position = target
            velocity = .zero
            self.target = nil
            finishFlight(arrived: true)
            return
        }
        // Ease in and out: speed up toward max speed, slow down near the target.
        let speed = min(Layout.maxSpeed, max(70, distance * 2.6))
        let k = min(1, dt * 6)
        velocity.dx += (dx / distance * speed - velocity.dx) * k
        velocity.dy += (dy / distance * speed - velocity.dy) * k
        position.x += velocity.dx * dt
        position.y += velocity.dy * dt
    }

    private func updateAppearance(mouse: CGPoint) {
        let speed = hypot(velocity.dx, velocity.dy)

        let base: Pose
        switch activity {
        case .sleeping: base = .sleeping
        case .dragging: base = .happy
        default: base = speed > 90 ? .flying : (focusEnd != nil ? .focusing : .idle)
        }
        let newPose = poseOverride ?? (isThinking && base != .flying ? .thinking : base)
        if newPose != pose { pose = newPose }

        if poseOverride != .tapping {
            if abs(velocity.dx) > 40 {
                let f: CGFloat = velocity.dx > 0 ? 1 : -1
                if f != facing { facing = f }
            } else if speed < 20, base == .idle {
                let f: CGFloat = mouse.x >= position.x ? 1 : -1
                if f != facing, abs(mouse.x - position.x) > 40 { facing = f }
            }
        }

        let targetLean = Double(max(-14, min(14, velocity.dx / 35)))
        var newLean = lean + (targetLean - lean) * 0.2
        if abs(newLean) < 0.1 { newLean = 0 }
        if abs(newLean - lean) > 0.05 || (newLean == 0 && lean != 0) { lean = newLean }

        // Eyes follow the cursor. The head sits about 33pt above his center.
        let lx = max(-1, min(1, (mouse.x - position.x) / 250)) * facing
        let ly = max(-1, min(1, (position.y + 33 - mouse.y) / 250))
        if abs(lx - look.x) > 0.04 || abs(ly - look.y) > 0.04 {
            look = CGPoint(x: lx, y: ly)
        }
    }

    /// Clicks pass through to your apps everywhere except on the genie himself.
    private func updateMousePassThrough(mouse: CGPoint) {
        var hit: Bool
        switch lampState {
        case .none: hit = genieRect.contains(mouse) || (focusEnd != nil && timerRect.contains(mouse))
        case .waiting: hit = lampRect.contains(mouse)
        case .emerging: hit = false
        }
        if let bubble, !bubble.buttons.isEmpty, bubbleRect.contains(mouse) { hit = true }
        if case .dragging = activity { hit = true }
        if window.ignoresMouseEvents == hit { window.ignoresMouseEvents = !hit }
    }

    private var genieRect: CGRect {
        CGRect(x: position.x - 48, y: position.y - 82, width: 96, height: 150)
    }

    /// The lamp, drawn in the bottom part of his window while he's inside it.
    private var lampRect: CGRect {
        CGRect(x: position.x - 62, y: position.y - Layout.figure / 2 + 8, width: 124, height: 70)
    }

    /// The focus timer pill under him (it has a stop button).
    private var timerRect: CGRect {
        CGRect(x: position.x - 70, y: position.y - Layout.figure / 2, width: 140, height: 34)
    }

    private var bubbleRect: CGRect {
        CGRect(x: position.x - Layout.width / 2, y: position.y + Layout.figure / 2,
               width: Layout.width, height: Layout.height - Layout.figure)
    }

    // MARK: - Movement helpers

    /// Flies to a point. Returns false if the flight was interrupted (e.g. you grabbed him).
    @discardableResult
    func flyTo(_ point: CGPoint) async -> Bool {
        finishFlight(arrived: false)
        target = clamp(point)
        return await withCheckedContinuation { arrival = $0 }
    }

    private func finishFlight(arrived: Bool) {
        let continuation = arrival
        arrival = nil
        continuation?.resume(returning: arrived)
    }

    private func setTarget(_ point: CGPoint) {
        finishFlight(arrived: false)
        target = clamp(point)
    }

    /// Keeps him fully on screen (below the menu bar), on whichever screen is closest to the point.
    private func clamp(_ p: CGPoint) -> CGPoint {
        let screen = Self.screen(nearest: p)
        let f = screen.frame
        let top = screen.visibleFrame.maxY - Self.headroom
        return CGPoint(x: min(max(p.x, f.minX + 50), f.maxX - 50),
                       y: min(max(p.y, f.minY + 40), top))
    }

    /// How far his head sticks up above his center.
    private static let headroom: CGFloat = 80

    private static func screen(nearest p: CGPoint) -> NSScreen {
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(p) }) { return hit }
        func distance(_ s: NSScreen) -> CGFloat {
            let f = s.frame
            let dx = max(f.minX - p.x, 0, p.x - f.maxX)
            let dy = max(f.minY - p.y, 0, p.y - f.maxY)
            return hypot(dx, dy)
        }
        return NSScreen.screens.min(by: { distance($0) < distance($1) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func randomPoint() -> CGPoint {
        let screen = NSScreen.screens.randomElement() ?? NSScreen.screens[0]
        let f = screen.visibleFrame.insetBy(dx: 120, dy: 120)
        guard f.width > 0, f.height > 0 else { return CGPoint(x: screen.frame.midX, y: screen.frame.midY) }
        return CGPoint(x: .random(in: f.minX...f.maxX), y: .random(in: f.minY...f.maxY))
    }

    /// Floats just above the window's top edge so his smoke tail rests on it.
    /// Nil when the window reaches the top of the screen and there's no room above it.
    private func perchPoint(on frame: CGRect, fraction: CGFloat) -> CGPoint? {
        let spot = CGPoint(x: frame.minX + frame.width * fraction, y: frame.maxY + 76)
        let screen = Self.screen(nearest: CGPoint(x: spot.x, y: frame.maxY - 1))
        return spot.y + Self.headroom <= screen.visibleFrame.maxY ? spot : nil
    }

    private var mainVisibleFrame: CGRect { (NSScreen.main ?? NSScreen.screens[0]).visibleFrame }

    private var sleepSpot: CGPoint {
        CGPoint(x: mainVisibleFrame.maxX - 130, y: mainVisibleFrame.minY + 60)
    }

    private var focusSpot: CGPoint {
        CGPoint(x: mainVisibleFrame.maxX - 140, y: mainVisibleFrame.minY + 110)
    }

    /// Fallback tap spot when we can't find the app's Dock icon.
    var defaultTapSpot: CGPoint {
        CGPoint(x: mainVisibleFrame.midX, y: mainVisibleFrame.minY + 10)
    }

    // MARK: - Behaviors

    private func decide() {
        nextDecision = Date().addingTimeInterval(.random(in: 7...15))
        let roll = Double.random(in: 0..<1)
        if roll < 0.35 {
            activity = .wandering
            setTarget(randomPoint())
        } else if roll < 0.75, perchOnWindow() {
            // Perched on top of a window.
        } else if roll < 0.88 {
            followCursor(seconds: 5)
        } else {
            activity = .idle // Just hang out and look around.
        }
    }

    @discardableResult
    private func perchOnWindow() -> Bool {
        let fraction = CGFloat.random(in: 0.15...0.85)
        // Only windows with room above them (full-height windows would push him off the top).
        let options = MacActions.windows().prefix(3).filter { perchPoint(on: $0.frame, fraction: fraction) != nil }
        guard let first = options.first else { return false }
        let chosen = Double.random(in: 0..<1) < 0.6 ? first : (options.randomElement() ?? first)
        guard let spot = perchPoint(on: chosen.frame, fraction: fraction) else { return false }
        activity = .perching(window: chosen.id, fraction: fraction)
        setTarget(spot)
        return true
    }

    func followCursor(seconds: Double) {
        wakeQuietly()
        finishFlight(arrived: false)
        activity = .following(until: Date().addingTimeInterval(seconds))
    }

    func toggleNap() {
        if case .sleeping = activity { wake() } else { goToSleep() }
    }

    func nap() { goToSleep() }

    private func goToSleep() {
        guard focusEnd == nil else { return }
        activity = .busy
        say("Yawn… nap time 💤", seconds: 3)
        Task {
            let arrived = await flyTo(sleepSpot)
            if arrived, case .busy = activity { activity = .sleeping }
        }
    }

    private func wake() {
        wakeQuietly()
        setPose(.happy, for: 1.2)
        say(["Mmm? Oh, hi! ✨", "I'm up, I'm up!", "Did someone make a wish?"].randomElement()!)
    }

    private func wakeQuietly() {
        if case .sleeping = activity {
            activity = .idle
            hoverStart = nil
            nextDecision = Date().addingTimeInterval(6)
        }
    }

    /// Flies over to a point and taps it with his hand (e.g. a Dock icon).
    func performTap(at point: CGPoint) async {
        wakeQuietly()
        activity = .busy
        let spot = CGPoint(x: point.x - Layout.handOffset.x, y: point.y - Layout.handOffset.y)
        let arrived = await flyTo(spot)
        if arrived {
            facing = 1
            setPose(.tapping, for: 0.45)
            try? await Task.sleep(for: .milliseconds(450))
        }
        if case .busy = activity { settle() }
    }

    /// Goes back to whatever makes sense after a task.
    private func settle() {
        activity = .idle
        nextDecision = Date().addingTimeInterval(6)
        if let perch = chatPerch {
            Task { await flyTo(perch) }
        } else if focusEnd != nil {
            Task { await flyTo(focusSpot) }
        }
    }

    // MARK: - The lamp

    /// Rubbing = moving the mouse back and forth over the lamp (no click needed).
    private func updateRubbing(mouse: CGPoint) {
        guard lampState == .waiting else { return }
        let dt = 1.0 / 60.0
        guard lampRect.insetBy(dx: -10, dy: -10).contains(mouse) else {
            lastRubX = nil
            if lampRub > 0 { lampRub = max(0, lampRub - dt * 0.12) }
            return
        }
        defer { lastRubX = mouse.x }
        guard let last = lastRubX else { return }
        let dx = mouse.x - last
        guard abs(dx) > 0.5 else {
            if lampRub > 0 { lampRub = max(0, lampRub - dt * 0.05) }
            return
        }
        let direction: CGFloat = dx > 0 ? 1 : -1
        rubTravel += abs(dx)
        if direction != rubDirection {
            // A back-and-forth stroke counts much more than just passing over.
            if rubTravel > 14, rubDirection != 0 { lampRub = min(1, lampRub + 0.09) }
            rubDirection = direction
            rubTravel = 0
        } else {
            lampRub = min(1, lampRub + Double(abs(dx)) / 2500)
        }
        if lampRub >= 1 { emergeFromLamp() }
    }

    func lampTapped() {
        say(["Psst… rub the lamp! ✨", "Rub rub rub! Back and forth!", "Let me ouuut… rub the lamp 🪔"].randomElement()!, seconds: 3)
    }

    private func emergeFromLamp() {
        guard lampState == .waiting else { return }
        let start = Date().timeIntervalSinceReferenceDate
        lampState = .emerging(start)
        activity = .busy
        NSSound(named: "Purr")?.play()
        Task {
            try? await Task.sleep(for: .seconds(Self.emergeSeconds))
            lampState = .none
            lampRub = 0
            setPose(.happy, for: 2)
            activity = .busy
            await flyTo(CGPoint(x: position.x - 120, y: position.y + 170))
            if case .busy = activity { activity = .idle }
            nextDecision = Date().addingTimeInterval(6)
            say(["POOF! ✨ Your genie is here! Press ⌥Space or click me to make a wish.",
                 "Ahh, 10,000 years in there gives you such a crick in the neck! What's your wish? ✨",
                 "You rang? ✨ Press ⌥Space or click me to make a wish."].randomElement()!)
        }
    }

    static let emergeSeconds = 2.2

    /// Flies back to the corner and hops into the lamp until you rub it again.
    func returnToLamp() {
        guard lampState == .none else { return }
        stopFocus(completed: false)
        wakeQuietly()
        activity = .busy
        say("Back to my lamp! Rub it when you need me ✨", seconds: 3)
        Task {
            await flyTo(Self.lampSpot)
            position = Self.lampSpot
            lampRub = 0
            lastRubX = nil
            lampState = .waiting
            activity = .inLamp
        }
    }

    // MARK: - Focus timer

    func startFocus(minutes: Int) {
        let minutes = max(1, min(180, minutes))
        wakeQuietly()
        if case .busy = activity {} else { activity = .idle }
        focusEnd = Date().addingTimeInterval(Double(minutes) * 60)
        focusRemaining = minutes * 60
        say("Focus mode! I'll read quietly for \(minutes) min 📚")
        if chatPerch == nil { Task { await flyTo(focusSpot) } }
    }

    func stopFocus(completed: Bool) {
        guard focusEnd != nil else { return }
        focusEnd = nil
        focusRemaining = nil
        nextDecision = Date().addingTimeInterval(8)
        if completed {
            NSSound(named: "Glass")?.play()
            say("Time's up! Stand up and stretch for 5 minutes ✨", seconds: 10)
        } else {
            say("Focus timer stopped.")
        }
    }

    // MARK: - Chat

    func chatVisibilityChanged(_ visible: Bool, barFrame: CGRect) {
        isChatOpen = visible
        if visible {
            wakeQuietly()
            let perch = CGPoint(x: barFrame.minX + 70, y: barFrame.maxY + 66)
            chatPerch = perch
            if case .busy = activity { return }
            activity = .idle
            Task { await flyTo(perch) }
        } else {
            chatPerch = nil
            nextDecision = Date().addingTimeInterval(3)
            if focusEnd != nil, !isBusy { Task { await flyTo(focusSpot) } }
        }
    }

    private var isBusy: Bool {
        if case .busy = activity { return true }
        return false
    }

    func beginThinking() {
        wakeQuietly()
        isThinking = true
    }

    func endThinking() { isThinking = false }

    // MARK: - Speech bubble

    func say(_ text: String, seconds: Double? = nil) {
        guard question == nil else { return } // Don't cover up a yes/no question.
        let token = UUID()
        bubbleToken = token
        bubble = Bubble(text: text)
        if pose != .sleeping { setPose(.talking, for: 1.6) }
        let duration = seconds ?? min(14, max(4, Double(text.count) / 14))
        Task {
            try? await Task.sleep(for: .seconds(duration))
            if bubbleToken == token { bubble = nil }
        }
    }

    /// Shows a Yes / No question in the bubble and waits for the answer (30s timeout = No).
    func ask(_ text: String) async -> Bool {
        answer(false)
        wakeQuietly()
        let token = UUID()
        questionToken = token
        bubbleToken = token
        bubble = Bubble(text: text, buttons: ["Yes", "No"])
        Task {
            try? await Task.sleep(for: .seconds(30))
            if questionToken == token { answer(false) }
        }
        return await withCheckedContinuation { question = $0 }
    }

    func answer(_ yes: Bool) {
        guard let continuation = question else { return }
        question = nil
        questionToken = UUID()
        bubble = nil
        continuation.resume(returning: yes)
    }

    func bubbleButtonTapped(_ index: Int) { answer(index == 0) }

    // MARK: - Poses

    func setPose(_ newPose: Pose?, for seconds: Double? = nil) {
        let token = UUID()
        poseToken = token
        poseOverride = newPose
        if let seconds {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if poseToken == token { poseOverride = nil }
            }
        }
    }

    // MARK: - Mouse

    func tapped() {
        if case .sleeping = activity { wake() } else { onTap?() }
    }

    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if case .dragging = activity {} else {
            finishFlight(arrived: false)
            target = nil
            velocity = .zero
            activity = .dragging
            dragOffset = CGPoint(x: mouse.x - position.x, y: mouse.y - position.y)
        }
        let newPosition = CGPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y)
        velocity = CGVector(dx: (newPosition.x - position.x) * 30, dy: (newPosition.y - position.y) * 30)
        position = newPosition
    }

    func dragEnded() {
        activity = .idle
        velocity = .zero
        nextDecision = Date().addingTimeInterval(10)
        if Bool.random() {
            say(["Wheee!", "Ooh, nice view from here ✨", "Careful, I'm magical!"].randomElement()!, seconds: 3)
        }
    }
}
