import Foundation
import Testing
@testable import LookoutCore

struct PermissionDecisionTests {
    @Test func hookOutput() {
        #expect(String(decoding: PermissionDecision.allow.hookOutput, as: UTF8.self)
            == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(String(decoding: PermissionDecision.deny.hookOutput, as: UTF8.self)
            == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from Lookout"},"hookEventName":"PermissionRequest"}}"#)
        #expect(PermissionDecision(rawValue: "allow") == .allow && PermissionDecision(rawValue: "x") == nil)
    }

    @Test func remoteRequestIDs() {
        #expect(PermissionDecision.isValidRequestID("0123456789abcdef0123456789abcdef"))
        #expect(!PermissionDecision.isValidRequestID("0123456789ABCDEF0123456789abcdef"))
        #expect(!PermissionDecision.isValidRequestID("0123456789abcdef0123456789abcde"))
        #expect(!PermissionDecision.isValidRequestID("../../.ssh/authorized_keys;rm -rf"))
        #expect(!PermissionDecision.isValidRequestID("0123456789abcdef0123456789abcde'"))
    }
}
