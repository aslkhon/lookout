import Foundation
import Testing
@testable import LookoutCore

struct PermissionDecisionTests {
    @Test func hookOutput() {
        #expect(String(decoding: PermissionDecision.allow.hookOutput(), as: UTF8.self)
            == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(String(decoding: PermissionDecision.deny.hookOutput(), as: UTF8.self)
            == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from Lookout"},"hookEventName":"PermissionRequest"}}"#)
        let answer = PermissionDecision.answer(["Which color?": "Blue"])
            .hookOutput(toolInput: ["questions": [["question": "Which color?"]]])
        #expect(String(decoding: answer, as: UTF8.self)
            == #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"answers":{"Which color?":"Blue"},"questions":[{"question":"Which color?"}]}},"hookEventName":"PermissionRequest"}}"#)
    }

    @Test func wireRoundTrip() {
        for decision in [PermissionDecision.allow, .deny, .answer(["Q1?": "Red, Blue", "Q2?": "line\nbreak \"quoted\""])] {
            #expect(PermissionDecision(wire: decision.wire) == decision)
        }
        #expect(PermissionDecision(wire: "allowed") == nil)
        #expect(PermissionDecision(wire: "answer\n[1]") == nil)
        #expect(PermissionDecision(wire: "answer\n{\"q\":1}") == nil)
    }

    @Test func remoteRequestIDs() {
        #expect(PermissionDecision.isValidRequestID("0123456789abcdef0123456789abcdef"))
        #expect(!PermissionDecision.isValidRequestID("0123456789ABCDEF0123456789abcdef"))
        #expect(!PermissionDecision.isValidRequestID("0123456789abcdef0123456789abcde"))
        #expect(!PermissionDecision.isValidRequestID("../../.ssh/authorized_keys;rm -rf"))
        #expect(!PermissionDecision.isValidRequestID("0123456789abcdef0123456789abcde'"))
    }

    @Test func parsesQuestions() {
        let input: [String: JSONValue] = ["questions": .array([
            .object(["question": .string("Which color?"), "header": .string("Color"), "multiSelect": .bool(false),
                     "options": .array([.object(["label": .string("Red"), "description": .string("Warm")]),
                                        .object(["label": .string("Blue")]), .string("junk")])]),
            .object(["question": .string("Which toppings?"), "multiSelect": .bool(true)]),
            .object(["header": .string("no question")]),
        ])]
        #expect(AgentQuestion.parse(input) == [
            AgentQuestion(text: "Which color?", header: "Color",
                          options: [.init(label: "Red", description: "Warm"), .init(label: "Blue", description: nil)], multiSelect: false),
            AgentQuestion(text: "Which toppings?", header: nil, options: [], multiSelect: true),
        ])
        #expect(AgentQuestion.parse(nil).isEmpty)
    }
}
