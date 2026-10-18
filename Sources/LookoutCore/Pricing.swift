import Foundation

/// API list prices in USD per million tokens, to estimate what a session would cost on the API.
/// From platform.claude.com/docs/en/about-claude/pricing and developers.openai.com/api/docs/pricing
/// (October 2026). On a subscription nothing is billed per token; this is the API equivalent.
public struct Price: Equatable, Sendable {
    public var input: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double
    public var output: Double

    /// Tokens priced at this rate.
    public func cost(_ t: ModelTokens) -> Double {
        (Double(t.input) * input + Double(t.cacheWrite5m) * cacheWrite5m + Double(t.cacheWrite1h) * cacheWrite1h
            + Double(t.cacheRead) * cacheRead + Double(t.output) * output) / 1_000_000
    }
}

/// One model's tokens, with cache writes split by how long they're kept (they're priced differently).
public struct ModelTokens: Equatable, Sendable {
    public var input = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0
    public var output = 0

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead; self.output = output
    }

    public static func + (a: ModelTokens, b: ModelTokens) -> ModelTokens {
        ModelTokens(input: a.input + b.input, cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
                    cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h, cacheRead: a.cacheRead + b.cacheRead,
                    output: a.output + b.output)
    }

    var prompt: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
}

public enum Pricing {
    private static func p(_ input: Double, _ w5: Double, _ w1: Double, _ read: Double, _ output: Double) -> Price {
        Price(input: input, cacheWrite5m: w5, cacheWrite1h: w1, cacheRead: read, output: output)
    }

    /// Model id prefixes, most specific first. Claude ids look like `claude-opus-5-5` (maybe `[1m]`;
    /// the 1M context costs the same).
    private static let claude: [(String, Price)] = [
        ("claude-fable-5-1", p(10, 12.5, 20, 0.25, 50)),
        ("claude-mythos-5-1", p(10, 12.5, 20, 0.25, 50)),
        ("claude-fable-5", p(10, 12.5, 20, 1, 50)),
        ("claude-mythos-5", p(10, 12.5, 20, 1, 50)),
        ("claude-opus-5-5", p(4, 5, 8, 0.2, 20)),
        ("claude-opus-5", p(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4-8", p(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4-7", p(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4-6", p(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4-5", p(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4", p(15, 18.75, 30, 1.5, 75)),
        ("claude-sonnet-5-5", p(2, 2.5, 4, 0.1, 10)),
        ("claude-sonnet-5", p(2, 2.5, 4, 0.2, 10)),
        ("claude-sonnet-4", p(3, 3.75, 6, 0.3, 15)),
        ("claude-haiku-4-5", p(1, 1.25, 2, 0.1, 5)),
        ("claude-3-5-haiku", p(0.8, 1, 1.6, 0.08, 4)),
    ]
    /// Claude Haiku 5.5 is priced by prompt length: a request over 100K tokens pays the higher rates.
    private static let haiku55 = p(0.1, 0.125, 0.2, 0.01, 0.5)
    private static let haiku55Long = p(0.5, 0.625, 1, 0.05, 2.5)

    /// Codex records running totals, not requests, so its long-context rates (prompts over 272K) can't apply.
    private static let codex: [(String, Price)] = [
        ("gpt-6-astra", p(10, 10, 10, 1, 50)),
        ("gpt-6.1-sol", p(2, 2, 2, 0.1, 10)),
        ("gpt-6-sol", p(2, 2, 2, 0.2, 10)),
        ("gpt-6-luna", p(0.1, 0.1, 0.1, 0.01, 0.5)),
        ("gpt-5.3-codex", p(1.75, 1.75, 1.75, 0.175, 14)),
    ]

    /// The price of one request (Claude) or of a session's totals (Codex); nil for unknown models.
    public static func price(model: String, promptTokens: Int = 0) -> Price? {
        if model.hasPrefix("claude-haiku-5-5") { return promptTokens > 100_000 ? haiku55Long : haiku55 }
        let table = model.hasPrefix("claude") ? claude : codex
        return table.first { model.hasPrefix($0.0) }?.1
    }

    public static func cost(model: String, _ tokens: ModelTokens) -> Double? {
        price(model: model, promptTokens: tokens.prompt).map { $0.cost(tokens) }
    }

    /// "$0.42", "$12.30", "$1,204"; "<$0.01" for tiny amounts.
    public static func format(_ dollars: Double) -> String {
        if dollars < 0.01 { return "<$0.01" }
        if dollars < 1000 { return String(format: "$%.2f", dollars) }
        // Not through Int: counts from an ssh host aren't trusted and could overflow it.
        return "$" + dollars.formatted(.number.precision(.fractionLength(0)))
    }
}
