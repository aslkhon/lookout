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

struct RemoteMatchTests {
    let windows = [
        VSCodeRegistry.Window(pid: 79820, appRoot: "/a", remoteAuthority: "ssh-remote+unicon",
                              remoteFolders: ["vscode-remote://ssh-remote%2Bunicon/home/syncall/project"],
                              workspaceFile: nil, folders: [], terminals: [1289002, 1289050]),
        VSCodeRegistry.Window(pid: 79821, appRoot: "/a", workspaceFile: nil, folders: ["/p/syncall"], terminals: [1289050]),
    ]

    @Test func matchesRemoteTerminalOnSameHost() {
        let m = VSCodeRegistry.match(host: "unicon", ancestors: [1290000, 1289050, 1288000], windows: windows)
        #expect(m?.window.pid == 79820)
        #expect(m?.terminal == 1289050)
    }

    @Test func ignoresOtherHostsAndLocalWindows() {
        #expect(VSCodeRegistry.match(host: "deploy", ancestors: [1289050], windows: windows) == nil)
        // A local window must never claim a remote PID, and vice versa.
        #expect(VSCodeRegistry.match(ancestors: [1289002], windows: windows.filter { $0.remoteAuthority == nil }) == nil)
    }

    @Test func hostSpellings() {
        #expect(SSHHost.name("ssh://dev@127.0.0.1:2222") == "127.0.0.1")
        #expect(SSHHost.name("deploy@10.0.0.6") == "10.0.0.6")
        #expect(SSHHost.matches(authority: "ssh-remote+unicon", host: "unicon"))
        #expect(SSHHost.matches(authority: "ssh-remote%2Bunicon", host: "UNICON"))
        // {"hostName":"myserver"} hex-encoded, as VS Code writes for hosts with options.
        let hex = Data(#"{"hostName":"myserver"}"#.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(SSHHost.matches(authority: "ssh-remote+\(hex)", host: "myserver"))
        #expect(!SSHHost.matches(authority: "dev-container+abc", host: "abc"))
    }
}
