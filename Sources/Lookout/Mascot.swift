import AppKit
import LookoutCore
import SwiftUI

// Pixel mascots: one character per agent, one scene per status. Everything is drawn on a
// 16×16 grid with Core Graphics as a pure function of time, so a layer can redraw it without
// SwiftUI laying the window out again. Technique after CodeIsland's mascots (MIT).

enum MascotKind: CaseIterable {
    case claude, codex, gemini, opencode

    init(_ source: AgentSource) {
        self = switch source {
        case .claude: .claude
        case .codex: .codex
        case .gemini: .gemini
        case .opencode: .opencode
        }
    }
}

enum MascotScene: CaseIterable {
    case working, stalled, needsApproval, needsInput, finished, idle, ended

    init(_ session: AgentSession) {
        self = switch session.status {
        case .working: session.stalled ? .stalled : .working
        case .needsApproval: .needsApproval
        case .needsInput: .needsInput
        case .finished: .finished
        case .idle: .idle
        case .ended: .ended
        }
    }
}

private func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

private struct Look {
    let sprite: [String]          // body, 10 wide; its bottom row sits on y = 13
    let palette: [Character: CGColor]
    let eyeColor: CGColor
    let eyeY: CGFloat             // eyes at x 6 and 9
    let arm: [String]             // left arm, mirrored for the right
    let armColor: CGColor
    let armX: (CGFloat, CGFloat)  // left edge of each arm
    let armY: CGFloat
    var mouth = false             // a blinking cursor under the eyes
}

private let looks: [MascotKind: Look] = [
    // A round orange bean with an asterisk tuft.
    .claude: Look(
        sprite: ["....*.*...",
                 ".....*....",
                 "....*.*...",
                 "..OOOOOO..",
                 ".OOOOOOOO.",
                 "OOOOOOOOOO",
                 "OOOOOOOOOO",
                 "OOOOOOOOOO",
                 "OOOOOOOOOO",
                 "oOOOOOOOOo",
                 ".oOOOOOOo.",
                 "..oooooo.."],
        palette: ["O": rgb(0xD97757), "o": rgb(0xB85C3E), "*": rgb(0xF0A887)],
        eyeColor: rgb(0x2B1A14), eyeY: 8,
        arm: ["O", "O"], armColor: rgb(0xA94F33), armX: (2, 13), armY: 9),
    // A little robot with a screen for a face.
    .codex: Look(
        sprite: [".....A....",
                 ".....a....",
                 "..GGGGGG..",
                 ".GGGGGGGG.",
                 ".GDDDDDDG.",
                 ".GDDDDDDG.",
                 ".GDDDDDDG.",
                 ".GGGGGGGG.",
                 "..gGGGGg..",
                 "..GGGGGG..",
                 "..GGGGGG..",
                 "..gggggg.."],
        palette: ["G": rgb(0xB9C1CD), "g": rgb(0x8992A0), "D": rgb(0x1D2128), "A": rgb(0x5FE0B0), "a": rgb(0x8992A0)],
        eyeColor: rgb(0xE9FFF6), eyeY: 6,
        arm: ["G", "G"], armColor: rgb(0x77808E), armX: (4, 11), armY: 10),
    // A blue ghost under a twinkling sparkle (drawn as an overlay).
    .gemini: Look(
        sprite: ["...BBBB...",
                 ".BBBBBBBB.",
                 "BBBBBBBBBB",
                 "BBBBBBBBBB",
                 "BBBBBBBBBB",
                 "BBBBBBBBBB",
                 "bBBBBBBBBb",
                 "PPPPPPPPPP",
                 "PPPPPPPPPP",
                 "P.PP..PP.P"],
        palette: ["B": rgb(0x4F86F7), "b": rgb(0x5E7CF2), "P": rgb(0x8B6CF0)],
        eyeColor: rgb(0x10183A), eyeY: 8,
        arm: ["B", "B"], armColor: rgb(0x3559C9), armX: (2, 13), armY: 10),
    // A terminal window with curly braces for arms.
    .opencode: Look(
        sprite: [".KKKKKKKK.",
                 ".KKKKKKKK.",
                 ".KWWWWWWK.",
                 ".KWWWWWWK.",
                 ".KWWWWWWK.",
                 ".KWWWWWWK.",
                 ".KWWWWWWK.",
                 ".KWWWWWWK.",
                 ".KKKKKKKK."],
        palette: ["K": rgb(0x34302C), "W": rgb(0xF3F0EA)],
        eyeColor: rgb(0x34302C), eyeY: 8,
        arm: [".X", "X.", ".X"], armColor: rgb(0x9C958C), armX: (1, 13), armY: 8, mouth: true),
]

private let alert = rgb(0xFF7A1A)
private let keyboardBase = rgb(0x4A5361)
private let keyColor = rgb(0x8C96A5)

private func frac(_ x: Double) -> Double { x - floor(x) }
/// A short event that happens once per `cycle`, as 0…1…0 over `duration`.
private func beat(_ t: Double, cycle: Double, at start: Double, duration: Double) -> Bool {
    let p = frac(t / cycle) * cycle - start
    return p >= 0 && p < duration
}

enum Mascot {
    /// Draws one frame into `rect` of `ctx`. `t` is seconds; scenes loop.
    static func draw(_ kind: MascotKind, _ scene: MascotScene, t: Double, in ctx: CGContext, rect: CGRect) {
        guard let look = looks[kind] else { return }
        let unit = min(rect.width, rect.height) / 16
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.translateBy(x: rect.midX - unit * 8, y: rect.midY + unit * 8)
        ctx.scaleBy(x: unit, y: -unit) // grid units, y down

        var pen = Pen(ctx: ctx, grey: scene == .ended)
        var bodyDY: CGFloat = 0
        var arms: (CGFloat, CGFloat) = (0, 0) // vertical offset of each arm; negative is up
        var eyes = Eyes.open
        var keyboard = false
        var hits: (Bool, Bool) = (false, false)

        switch scene {
        case .working:
            keyboard = true
            let thinking = beat(t, cycle: 8, at: 5, duration: 1.3)
            bodyDY = thinking ? 0 : (frac(t * 2.5) < 0.5 ? 0 : 0.5)
            if thinking {
                eyes = .up
                arms = (-0.5, -0.5)
            } else {
                let left = frac(t * 4) < 0.5, right = frac(t * 4 + 0.35) < 0.5
                arms = (left ? 1 : 0, right ? 1 : 0)
                hits = (left, right)
                eyes = beat(t, cycle: 3.7, at: 1, duration: 0.15) ? .closed : .down
            }
        case .stalled:
            keyboard = true
            arms = (1, 1)
            eyes = .up
            bodyDY = frac(t / 3) < 0.5 ? 0 : 0.5
        case .needsApproval, .needsInput:
            let p = frac(t / 1.8)
            let jump: CGFloat = p < 0.12 ? -2 : p < 0.2 ? 0 : p < 0.3 ? -1 : 0
            bodyDY = jump
            arms = jump < 0 ? (-3, -3) : (frac(t * 3) < 0.5 ? (-2, 0) : (0, -2))
            eyes = .wide
        case .finished:
            let hop = beat(t, cycle: 3, at: 0, duration: 0.25)
            bodyDY = hop ? -1 : 0
            arms = frac(t * 1.5) < 0.5 ? (-3, -2) : (-2, -3)
            eyes = .happy
        case .idle:
            bodyDY = frac(t / 3.2) < 0.5 ? 0 : 0.5
            arms = (0.5, 0.5)
            eyes = .closed
        case .ended:
            bodyDY = 0.5
            arms = (0.5, 0.5)
            eyes = .closed
        }

        // Body
        let top = 14 - CGFloat(look.sprite.count) + bodyDY
        for (row, line) in look.sprite.enumerated() {
            for (col, ch) in line.enumerated() {
                guard let color = look.palette[ch] else { continue }
                pen.fill(3 + CGFloat(col), top + CGFloat(row), 1, 1, color)
            }
        }

        // Face
        let ey = look.eyeY + bodyDY
        for x in [CGFloat(6), 9] {
            switch eyes {
            case .open: pen.fill(x, ey, 1, 2, look.eyeColor)
            case .wide: pen.fill(x - 0.5, ey - 0.5, 1.5, 2.5, look.eyeColor)
            case .down: pen.fill(x, ey + 0.5, 1, 1.5, look.eyeColor)
            case .up: pen.fill(x, ey - 0.5, 1, 1.5, look.eyeColor)
            case .closed: pen.fill(x - 0.5, ey + 1, 1.5, 0.5, look.eyeColor)
            case .happy:
                pen.fill(x - 0.5, ey + 1, 0.5, 0.5, look.eyeColor)
                pen.fill(x, ey + 0.5, 0.5, 0.5, look.eyeColor)
                pen.fill(x + 0.5, ey + 1, 0.5, 0.5, look.eyeColor)
            }
        }
        if look.mouth, scene != .ended, frac(t * 1.25) < 0.5 || scene != .working {
            pen.fill(7, ey + 2.5, 2, 0.5, look.eyeColor)
        }

        // Arms, mirrored
        for (side, dy) in [(0, arms.0), (1, arms.1)] {
            let x0 = side == 0 ? look.armX.0 : look.armX.1
            for (row, line) in look.arm.enumerated() {
                let cells = side == 0 ? Array(line) : Array(line.reversed())
                for (col, ch) in cells.enumerated() where ch != "." {
                    pen.fill(x0 + CGFloat(col), look.armY + bodyDY + dy + CGFloat(row), 1, 1, look.armColor)
                }
            }
        }

        // Props
        if keyboard {
            pen.fill(1, 13, 14, 1.5, keyboardBase)
            for i in 0..<6 { pen.fill(2 + CGFloat(i) * 2, 13.5, 1.5, 0.5, keyColor) }
            if hits.0 { pen.fill(2 + CGFloat(Int(t * 4) % 3) * 2, 13.5, 1.5, 0.5, rgb(0xFFFFFF)) }
            if hits.1 { pen.fill(8 + CGFloat(Int(t * 4 + 1) % 3) * 2, 13.5, 1.5, 0.5, rgb(0xFFFFFF)) }
        }
        if kind == .gemini {
            let y: CGFloat = 1 + bodyDY + (frac(t / 2) < 0.5 ? 0 : 0.5)
            let twinkle = scene != .ended && frac(t / 1.6) < 0.5
            pen.fill(7.5, y, 1, 3, rgb(0xB9CCFF))
            pen.fill(6.5, y + 1, 3, 1, rgb(0xB9CCFF))
            if twinkle { pen.fill(7.5, y + 1, 1, 1, rgb(0xFFFFFF)) }
        }

        // Overlays
        switch scene {
        case .needsApproval:
            let y = 1 + min(0, bodyDY) * 0.5
            pen.fill(14, y, 1.5, 3, alert)
            pen.fill(14, y + 3.5, 1.5, 1.5, alert)
        case .needsInput:
            let y = 1 + min(0, bodyDY) * 0.5
            pen.fill(13, y, 3, 1, alert)
            pen.fill(15, y + 1, 1, 1, alert)
            pen.fill(14, y + 2, 1.5, 1, alert)
            pen.fill(14, y + 3.5, 1.5, 1, alert)
        case .finished:
            for (i, (x, y)) in [(1.0, 2.0), (13.0, 1.0), (14.0, 6.0)].enumerated() where frac(t / 1.2 + Double(i) / 3) < 0.5 {
                let c = rgb(0xF5B400)
                pen.fill(x, y + 0.5, 1.5, 0.5, c)
                pen.fill(x + 0.5, y, 0.5, 1.5, c)
            }
        case .idle:
            for i in 0..<2 {
                let p = frac(t / 2.6 + Double(i) / 2)
                let x = 12 + p * 2, y = 5 - p * 4
                pen.alpha = p < 0.75 ? 0.9 : (1 - p) * 3.6
                let c = rgb(0x9AA0AA)
                pen.fill(x, y, 2, 0.5, c)
                pen.fill(x + 1, y + 0.5, 0.5, 0.5, c)
                pen.fill(x + 0.5, y + 1, 0.5, 0.5, c)
                pen.fill(x, y + 1.5, 2, 0.5, c)
                pen.alpha = 1
            }
        case .stalled:
            let p = frac(t / 1.8)
            pen.alpha = p < 0.8 ? 1 : (1 - p) * 5
            pen.fill(13, 4 + p * 3, 1, 1.5, rgb(0x7CC4FF))
            pen.alpha = 1
        case .working, .ended:
            break
        }
        ctx.restoreGState()
    }

    private enum Eyes { case open, wide, down, up, closed, happy }

    private struct Pen {
        let ctx: CGContext
        let grey: Bool
        var alpha: CGFloat = 1

        func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: CGColor) {
            var color = color
            if grey, let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components {
                let l = 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
                color = CGColor(srgbRed: l, green: l, blue: l, alpha: 0.55)
            }
            ctx.setFillColor(color.copy(alpha: color.alpha * alpha) ?? color)
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }
    }
}

/// The agent's mascot acting out its status. A layer-backed view redraws it from a display link
/// at a pixel-art 12 fps; redrawing from SwiftUI every frame would lay the whole window out again.
struct MascotIcon: NSViewRepresentable {
    let kind: MascotKind
    let scene: MascotScene
    /// Shifts the loop so neighbouring rows don't move in step.
    var phase: Double = 0
    var animated = true

    func makeNSView(context: Context) -> MascotView { MascotView() }

    func updateNSView(_ view: MascotView, context: Context) {
        view.configure(kind: kind, scene: scene, phase: phase, animated: animated)
    }
}

final class MascotView: NSView {
    private var kind = MascotKind.claude
    private var scene = MascotScene.idle
    private var phase = 0.0
    private var animated = true
    private var link: CADisplayLink?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(kind: MascotKind, scene: MascotScene, phase: Double, animated: Bool) {
        guard kind != self.kind || scene != self.scene || phase != self.phase || animated != self.animated else { return }
        (self.kind, self.scene, self.phase, self.animated) = (kind, scene, phase, animated)
        updateLink()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    private func updateLink() {
        let wanted = animated && scene != .ended && window != nil
        if wanted, link == nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 12)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !wanted {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func tick() {
        if window?.occlusionState.contains(.visible) == true { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Whole device pixels per grid cell keep the art crisp; it may spill a point past the frame.
        let scale = window?.backingScaleFactor ?? 2
        let side = max(1, (min(bounds.width, bounds.height) * scale / 16).rounded()) * 16 / scale
        let origin = CGPoint(x: ((bounds.midX - side / 2) * scale).rounded() / scale,
                             y: ((bounds.midY - side / 2) * scale).rounded() / scale)
        let t = animated ? CACurrentMediaTime() + phase : 0
        Mascot.draw(kind, scene, t: t, in: ctx, rect: CGRect(origin: origin, size: CGSize(width: side, height: side)))
    }
}
