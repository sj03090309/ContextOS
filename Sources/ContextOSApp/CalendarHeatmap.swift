import SwiftUI
import ContextOSCore

/// A month of AI token usage, laid out as a real calendar.
///
/// Deliberately not the GitHub year-strip: over a single month a weeks-as-columns
/// strip reads as an arbitrary 5×7 block, while a calendar grid people already
/// know how to read tells them *which Tuesday* was the heavy one.
struct MonthCalendarView: View {
    /// Any date inside the month to render.
    var month: Date
    /// local `yyyy-MM-dd` → tokens.
    var tokensByDay: [String: Int]
    var cellHeight: CGFloat = 15
    var spacing: CGFloat = 3
    var selected: String?
    var onSelect: ((String) -> Void)?

    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    var body: some View {
        // Laid out once per render rather than per cell: `levels` sorts the
        // month's values, and this view redraws whenever the dashboard ticks.
        let weeks = CalendarGrid.weeks(of: month)
        let levels = Self.levels(weeks: weeks, tokensByDay: tokensByDay)
        return VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: spacing) {
                ForEach(Self.weekdays, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks.indices, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(weeks[row].indices, id: \.self) { column in
                        cell(weeks[row][column], levels: levels)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: CalendarGrid.Day?, levels: [Int]) -> some View {
        if let day {
            let tokens = tokensByDay[day.key] ?? 0
            // A Button rather than a tappable shape with `.onTapGesture`: the
            // gesture never fired on these cells, and a button also gets
            // keyboard focus and VoiceOver for free.
            Button { onSelect?(day.key) } label: {
                swatch(day, tokens: tokens, levels: levels)
            }
            .buttonStyle(.plain)
            // The popover's calendar is read-only. `.disabled` would be the
            // obvious way to say so, but it greys the label out too and washes
            // the whole heatmap flat; this drops the interaction only.
            .allowsHitTesting(onSelect != nil)
            .help(tokens > 0 ? "\(day.key) · \(TokenEstimator.korean(tokens)) 토큰"
                             : "\(day.key) · 기록 없음")
        } else {
            // Padding for the days before the 1st and after the last.
            Color.clear.frame(height: cellHeight).frame(maxWidth: .infinity)
        }
    }

    private func swatch(_ day: CalendarGrid.Day, tokens: Int, levels: [Int]) -> some View {
        let isSelected = selected == day.key
        return RoundedRectangle(cornerRadius: 3)
            .fill(Self.color(for: tokens, in: levels))
            .frame(height: cellHeight)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isSelected ? Brand.accent : (day.isToday ? Color.secondary : .clear),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
            .overlay(
                Text("\(day.number)")
                    .font(.system(size: 8, weight: day.isToday ? .bold : .regular))
                    .foregroundStyle(tokens > 0 ? Brand.ink.opacity(0.75) : Color.secondary.opacity(0.7))
            )
            // The drawn shape leaves gaps between cells; without this the button
            // would only accept clicks that land on the swatch itself.
            .contentShape(Rectangle())
    }

    /// Quartile thresholds over the month's active days.
    ///
    /// Scaling against the maximum instead would let one outlier day — and token
    /// counts are wildly skewed — wash every other day out to the palest shade.
    static func levels(weeks: [[CalendarGrid.Day?]], tokensByDay: [String: Int]) -> [Int] {
        let keys = Set(weeks.flatMap { $0 }.compactMap { $0?.key })
        let active = tokensByDay.filter { keys.contains($0.key) && $0.value > 0 }
            .values.sorted()
        guard !active.isEmpty else { return [] }
        func quantile(_ q: Double) -> Int {
            active[min(active.count - 1, max(0, Int(Double(active.count - 1) * q)))]
        }
        return [quantile(0.25), quantile(0.5), quantile(0.75)]
    }

    static func color(for tokens: Int, in levels: [Int]) -> Color {
        guard tokens > 0, !levels.isEmpty else { return Color.secondary.opacity(0.12) }
        let step = levels.filter { tokens > $0 }.count      // 0...3
        return Brand.accent.opacity([0.3, 0.5, 0.75, 1.0][step])
    }
}
