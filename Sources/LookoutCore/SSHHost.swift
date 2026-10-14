import Foundation

/// Comparing the different spellings of one ssh destination.
public enum SSHHost {
    /// "ssh://dev@example.com:2222" → "example.com"; "deploy@10.0.0.6" → "10.0.0.6"; "unicon" → "unicon".
    public static func name(_ destination: String) -> String {
        var s = destination
        if s.hasPrefix("ssh://") { s.removeFirst(6) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy(\.isNumber) {
            s = String(s[..<colon])
        }
        return s.lowercased()
    }

    /// Whether a VS Code remote authority ("ssh-remote+unicon", or "ssh-remote+7b22…" hex JSON
    /// for hosts with options) refers to `host`.
    public static func matches(authority: String, host: String) -> Bool {
        let decoded = authority.removingPercentEncoding ?? authority
        guard decoded.hasPrefix("ssh-remote+") else { return false }
        var target = String(decoded.dropFirst("ssh-remote+".count))
        if let data = hexDecoded(target),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hostName = json["hostName"] as? String {
            target = hostName
        }
        return name(target) == name(host)
    }

    private static func hexDecoded(_ s: String) -> Data? {
        guard s.count.isMultiple(of: 2), s.hasPrefix("7b") else { return nil } // "{"
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
