import Foundation

/// Phone alerts through the Bark iOS app: a push is one POST to the Bark server with the device key
/// the app shows. https://bark.day.app
public struct Bark: Equatable, Sendable {
    public static let defaultServer = URL(string: "https://api.day.app")!

    public var server: URL
    public var key: String

    /// The key on its own, or the URL the Bark app copies: `https://api.day.app/<key>` or the same
    /// on your own server, maybe followed by a sample title.
    public init?(_ setting: String) {
        let text = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.contains("://") else {
            guard !text.contains("/") else { return nil }
            server = Self.defaultServer
            key = text
            return
        }
        guard let url = URL(string: text), let scheme = url.scheme, let host = url.host,
              let key = url.path.split(separator: "/").first.map(String.init), !key.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = url.port
        guard let server = parts.url else { return nil }
        self.server = server
        self.key = key
    }

    /// `urgent` pushes break through Focus as time-sensitive ones.
    public func request(title: String, body: String, urgent: Bool) -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent("push"))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let payload: [String: Any] = ["device_key": key, "title": title, "body": body, "group": "Lookout",
                                      "level": urgent ? "timeSensitive" : "active"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        return request
    }

    /// Bark answers `{"code": 200, …}` when it took the push.
    public static func accepted(_ data: Data, status: Int) -> Bool {
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["code"] as? Int == 200
    }
}
