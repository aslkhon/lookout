import AppKit
import LookoutCore
import SwiftUI

/// The floating mini window: one small tile per project, with a status icon per agent.
struct MiniView: View {
    @ObservedObject var model: AppModel
    var openDashboard: () -> Void
    var close: () -> Void
    @State private var hovering = false

    var body: some View {
        let projects = Dictionary(grouping: model.sortedSessions.filter { $0.status != .ended }, by: \.projectName)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        VStack(alignment: .leading, spacing: 5) {
            if projects.isEmpty {
                Label("No agents", systemImage: "binoculars")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
            }
            ForEach(projects, id: \.key) { name, sessions in
                MiniTile(name: name, sessions: sessions, focus: { model.focus($0) })
                    .onTapGesture(count: 2, perform: openDashboard)
            }
        }
        .padding(8)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Mini Window")
                .padding(2)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open Dashboard", action: openDashboard)
            Button("Close Mini Window", action: close)
        }
    }
}

private struct MiniTile: View {
    let name: String
    let sessions: [AgentSession]
    let focus: (AgentSession) -> Void
    @AppStorage private var color: String

    init(name: String, sessions: [AgentSession], focus: @escaping (AgentSession) -> Void) {
        self.name = name; self.sessions = sessions; self.focus = focus
        _color = ProjectStyle.color(for: name)
    }

    var body: some View {
        HStack(spacing: 6) {
            ProjectIcon(project: name).font(.caption).frame(width: 16)
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
            Spacer(minLength: 6)
            HStack(spacing: 3) {
                ForEach(sessions) { session in
                    StatusIcon(session: session, size: 13)
                        .contentShape(Rectangle())
                        .onTapGesture { focus(session) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minWidth: 170, maxWidth: .infinity)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            CardOutline(shape: RoundedRectangle(cornerRadius: 8), color: ProjectStyle.color(named: color),
                        alert: sessions.contains(where: \.needsYou))
        }
        .help(name)
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

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { note in
            guard let panel = note.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: Self.topLeftKey)
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if frame.size != self.frame.size { frame.origin.y = self.frame.maxY - frame.height } // keep the top edge
        super.setFrame(frame, display: flag)
    }

    /// Where the user left it, if that's still on a screen; else the top-right corner of the main screen.
    func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: Self.topLeftKey).map(NSPointFromString),
           NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(saved) }) {
            setFrameTopLeftPoint(saved)
        } else if let screen = NSScreen.main {
            setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - frame.width - 20, y: screen.visibleFrame.maxY - 20))
        }
    }
}
