import AppKit
import LookoutCore
import SwiftUI

/// The floating mini window: the project grid in small, every agent a row you can click.
struct MiniView: View {
    @ObservedObject var model: AppModel
    var openDashboard: () -> Void
    var close: () -> Void

    var body: some View {
        let projects = Dictionary(grouping: model.sortedSessions.filter { $0.status != .ended }, by: \.projectName)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        let columns = projects.count > 2 ? 2 : 1
        VStack(alignment: .leading, spacing: 6) {
            titleBar
            HStack(alignment: .top, spacing: 6) {
                if projects.isEmpty {
                    Label("No agents", systemImage: "binoculars")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                ForEach(0..<columns, id: \.self) { column in
                    VStack(spacing: 6) {
                        ForEach(projects.indices.filter { $0 % columns == column }, id: \.self) { i in
                            MiniCard(name: projects[i].key, sessions: projects[i].value,
                                     focus: { model.focus($0) }, openDashboard: openDashboard)
                        }
                    }
                }
            }
        }
        .padding(8)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button("Back to the Full Window") { close(); openDashboard() }
            Button("Open Dashboard", action: openDashboard)
            Button("Close Mini Window", action: close)
        }
    }

    /// Always visible: the panel never becomes key, so it gets no hover events to reveal buttons with.
    private var titleBar: some View {
        HStack(spacing: 10) {
            Label("Lookout", systemImage: "binoculars").font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            Button { close(); openDashboard() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Back to the Full Window")
            Button(action: close) { Image(systemName: "xmark") }
                .help("Close Mini Window")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

/// A project card: its header, then a row per agent. Click a row to jump to that agent's terminal.
private struct MiniCard: View {
    let name: String
    let sessions: [AgentSession]
    let focus: (AgentSession) -> Void
    let openDashboard: () -> Void
    @AppStorage private var color: String

    init(name: String, sessions: [AgentSession], focus: @escaping (AgentSession) -> Void, openDashboard: @escaping () -> Void) {
        self.name = name; self.sessions = sessions; self.focus = focus; self.openDashboard = openDashboard
        _color = ProjectStyle.color(for: name)
    }

    var body: some View {
        let alert = sessions.contains(where: \.needsYou)
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ProjectIcon(project: name).font(.system(size: 12.5)).frame(width: 17)
                Text(name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if alert {
                    Text("Needs you")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: openDashboard)
            ForEach(sessions) { session in
                Divider().padding(.leading, 6)
                MiniRow(session: session)
                    .contentShape(Rectangle())
                    .onTapGesture { focus(session) }
                    .help("Click to jump to this agent's terminal")
            }
        }
        .padding(3)
        .frame(width: 203)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            CardOutline(shape: RoundedRectangle(cornerRadius: 8), color: ProjectStyle.color(named: color), alert: alert)
        }
    }
}

/// An agent in two small lines: its name, then its status and what it's doing.
private struct MiniRow: View {
    let session: AgentSession

    private var title: String { session.name ?? session.branch ?? session.source.displayName }

    var body: some View {
        HStack(spacing: 6) {
            StatusIcon(session: session, size: 15)
            AgentLogo(source: session.source, size: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                (Text(session.status.label).foregroundColor(session.status.color)
                 + Text(session.detail.map { " · \($0)" } ?? "").foregroundColor(.secondary))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Ticking { now in
                Text(Format.ago(session.statusSince, now: now))
                    .font(.system(size: 12, weight: session.needsYou ? .semibold : .regular))
                    .foregroundStyle(session.needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
    }
}

extension AppDelegate {
    /// UserDefaults key: the mini window is open, and reopens at launch.
    static let miniKey = "miniWindowShown"

    func toggleMini() {
        if miniPanel?.isVisible == true { closeMini() } else { showMini() }
    }

    func showMini() {
        if miniPanel == nil {
            // Non-activating: clicking a tile never pulls Lookout in front of the app you're working in.
            let panel = MiniPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: MiniView(
                model: AppModel.shared,
                openDashboard: { NSApp.activate(); AppDelegate.openDashboard?() },
                close: { [weak self] in self?.closeMini() }))
            hosting.sizingOptions = .preferredContentSize // the window follows the tiles
            panel.contentViewController = hosting
            panel.setContentSize(hosting.view.fittingSize)
            panel.restorePosition()
            miniPanel = panel
        }
        miniPanel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: Self.miniKey)
    }

    func closeMini() {
        miniPanel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Self.miniKey)
    }
}

/// Grows and shrinks from its top-left corner, and remembers where that corner was dragged.
/// (The window frame autosave restored it on the wrong spot with several screens.)
private final class MiniPanel: NSPanel {
    private static let topLeftKey = "miniWindowTopLeft"
    /// The top-left corner to keep while the content changes size.
    private var anchor: NSPoint?
    /// Not placed by the user yet: hug this screen's top-right corner as the width changes.
    private var defaultScreen: NSScreen?
    private var placing = false

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        let center = NotificationCenter.default
        // A resize keeps the bottom-left corner, so it doesn't post a move: put the top-left back.
        center.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let screen = self.defaultScreen { self.anchor = Self.topRight(of: screen, width: self.frame.width) }
                if let anchor = self.anchor { self.place(anchor) }
            }
        }
        center.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.placing { self.defaultScreen = nil } // dragged
                let topLeft = NSPoint(x: self.frame.minX, y: self.frame.maxY)
                self.anchor = topLeft
                UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.topLeftKey)
            }
        }
    }

    /// Where the user left it, if that's still on a screen; else the top-right of the menu bar's screen.
    func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: Self.topLeftKey).map(NSPointFromString),
           NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(saved) }) {
            anchor = saved
        } else if let screen = NSScreen.screens.first {
            defaultScreen = screen
            anchor = Self.topRight(of: screen, width: frame.width)
        }
        if let anchor { place(anchor) }
    }

    private func place(_ topLeft: NSPoint) {
        placing = true
        setFrameTopLeftPoint(topLeft)
        placing = false
    }

    private static func topRight(of screen: NSScreen, width: CGFloat) -> NSPoint {
        NSPoint(x: screen.visibleFrame.maxX - width - 20, y: screen.visibleFrame.maxY - 20)
    }
}
