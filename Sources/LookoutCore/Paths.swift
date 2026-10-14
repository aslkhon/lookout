import Foundation

/// Filesystem locations shared by the app and the hook binary.
/// Kept free of spaces because agent CLIs pass hook commands through a shell.
public enum LookoutPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var root: URL { home.appendingPathComponent(".lookout") }
    public static var socket: URL { root.appendingPathComponent("lookout.sock") }
    public static var hookBinary: URL { root.appendingPathComponent("bin/lookout-hook") }
}
