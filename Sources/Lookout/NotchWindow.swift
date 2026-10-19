import AppKit
import LookoutCore
import SwiftUI

/// Experimental: Lookout in the notch. Folded, it's the notch plus two "ears": the most urgent
/// agent's status on the left, how many are active on the right. Hover, or an agent
/// newly needing you, unfolds it into plan limits and a row per agent. Screens without a notch get
/// a drawn one in the middle of the menu bar.
@MainActor
final class NotchState: ObservableObject {
    @Published var expanded = false
    /// You opened it (hover or ⌥⇧L) rather than it peeking on its own. Only then do ⌘Y and ⌘N
    /// answer, so a keystroke meant for another app can't approve something you haven't seen.
    @Published private(set) var openedByYou = false
    /// The notch's size on the chosen screen.
    @Published var notch = CGSize(width: 180, height: 24)
    /// The black shape, in the window's SwiftUI coordinates: only there does the window take clicks.
    var islandRect = CGRect.zero
    /// Each row's frame, same coordinates, to highlight the one under the mouse.
    var rowRects: [String: CGRect] = [:]
    @Published private(set) var hoveredRow: String?
    private(set) var hovering = false
    private var task: Task<Void, Never>?

    /// Opens a moment after the mouse arrives, so passing over the top of the screen doesn't.
    func hover(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside { change(to: true, after: .milliseconds(150), byYou: true) } else { change(to: false, after: .milliseconds(300)) }
    }

    /// `point` is in the window's SwiftUI coordinates, nil when the mouse is off the island.
    func mouse(at point: CGPoint?) {
        let row = point.flatMap { point in rowRects.first { $0.value.contains(point) }?.key }
        if row != hoveredRow { hoveredRow = row }
    }

    /// Unfolds for a few seconds to show what changed, or because you pressed ⌥⇧L.
    func peek(byYou: Bool = false) {
        task?.cancel()
        expanded = true
        if byYou { openedByYou = true }
        change(to: false, after: .seconds(4))
    }

    private func change(to open: Bool, after delay: Duration, byYou: Bool = false) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, open || !hovering else { return }
            expanded = open
            if !open { openedByYou = false } else if byYou { openedByYou = true }
        }
    }
}

struct NotchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    var openDashboard: () -> Void

    private static let ear: CGFloat = 34
    private static let width: CGFloat = 640
    /// Rows shown before "N more".
    private static let maxRows = 8

    var body: some View {
        // Idle agents aren't shown in the compact views.
        let live = model.sortedSessions.filter { $0.status != .ended && $0.status != .idle }
        let attention = model.attentionCount
        // The oldest approval Lookout can answer gets ⌘Y and ⌘N. Not questions, nor plans: those are
        // answered in the menu or the terminal.
        let target = live.filter(answerable).min { $0.statusSince < $1.statusSince }
        // An orange glow while ⌘Y and ⌘N go to Lookout rather than the app in front.
        let armed = state.expanded && state.openedByYou && target != nil
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: state.expanded ? 22 : 9,
                                           bottomTrailingRadius: state.expanded ? 22 : 9)
        VStack(spacing: 0) {
            if state.expanded {
                Group {
                    header
                    list(live, target: armed ? target?.id : nil)
                }
                .transition(.opacity)
            } else {
                ears(live, attention: attention)
                    .transition(.opacity)
            }
        }
        .frame(width: state.expanded ? Self.width : state.notch.width + 2 * Self.ear, alignment: .top)
        .background(.black)
        // While it grows, the content stays inside the shape.
        .clipShape(shape)
        // Cast by a shape that runs past the top of the screen, so it glows on three sides only.
        .background {
            if armed { shape.fill(.black).padding(.top, -40).shadow(color: .orange.opacity(0.6), radius: 12) }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.islandRect = $0 }
        .contextMenu { AppCommands() }
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: state.expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: attention) { old, new in
            if new > old { state.peek() }
        }
        .onChange(of: armed ? target?.id : nil, initial: true) { _, id in
            GlobalShortcut.shared.answer = id.flatMap { model.sessions[$0] }.flatMap(model.decider)
        }
        .onDisappear { GlobalShortcut.shared.answer = nil }
    }

    private func answerable(_ session: AgentSession) -> Bool {
        session.status == .needsApproval && model.decider(for: session) != nil
            && model.plan(for: session) == nil && model.questions(for: session).isEmpty
    }

    private func ears(_ live: [AgentSession], attention: Int) -> some View {
        // ZStacks, not Groups: an empty Group has no frame, and the ears would shift off-center.
        HStack(spacing: 0) {
            ZStack {
                if let first = live.first { StatusIcon(session: first, size: 14) }
            }
            .frame(width: Self.ear)
            Spacer().frame(width: state.notch.width)
            ZStack {
                // Working, waiting for you or just finished. Orange while any needs you.
                if !live.isEmpty {
                    Text("\(live.count)").foregroundStyle(attention > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            .frame(width: Self.ear)
        }
        .frame(height: state.notch.height)
    }

    /// Beside the notch: one agent's limits on each side, and Setup.
    private var header: some View {
        let limits = model.limits
        return HStack(spacing: 0) {
            HStack { if let first = limits.first { NotchLimits(entry: first) } }
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: state.notch.width)
            HStack(spacing: 12) {
                if limits.count > 1 { NotchLimits(entry: limits[1]) }
                Button { AppDelegate.shared?.showSetup() } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Setup")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 18)
        .frame(height: max(state.notch.height, 28))
    }

    private func list(_ live: [AgentSession], target: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if live.isEmpty {
                Text(model.sessions.isEmpty ? "No agents. Start Claude Code, Codex, Gemini CLI or OpenCode in any terminal." : "No active agents.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 14).padding(.horizontal, 8)
            }
            ForEach(live.prefix(Self.maxRows)) { session in
                NotchRow(session: session, decide: answerable(session) ? model.decider(for: session) : nil,
                         shortcuts: session.id == target)
                    .padding(.horizontal, 8)
                    .background(state.hoveredRow == session.id ? Color.white.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.rowRects[session.id] = $0 }
                    .onDisappear { state.rowRects[session.id] = nil }
                    .onTapGesture { model.focus(session) }
                    .help("Click to jump to this agent's terminal")
            }
            HStack {
                if live.count > Self.maxRows {
                    Button("\(live.count - Self.maxRows) more…", action: openDashboard)
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                ViewSwitcher(size: 11)
            }
            .padding(.top, 6).padding(.horizontal, 8)
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 14)
    }
}

/// "5h 26% 1h50m · 7d 68% 2d2h", the percentage colored by how close it is.
private struct NotchLimits: View {
    let entry: (source: AgentSource, limits: [UsageLimit])

    var body: some View {
        Ticking(interval: 60) { now in
            HStack(spacing: 6) {
                AgentLogo(source: entry.source, size: 12)
                ForEach(entry.limits.map { $0.current(now: now) }, id: \.windowMinutes) { limit in
                    let used = min(max(limit.usedPercent, 0), 100)
                    HStack(spacing: 3) {
                        Text(limit.name)
                        Text("\(Int(used.rounded()))%")
                            .foregroundStyle(used >= 90 ? .red : used >= 70 ? .orange : .green)
                        Text(Format.until(limit.resetsAt, now: now)).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }
            .help("\(entry.source.displayName) plan limits")
        }
    }
}

/// An agent that's busy, waiting or just finished, in two lines: its name, then what it's doing
/// or what it said.
private struct NotchRow: View {
    let session: AgentSession
    /// Allow and Deny, when Lookout holds this agent's approval.
    var decide: ((PermissionDecision) -> Void)?
    /// ⌘Y and ⌘N answer this one.
    var shortcuts = false

    private var title: String {
        [session.projectName, session.name ?? session.branch].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(session: session, size: 18).frame(width: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                activity.font(.system(size: 12)).lineLimit(2)
                if let decide {
                    HStack(spacing: 8) {
                        Button("Deny") { decide(.deny) }
                        Button("Allow") { decide(.allow) }.buttonStyle(.borderedProminent)
                        if shortcuts { ShortcutHint(text: "⌘Y · ⌘N") }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            tags
        }
        .padding(.vertical, 6)
    }

    /// The tool in color with what it acts on, else the status and its detail.
    private var activity: Text {
        if session.status == .working, let tool = session.tool {
            return Text(tool.name).foregroundColor(.blue).fontWeight(.medium)
                + Text(tool.argument.map { " \($0)" } ?? "").foregroundColor(.secondary)
        }
        return Text(session.statusLabel).foregroundColor(session.statusColor)
            + Text(session.statusDetail.map { " · \($0)" } ?? "").foregroundColor(.secondary)
    }

    private var tags: some View {
        HStack(spacing: 5) {
            tag(session.source.displayName, color: session.source == .claude ? .orange : .secondary)
            if let app = session.appName { tag(app, color: .secondary) }
            Ticking { now in tag(Format.ago(session.statusSince, now: now), color: .secondary) }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

extension AppDelegate {
    /// Shows the panel; `switchView` closes the other views.
    func showNotch() {
        if notchPanel == nil {
            let state = NotchState()
            let panel = NotchPanel(state: state)
            panel.contentViewController = NSHostingController(rootView: NotchView(
                model: AppModel.shared, state: state,
                openDashboard: { [weak self] in self?.switchView(to: .window) }))
            notchPanel = panel
        }
        notchPanel?.place()
        notchPanel?.orderFrontRegardless()
    }
}

/// A borderless panel over the menu bar, centered on the top edge of the screen with the notch.
/// It never changes size (the island grows and shrinks inside it, animated), and lets clicks
/// through everywhere but the island.
final class NotchPanel: NSPanel {
    private static let size = CGSize(width: 700, height: 600)
    private let state: NotchState
    private var monitors: [Any] = []

    init(state: NotchState) {
        self.state = state
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true // sets the level too, so it goes first
        level = .mainMenu + 3 // above the menu bar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // The panel never becomes key and mostly ignores the mouse, so follow it from outside:
        // other apps' moves globally, ours (once the island takes the mouse) locally.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.followMouse() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.followMouse() }
            return event
        }) { monitors.append(local) }
    }

    /// Takes the mouse only over the island, and opens or closes it.
    private func followMouse() {
        guard isVisible else { return }
        let island = state.islandRect
        // SwiftUI's coordinates start at the top-left; the screen's at the bottom-left.
        let rect = NSRect(x: frame.minX + island.minX, y: frame.maxY - island.maxY,
                          width: island.width, height: island.height + 1) // + the screen's top row
        let inside = rect.contains(NSEvent.mouseLocation)
        if ignoresMouseEvents == inside { ignoresMouseEvents = !inside }
        state.hover(inside)
        let mouse = NSEvent.mouseLocation
        state.mouse(at: inside && state.expanded ? CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y) : nil)
    }

    func peek(byYou: Bool = false) { state.peek(byYou: byYou) }

    /// The built-in screen if it has a notch, else the menu bar's screen.
    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    func place() {
        guard let screen = notchScreen else { return }
        let notch: CGSize
        if screen.safeAreaInsets.top > 0 {
            let sides = (screen.auxiliaryTopLeftArea?.width ?? 0) + (screen.auxiliaryTopRightArea?.width ?? 0)
            notch = CGSize(width: screen.frame.width - sides, height: screen.safeAreaInsets.top)
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notch = CGSize(width: 180, height: menuBar > 0 ? menuBar : 24)
        }
        if state.notch != notch { state.notch = notch }
        setFrame(NSRect(x: screen.frame.midX - Self.size.width / 2, y: screen.frame.maxY - Self.size.height,
                        width: Self.size.width, height: Self.size.height), display: true)
    }

    /// Allow the frame over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
