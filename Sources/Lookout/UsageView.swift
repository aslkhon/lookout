import LookoutCore
import SwiftUI

/// Turns and agent time per project, from the turns Lookout has seen finish.
struct UsageView: View {
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

    @AppStorage("usagePeriod") private var period: Period = .week
    @State private var records: [TurnRecord] = []
    @State private var since: Date?

    var body: some View {
        let rows = TurnLog.byProject(records.filter { $0.end >= period.start })
        VStack(spacing: 0) {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
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
        .frame(width: 520, height: 420)
        .task {
            let all = await Task.detached { TurnLog.load(since: .distantPast) }.value
            since = all.first?.end
            records = all.filter { $0.end >= Period.month.start }
        }
    }
}
