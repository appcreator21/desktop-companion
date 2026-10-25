import SwiftUI

/// Everything inside the genie's window: speech bubble on top, genie + focus timer below.
struct GenieRootView: View {
    @ObservedObject var brain: GenieBrain

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color.clear
                if let bubble = brain.bubble {
                    BubbleView(bubble: bubble) { brain.bubbleButtonTapped($0) }
                        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: Layout.width, height: Layout.height - Layout.figure)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: brain.bubble)

            ZStack(alignment: .bottom) {
                GenieFigure(pose: brain.pose, look: brain.look)
                    .frame(width: Layout.figure, height: Layout.figure)
                    .scaleEffect(x: brain.facing, y: 1)
                    .rotationEffect(.degrees(brain.lean))
                    .contentShape(Rectangle().inset(by: 30))
                    .onTapGesture { brain.tapped() }
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { _ in brain.dragChanged() }
                            .onEnded { _ in brain.dragEnded() }
                    )
                if let seconds = brain.focusRemaining {
                    TimerPill(seconds: seconds)
                        .padding(.bottom, 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: Layout.width, height: Layout.figure)
        }
        .frame(width: Layout.width, height: Layout.height)
    }
}

struct BubbleView: View {
    let bubble: Bubble
    let onButton: (Int) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(bubble.text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(7)
                .fixedSize(horizontal: false, vertical: true)
            if !bubble.buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(bubble.buttons.enumerated()), id: \.offset) { index, title in
                        Button(title) { onButton(index) }
                            .controlSize(.small)
                            .keyboardShortcut(index == 0 ? .defaultAction : .cancelAction)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(.bottom, 4)
    }
}

/// The little countdown clock he naps next to during focus mode.
struct TimerPill: View {
    let seconds: Int

    var body: some View {
        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(red: 0.25, green: 0.2, blue: 0.15))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.97, green: 0.91, blue: 0.79)))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

/// The genie, drawn live every frame.
struct GenieFigure: View {
    var pose: Pose
    var look: CGPoint

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                GenieArt.draw(in: context, size: size, t: t, pose: pose, look: look)
            }
            .offset(y: pose == .sleeping ? sin(t * 1.2) * 1.5 : sin(t * 2.2) * 4)
        }
    }
}

/// Drawing code for the genie. Canvas is 170x170, y grows downward.
enum GenieArt {
    static let skinLight = Color(red: 0.38, green: 0.72, blue: 0.99)
    static let skinDark = Color(red: 0.13, green: 0.42, blue: 0.85)
    static let turban = Color(red: 0.56, green: 0.29, blue: 0.82)
    static let turbanDark = Color(red: 0.39, green: 0.17, blue: 0.64)
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.28)
    static let ruby = Color(red: 0.92, green: 0.18, blue: 0.35)
    static let ink = Color(red: 0.10, green: 0.10, blue: 0.22)
    static let bookPink = Color(red: 0.98, green: 0.72, blue: 0.80)

    static func draw(in context: GraphicsContext, size: CGSize, t: Double, pose: Pose, look: CGPoint) {
        var ctx = context
        ctx.addFilter(.shadow(color: .black.opacity(0.28), radius: 5, x: 0, y: 3))
        ctx.drawLayer { layer in
            let cx = size.width / 2
            let skin = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [skinLight, skinDark]),
                startPoint: CGPoint(x: cx - 30, y: 20), endPoint: CGPoint(x: cx + 35, y: 150))

            drawTail(layer, cx: cx, t: t, calm: pose == .sleeping || pose == .focusing)
            drawTorso(layer, cx: cx, skin: skin)
            drawArms(layer, cx: cx, t: t, pose: pose, skin: skin)
            drawHead(layer, cx: cx, t: t, pose: pose, look: look, skin: skin)
        }
        // Effects drawn without the shadow.
        drawExtras(context, cx: size.width / 2, t: t, pose: pose)
    }

    // A wavy column of smoke puffs that gets thinner toward the tip.
    private static func drawTail(_ ctx: GraphicsContext, cx: CGFloat, t: Double, calm: Bool) {
        let speed = calm ? 1.2 : 3.2
        for i in 0..<8 {
            let f = CGFloat(i)
            let r = max(3.5, 21 - f * 2.4)
            let x = cx + CGFloat(sin(t * speed + Double(i) * 0.8)) * f * 1.4 + f * 1.6
            let y = 104 + f * 8
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            let alpha = 1.0 - Double(i) * 0.07
            ctx.fill(Path(ellipseIn: rect), with: .linearGradient(
                Gradient(colors: [skinLight.opacity(alpha), skinDark.opacity(alpha)]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        }
    }

    private static func drawTorso(_ ctx: GraphicsContext, cx: CGFloat, skin: GraphicsContext.Shading) {
        let torso = Path(roundedRect: CGRect(x: cx - 24, y: 72, width: 48, height: 40), cornerRadius: 18)
        ctx.fill(torso, with: skin)

        // Little purple vest.
        var left = Path()
        left.move(to: CGPoint(x: cx - 23, y: 80))
        left.addLine(to: CGPoint(x: cx - 9, y: 78))
        left.addLine(to: CGPoint(x: cx - 13, y: 104))
        left.addLine(to: CGPoint(x: cx - 23, y: 104))
        left.closeSubpath()
        var right = Path()
        right.move(to: CGPoint(x: cx + 23, y: 80))
        right.addLine(to: CGPoint(x: cx + 9, y: 78))
        right.addLine(to: CGPoint(x: cx + 13, y: 104))
        right.addLine(to: CGPoint(x: cx + 23, y: 104))
        right.closeSubpath()
        ctx.fill(left, with: .color(turban))
        ctx.fill(right, with: .color(turban))

        // Gold belt.
        ctx.fill(Path(roundedRect: CGRect(x: cx - 25, y: 102, width: 50, height: 8), cornerRadius: 4),
                 with: .color(gold))

        // Shoulders.
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 35, y: 71, width: 20, height: 20)), with: skin)
        ctx.fill(Path(ellipseIn: CGRect(x: cx + 15, y: 71, width: 20, height: 20)), with: skin)
    }

    private static func drawArms(_ ctx: GraphicsContext, cx: CGFloat, t: Double, pose: Pose,
                                 skin: GraphicsContext.Shading) {
        let armStyle = StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)

        func arm(_ points: [CGPoint]) {
            var path = Path()
            path.addLines(points)
            ctx.stroke(path, with: skin, style: armStyle)
            if let hand = points.last {
                ctx.fill(Path(ellipseIn: CGRect(x: hand.x - 6.5, y: hand.y - 6.5, width: 13, height: 13)), with: skin)
            }
        }
        func cuff(at p: CGPoint) {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11)), with: .color(gold))
        }
        let leftShoulder = CGPoint(x: cx - 25, y: 81)
        let rightShoulder = CGPoint(x: cx + 25, y: 81)
        let leftHip = [leftShoulder, CGPoint(x: cx - 35, y: 95), CGPoint(x: cx - 24, y: 104)]

        switch pose {
        case .tapping:
            arm(leftHip)
            cuff(at: CGPoint(x: cx - 33, y: 97))
            arm([rightShoulder, CGPoint(x: cx + 50, y: 118)])
            cuff(at: CGPoint(x: cx + 43, y: 108))

        case .talking, .happy:
            let wave = CGFloat(sin(t * 10)) * 5
            arm(leftHip)
            cuff(at: CGPoint(x: cx - 33, y: 97))
            arm([rightShoulder, CGPoint(x: cx + 42, y: 60), CGPoint(x: cx + 44 + wave, y: 46)])
            cuff(at: CGPoint(x: cx + 42, y: 58))

        case .thinking:
            arm(leftHip)
            cuff(at: CGPoint(x: cx - 33, y: 97))
            arm([rightShoulder, CGPoint(x: cx + 22, y: 96), CGPoint(x: cx + 9, y: 79)])
            cuff(at: CGPoint(x: cx + 17, y: 90))

        case .focusing:
            // Holding an open pink book.
            arm([leftShoulder, CGPoint(x: cx - 24, y: 98), CGPoint(x: cx - 18, y: 100)])
            arm([rightShoulder, CGPoint(x: cx + 24, y: 98), CGPoint(x: cx + 18, y: 100)])
            let leftPage = Path(roundedRect: CGRect(x: cx - 22, y: 86, width: 22, height: 24), cornerRadius: 3)
            let rightPage = Path(roundedRect: CGRect(x: cx, y: 86, width: 22, height: 24), cornerRadius: 3)
            ctx.fill(leftPage, with: .color(bookPink))
            ctx.fill(rightPage, with: .color(bookPink.opacity(0.85)))
            for i in 0..<4 {
                let y = 91 + CGFloat(i) * 4.5
                var lines = Path()
                lines.move(to: CGPoint(x: cx - 18, y: y)); lines.addLine(to: CGPoint(x: cx - 4, y: y))
                lines.move(to: CGPoint(x: cx + 4, y: y)); lines.addLine(to: CGPoint(x: cx + 18, y: y))
                ctx.stroke(lines, with: .color(ink.opacity(0.25)), lineWidth: 1)
            }

        case .idle, .flying, .sleeping:
            // Arms crossed, classic genie style.
            let crossed = Path(roundedRect: CGRect(x: cx - 28, y: 85, width: 56, height: 13), cornerRadius: 6.5)
            ctx.fill(crossed, with: skin)
            ctx.stroke(crossed, with: .color(ink.opacity(0.18)), lineWidth: 1)
            cuff(at: CGPoint(x: cx - 18, y: 91.5))
            cuff(at: CGPoint(x: cx + 18, y: 91.5))
        }
    }

    private static func drawHead(_ ctx: GraphicsContext, cx: CGFloat, t: Double, pose: Pose, look: CGPoint,
                                 skin: GraphicsContext.Shading) {
        // Ears + gold earring.
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 29, y: 47, width: 10, height: 14)), with: skin)
        ctx.fill(Path(ellipseIn: CGRect(x: cx + 19, y: 47, width: 10, height: 14)), with: skin)
        ctx.stroke(Path(ellipseIn: CGRect(x: cx - 28, y: 59, width: 7, height: 7)), with: .color(gold), lineWidth: 2)

        // Head.
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 24, y: 28, width: 48, height: 50)), with: skin)

        // Turban with a ruby.
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 7, y: 9, width: 14, height: 14)), with: .color(turban))
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 27, y: 19, width: 54, height: 26)), with: .color(turban))
        var fold = Path()
        fold.move(to: CGPoint(x: cx - 24, y: 36))
        fold.addQuadCurve(to: CGPoint(x: cx + 24, y: 30), control: CGPoint(x: cx, y: 24))
        ctx.stroke(fold, with: .color(turbanDark), lineWidth: 2)
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 5.5, y: 30, width: 11, height: 11)), with: .color(gold))
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 3, y: 32.5, width: 6, height: 6)), with: .color(ruby))

        // Eyes.
        let blink = fmod(t + 0.3, 4.3) < 0.13
        let eyesClosed = pose == .sleeping || blink
        let leftEye = CGPoint(x: cx - 9, y: 53)
        let rightEye = CGPoint(x: cx + 9, y: 53)
        for eye in [leftEye, rightEye] {
            if eyesClosed {
                var lid = Path()
                lid.move(to: CGPoint(x: eye.x - 4.5, y: eye.y))
                lid.addQuadCurve(to: CGPoint(x: eye.x + 4.5, y: eye.y), control: CGPoint(x: eye.x, y: eye.y + 3.5))
                ctx.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: eye.x - 5, y: eye.y - 6, width: 10, height: 12)), with: .color(.white))
                var lookAt = look
                if pose == .thinking { lookAt = CGPoint(x: 0.6, y: -0.9) }
                if pose == .focusing { lookAt = CGPoint(x: 0, y: 0.9) }
                let pupil = CGPoint(x: eye.x + lookAt.x * 2.4, y: eye.y + lookAt.y * 2.8)
                ctx.fill(Path(ellipseIn: CGRect(x: pupil.x - 2.8, y: pupil.y - 2.8, width: 5.6, height: 5.6)),
                         with: .color(ink))
                ctx.fill(Path(ellipseIn: CGRect(x: pupil.x - 1.6, y: pupil.y - 2.4, width: 1.8, height: 1.8)),
                         with: .color(.white))
            }
        }

        // Eyebrows (one raised while thinking).
        let browStyle = StrokeStyle(lineWidth: 2.6, lineCap: .round)
        var browL = Path()
        browL.move(to: CGPoint(x: cx - 14, y: 45.5))
        browL.addLine(to: CGPoint(x: cx - 5, y: 44))
        var browR = Path()
        let raise: CGFloat = pose == .thinking ? -3 : 0
        browR.move(to: CGPoint(x: cx + 5, y: 44 + raise))
        browR.addLine(to: CGPoint(x: cx + 14, y: 45.5 + raise))
        ctx.stroke(browL, with: .color(ink), style: browStyle)
        ctx.stroke(browR, with: .color(ink), style: browStyle)

        // Reading glasses in focus mode.
        if pose == .focusing {
            for eye in [leftEye, rightEye] {
                ctx.stroke(Path(ellipseIn: CGRect(x: eye.x - 7, y: eye.y - 7, width: 14, height: 14)),
                           with: .color(gold), lineWidth: 1.6)
            }
            var bridge = Path()
            bridge.move(to: CGPoint(x: cx - 2, y: 53))
            bridge.addLine(to: CGPoint(x: cx + 2, y: 53))
            ctx.stroke(bridge, with: .color(gold), lineWidth: 1.6)
        }

        // Nose.
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 3, y: 56, width: 6, height: 5)), with: .color(skinDark.opacity(0.55)))

        // Mouth.
        switch pose {
        case .sleeping:
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 2.5, y: 64, width: 5, height: 4)), with: .color(ink))
        case .talking:
            let open = 3 + abs(CGFloat(sin(t * 14))) * 4
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 5, y: 62, width: 10, height: open)), with: .color(ink))
        case .happy, .tapping:
            var grin = Path()
            grin.move(to: CGPoint(x: cx - 8, y: 62))
            grin.addQuadCurve(to: CGPoint(x: cx + 8, y: 62), control: CGPoint(x: cx, y: 73))
            grin.closeSubpath()
            ctx.fill(grin, with: .color(ink))
        default:
            var smile = Path()
            smile.move(to: CGPoint(x: cx - 7, y: 63))
            smile.addQuadCurve(to: CGPoint(x: cx + 7, y: 63), control: CGPoint(x: cx, y: 69))
            ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // Goatee.
        var goatee = Path()
        goatee.move(to: CGPoint(x: cx - 4, y: 75))
        goatee.addLine(to: CGPoint(x: cx + 4, y: 75))
        goatee.addLine(to: CGPoint(x: cx, y: 84))
        goatee.closeSubpath()
        ctx.fill(goatee, with: .color(ink))
    }

    private static func drawExtras(_ ctx: GraphicsContext, cx: CGFloat, t: Double, pose: Pose) {
        // Sparkles around the tail.
        for i in 0..<3 {
            let phase = t * 1.3 + Double(i) * 2.1
            let twinkle = (sin(phase * 2) + 1) / 2
            let p = CGPoint(x: cx + CGFloat(cos(phase)) * 30, y: 125 + CGFloat(sin(phase * 0.7)) * 22)
            ctx.fill(star(at: p, r: 3 + CGFloat(twinkle) * 2.5), with: .color(gold.opacity(0.35 + twinkle * 0.6)))
        }

        switch pose {
        case .sleeping:
            for i in 0..<3 {
                let phase = fmod(t * 0.45 + Double(i) / 3, 1)
                let point = CGPoint(x: cx + 30 + CGFloat(phase) * 16, y: 34 - CGFloat(phase) * 28)
                let text = Text("z")
                    .font(.system(size: 10 + CGFloat(phase) * 8, weight: .heavy, design: .rounded))
                    .foregroundColor(turban.opacity(1 - phase))
                ctx.draw(text, at: point)
            }
        case .thinking:
            for i in 0..<3 {
                let pulse = (sin(t * 5 - Double(i)) + 1) / 2
                let r = 2.2 + CGFloat(i) * 1.1
                let p = CGPoint(x: cx + 28 + CGFloat(i) * 8, y: 26 - CGFloat(i) * 6)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(0.6 + pulse * 0.4)))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                           with: .color(skinDark), lineWidth: 1)
            }
        default:
            break
        }
    }

    private static func star(at c: CGPoint, r: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
        return p
    }
}
