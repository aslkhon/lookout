import Foundation
import Testing
@testable import LookoutCore

struct VSCodeRegistryTests {
    let windows = [
        VSCodeRegistry.Window(pid: 79821, appRoot: "/a", workspaceFile: nil, folders: ["/p/syncall"], terminals: [79831, 79828]),
        VSCodeRegistry.Window(pid: 79823, appRoot: "/a", workspaceFile: nil, folders: ["/p/callsync", "/p/chatbot"], terminals: [79826, 79827]),
    ]

    @Test func matchesTerminalShellAncestor() {
        // claude (83902) → zsh (79826) → pty host → Code
        let m = VSCodeRegistry.match(ancestors: [83902, 79826, 79759, 79709], windows: windows)
        #expect(m?.window.pid == 79823)
        #expect(m?.terminal == 79826)
    }

    @Test func matchesAgentRunByExtensionHost() {
        let m = VSCodeRegistry.match(ancestors: [80497, 79821, 79709], windows: windows)
        #expect(m?.window.pid == 79821)
        #expect(m?.terminal == nil)
    }

    @Test func noMatchOutsideVSCode() {
        #expect(VSCodeRegistry.match(ancestors: [75246, 4000, 3999], windows: windows) == nil)
    }

    @Test func decodesExtensionOutput() throws {
        let json = #"{"pid":79824,"appRoot":"/Applications/Visual Studio Code.app/Contents/Resources/app","workspaceFile":null,"folders":["/p/analytics"],"terminals":[79830,79829]}"#
        let w = try JSONDecoder().decode(VSCodeRegistry.Window.self, from: Data(json.utf8))
        #expect(w.terminals == [79830, 79829] && w.workspaceFile == nil)
    }
}
