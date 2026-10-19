import Foundation
import Testing
@testable import LookoutCore

struct BarkTests {
    @Test func keyOrURL() throws {
        #expect(Bark("abc123")?.server == Bark.defaultServer)
        #expect(Bark("abc123")?.key == "abc123")
        #expect(Bark("  https://api.day.app/abc123/Sample%20title \n")?.key == "abc123")
        let own = try #require(Bark("http://bark.example.com:8080/k9"))
        #expect(own.server.absoluteString == "http://bark.example.com:8080")
        #expect(own.key == "k9")
        #expect(Bark("") == nil)
        #expect(Bark("https://api.day.app/") == nil)
        #expect(Bark("not/a key") == nil)
    }

    @Test func request() throws {
        let request = try #require(Bark("abc123")).request(title: "app needs approval", body: "Claude Code: Bash: npm test", urgent: true)
        #expect(request.url?.absoluteString == "https://api.day.app/push")
        #expect(request.httpMethod == "POST")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body == ["device_key": "abc123", "title": "app needs approval", "body": "Claude Code: Bash: npm test",
                         "group": "Lookout", "level": "timeSensitive"])
    }

    @Test func accepted() {
        #expect(Bark.accepted(Data(#"{"code":200,"message":"success"}"#.utf8), status: 200))
        #expect(!Bark.accepted(Data(#"{"code":400,"message":"failed to get device token"}"#.utf8), status: 400))
        #expect(!Bark.accepted(Data("<html>".utf8), status: 200))
    }
}
