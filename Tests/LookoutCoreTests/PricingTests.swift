import Foundation
import Testing
@testable import LookoutCore

struct PricingTests {
    func line(_ json: String) -> Data { Data(json.utf8) }

    @Test func claudeMessagesArePricedByModelAndCacheKind() {
        var usage = TokenUsage()
        var last: String?
        // Opus 5.5: $4 in, $5 5m write, $8 1h write, $0.20 read, $20 out per million.
        usage.add(line: line(#"{"type":"assistant","message":{"id":"a","model":"claude-opus-5-5","usage":{"input_tokens":1000000,"cache_creation_input_tokens":2000000,"cache_creation":{"ephemeral_1h_input_tokens":1000000,"ephemeral_5m_input_tokens":1000000},"cache_read_input_tokens":10000000,"output_tokens":100000}}}"#),
                  source: .claude, lastID: &last)
        #expect(abs((usage.cost ?? 0) - (4 + 5 + 8 + 2 + 2)) < 0.0001)
        #expect(usage.cacheWrite == 2_000_000)
        // A placeholder reply costs nothing; an unknown model makes the estimate unknown.
        usage.add(line: line(#"{"type":"assistant","message":{"id":"b","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#),
                  source: .claude, lastID: &last)
        #expect(usage.cost != nil)
        usage.add(line: line(#"{"type":"assistant","message":{"id":"c","model":"claude-future-9","usage":{"input_tokens":10,"output_tokens":1}}}"#),
                  source: .claude, lastID: &last)
        #expect(usage.cost == nil)
    }

    @Test func haikuLongPromptsCostMore() {
        let short = Pricing.cost(model: "claude-haiku-5-5", ModelTokens(input: 50_000, output: 1000))!
        let long = Pricing.cost(model: "claude-haiku-5-5", ModelTokens(input: 150_000, output: 1000))!
        #expect(abs(short - (0.005 + 0.0005)) < 1e-9)
        #expect(abs(long - (0.075 + 0.0025)) < 1e-9)
        #expect(Pricing.price(model: "claude-opus-5-5[1m]") == Pricing.price(model: "claude-opus-5-5"))
        #expect(Pricing.price(model: "claude-opus-4-1-20250805")?.input == 15)
    }

    @Test func codexIsPricedWithItsTurnModel() {
        var usage = TokenUsage()
        var last: String?
        usage.add(line: line(#"{"type":"turn_context","payload":{"model":"gpt-6-astra"}}"#), source: .codex, lastID: &last)
        usage.add(line: line(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1100000,"cached_input_tokens":1000000,"output_tokens":20000}}}}"#),
                  source: .codex, lastID: &last)
        // $10 × 0.1M + $1 × 1M + $50 × 0.02M
        #expect(abs((usage.cost ?? 0) - 3) < 0.0001)
    }

    @Test func remoteUsageIsPricedPerModel() {
        let output = Data(#"usage\#t{"input":1000000,"cache_read":0,"cache_write":0,"output":0,"models":{"claude-opus-5-5":[1000000,0,0,0,0],"claude-haiku-5-5@long":[1000000,0,0,0,0]}}"#.utf8)
        #expect(abs((Transcript.parseRemoteUsage(output)?.cost ?? 0) - 4.5) < 0.0001)
        let old = Data(#"usage\#t{"input":5,"cache_read":0,"cache_write":0,"output":1}"#.utf8)
        #expect(Transcript.parseRemoteUsage(old)?.cost == nil)
    }

    @Test func formatting() {
        #expect(Pricing.format(0.004) == "<$0.01")
        #expect(Pricing.format(12.3) == "$12.30")
    }
}
