import Charts
import LookoutCore
import SwiftUI

/// Tokens and estimated cost per day and agent, from the transcripts; then turns and agent time per
/// project, from the turns Lookout has seen finish.
struct UsageView: View {
    var limits: [(source: AgentSource, limits: [UsageLimit])]
    var close: () -> Void

    enum Period: String, CaseIterable {
        case today = "Today", week = "7 Days", month = "30 Days"

        var start: Date {
            let today = Calendar.current.startOfDay(for: .now)
            switch self {
            case .today: return today
            case .week: return Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today
            case .month: return Calendar.current.date(byAdding: .day, value: -29, to: today) ?? today
            }
        }
    }

    enum Metric: String, CaseIterable { case cost = "Cost", tokens = "Tokens" }

    @AppStorage("usagePeriod") private var period: Period = .week
    @AppStorage("usageMetric") private var metric: Metric = .cost
    @State private var records: [TurnRecord] = []
    @State private var since: Date?
    /// Nil while the transcripts are read.
    @State private var days: UsageHistory.Days?

    var body: some View {
        let rows = TurnLog.byProject(records.filter { $0.end >= period.start })
        VStack(spacing: 0) {
            if !limits.isEmpty {
                LimitsStrip(limits: limits)
                    .padding(.horizontal, 12).padding(.top, 12)
            }
            Picker("Period", selection: $period) {
                ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            daily
                .padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            Table(rows) {
                TableColumn("Project") { row in
                    HStack(spacing: 6) {
                        ProjectIcon(project: row.project).frame(width: 18)
                        Text(row.project)
                    }
                }
                TableColumn("Turns") { Text("\($0.turns)").monospacedDigit() }
                    .width(60)
                TableColumn("Agent Time") { Text(Format.duration($0.time)).monospacedDigit() }
                    .width(90)
                TableColumn("Avg Turn") { Text(Format.duration($0.averageTurn)).monospacedDigit() }
                    .width(80)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Finished Turns", systemImage: "chart.bar",
                                           description: Text("Turns are counted as agents finish them."))
                }
            }
            Divider()
            HStack {
                // Agent time is summed per agent: two agents working for an hour count two hours.
                Text(since.map { "Counted since \($0.formatted(date: .abbreviated, time: .omitted)) · agents working at once each count" }
                     ?? "Counted from now on")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 680)
        .task {
            let all = await Task.detached { TurnLog.load(since: .distantPast) }.value
            since = all.first?.end
            records = all.filter { $0.end >= Period.month.start }
        }
        .task {
            days = await Task.detached(priority: .utility) { UsageHistory.load(since: Period.month.start) }.value
        }
    }

    /// The chart covers a week even for Today, so today has something to compare with.
    private var chartDays: [Date] {
        let count = period == .month ? 30 : 7
        let today = Calendar.current.startOfDay(for: .now)
        return (0..<count).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }

    private struct Bar: Identifiable {
        var day: Date
        var source: AgentSource
        var usage: DayUsage
        var id: String { "\(day.timeIntervalSince1970)-\(source.rawValue)" }
    }

    private func total(from start: Date) -> DayUsage {
        let first = UsageHistory.dayString(start)
        return (days ?? [:]).filter { $0.key >= first }.values.flatMap(\.values).reduce(DayUsage(), +)
    }

    @ViewBuilder
    private var daily: some View {
        if let days {
            let bars = chartDays.flatMap { day in
                (days[UsageHistory.dayString(day)] ?? [:]).map { Bar(day: day, source: $0.key, usage: $0.value) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    summary("Today", total(from: Period.today.start))
                    if period != .today { summary(period.rawValue, total(from: period.start)) }
                    Spacer()
                    Picker("Show", selection: $metric) {
                        ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day),
                            y: .value(metric.rawValue, metric == .cost ? bar.usage.cost : Double(bar.usage.tokens)))
                        .foregroundStyle(by: .value("Agent", bar.source.displayName))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: period == .month ? 5 : 1)) {
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { Text(axisLabel(value.as(Double.self) ?? 0)) }
                    }
                }
                .chartForegroundStyleScale(domain: [AgentSource.claude.displayName, AgentSource.codex.displayName],
                                           range: [Color(red: 0.85, green: 0.47, blue: 0.34), Color.blue])
                .frame(height: 170)
                Text("Estimated at API list prices from Claude Code's and Codex's transcripts on this Mac; on a subscription nothing is billed per token.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading transcripts…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func summary(_ title: String, _ usage: DayUsage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Pricing.format(usage.cost)).font(.title3.weight(.semibold)).monospacedDigit()
                Text("\(TokenUsage.short(usage.tokens)) tokens").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .help(usage.unpriced > 0 ? "\(TokenUsage.short(usage.unpriced)) tokens of models without a known price aren't in the cost" : "")
    }

    private func axisLabel(_ value: Double) -> String {
        metric == .cost ? (value == 0 ? "$0" : "$" + value.formatted(.number.precision(.fractionLength(0)))) : TokenUsage.short(Int(value))
    }
}
