import SwiftUI
#if canImport(ContextOSUsage)
import ContextOSUsage
#endif

public struct UsageWidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public var body: some View { scheme == .dark ? Color(white: 0.11) : Color.white }
}

/// Shared by WidgetKit and synthetic review. M means one million observed tokens.
public struct UsageWidgetView: View {
    public enum Size: String, CaseIterable { case small, medium, large }
    @Environment(\.colorScheme) private var scheme
    public let snapshot: WidgetUsageSnapshot
    public let size: Size
    public let now: Date
    public init(snapshot: WidgetUsageSnapshot, size: Size, now: Date = Date()) {
        self.snapshot = snapshot; self.size = size; self.now = now
    }
    private var ink: Color { scheme == .dark ? Color(white: 0.96) : Color(white: 0.11) }
    private var muted: Color { scheme == .dark ? Color(white: 0.69) : Color(white: 0.40) }
    private var accent: Color {
        scheme == .dark ? Color(red: 0.57, green: 0.72, blue: 1)
                        : Color(red: 0.14, green: 0.36, blue: 0.78)
    }
    private var old: Bool { snapshot.stale(at: now) }
    private var status: String {
        let value: String
        if old { value = "오래됨" }
        else if snapshot.providers.isEmpty { value = "연결 필요" }
        else if snapshot.providers.allSatisfy({ $0.state == .unsupported }) { value = "지원 안 됨" }
        else if snapshot.providers.contains(where: { $0.state == .unavailable }) {
            value = snapshot.today == nil ? "연결 끊김" : "일부 수집 불가"
        } else if snapshot.providers.contains(where: { $0.state == .partial }) { value = "일부 기록" }
        else { value = snapshot.today == nil ? "기록 없음" : "정상" }
        return snapshot.isSample ? (value == "정상" ? "합성 데이터" : "합성 · " + value) : value
    }
    private func millions(_ value: Int64?) -> String {
        guard let value else { return "—" }
        if value > 0 && value < 10_000 { return "<0.01M" }
        let scaled = Double(value) / 1_000_000
        if scaled >= 1_000_000 { return String(format: "%.1eM", scaled).replacingOccurrences(of: "e+", with: "e") }
        return String(format: "%.2fM", scaled)
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: size == .medium && snapshot.agents.count >= 3 ? 4 : 12) {
            switch size {
            case .small:
                if let metric = snapshot.smallMetric, metric != .tokens {
                    title(metric.label, branded: true)
                    Text(WidgetTimeSnapshot.duration(metric == .activity ? snapshot.timing?.activity?.estimatedNanoseconds : metric == .workTimer ? snapshot.timing?.manualNanoseconds : snapshot.timing?.foregroundNanoseconds))
                        .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    title(old ? "마지막 집계 토큰" : "오늘 토큰", branded: true)
                    number(snapshot.today, points: 36)
                }
            case .medium:
                title(old ? "AI 토큰 · 이전 집계" : "오늘 AI 토큰", branded: true)
                if snapshot.agents.isEmpty { empty }
                ForEach(Array(snapshot.agents.prefix(3).enumerated()), id: \.element.id) { index, rank in
                    comparison(rank, index: index)
                }
            case .large:
                VStack(alignment: .leading, spacing: 4) {
                    title("7일 토큰", branded: true)
                    number(snapshot.weekTotal, points: 38)
                }
                if snapshot.days.contains(where: { $0.tokens != nil }) { chart.padding(.top, 3) }
                title(old ? "AI 토큰 · 이전 집계" : "오늘 AI").padding(.top, 9)
                if snapshot.agents.isEmpty { empty }
                ForEach(snapshot.agents.prefix(3)) { rank in rankRow(rank, points: 15) }
            }
            Spacer(minLength: 0)
            footer
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .privacySensitive().accessibilityElement(children: .contain)
    }
    private func title(_ text: String, branded: Bool = false) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
            .lineLimit(1).minimumScaleFactor(0.9)
            .padding(.trailing, branded ? 24 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if branded {
                    MungchiWidgetMark().fill(ink.opacity(0.8), style: FillStyle(eoFill: true))
                        .frame(width: 20, height: 20).accessibilityHidden(true)
                }
            }
    }
    private func number(_ value: Int64?, points: CGFloat) -> some View {
        Text(millions(value)).font(.system(size: points, weight: .semibold))
            .tracking(-0.8).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            .accessibilityLabel(value.map { "\($0) 토큰" } ?? "사용 기록 없음")
    }
    private var empty: some View {
        Text("사용 기록 없음").font(.system(size: 14)).foregroundStyle(muted)
    }
    private func rankRow(_ rank: UsageRank, points: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(rank.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            number(rank.tokens, points: points).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank.name), \(rank.tokens) 토큰")
    }
    private func comparison(_ rank: UsageRank, index: Int) -> some View {
        let maximum = max(1, snapshot.agents.map(\.tokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            rankRow(rank, points: 16)
            GeometryReader { proxy in
                Capsule().fill(muted.opacity(0.12))
                Capsule().fill(index == 0 ? accent : muted.opacity(0.55))
                    .frame(width: proxy.size.width * Double(rank.tokens) / Double(maximum))
            }.frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank.name), \(rank.tokens) 토큰")
    }
    private var chart: some View {
        let maximum = max(1, snapshot.days.compactMap(\.tokens).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 14) {
            ForEach(snapshot.days) { day in
                VStack(spacing: 7) {
                    ZStack(alignment: .bottom) {
                        Color.clear
                        if let tokens = day.tokens {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(day.id == snapshot.days.last?.id ? accent : muted.opacity(0.25))
                                .frame(height: max(tokens > 0 ? 2 : 1, 62 * Double(tokens) / Double(maximum)))
                        } else { Text("·").font(.system(size: 12)).foregroundStyle(muted) }
                    }.frame(height: 62)
                    Text(day.date, format: Date.FormatStyle(date: .omitted, time: .omitted,
                        timeZone: TimeZone(identifier: snapshot.timeZoneID) ?? .gmt).day())
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.tokens.map { "\($0) 토큰" } ?? "기록 없음")")
            }
        }
    }
    private var footer: some View {
        if size == .small, let metric = snapshot.smallMetric, metric != .tokens {
            return AnyView(timeFooter(metric))
        }
        return AnyView(tokenFooter)
    }
    private func timeFooter(_ metric: SmallWidgetMetric) -> AnyView {
        let timing = snapshot.timing
        if metric == .activity {
            let activity = timing?.activity
            let label = activity.map { $0.stale(at: now) ? "이전 집계 · 추정" : $0.phase == .paused ? ($0.partial ? "정지 · 일부 누락" : "자동 일시정지") : $0.partial ? "일부 누락 · 추정" : "활동 추정 · 최근 집계" } ?? "확장 연결 필요"
            return AnyView(VStack(alignment: .leading, spacing: 3) {
                Text((timing?.isSample == true ? "합성 · " : "") + label).lineLimit(1).minimumScaleFactor(0.8)
                Text(activity?.generatedAt ?? snapshot.generatedAt, style: .time)
            }.font(.system(size: 10)).foregroundStyle(muted))
        }
        let state = metric == .workTimer ? timing?.manualState : timing?.foregroundState
        let stamp = timing?.generatedAt ?? snapshot.generatedAt
        let label = timing?.stale(at: now) == true ? "오래됨" : state == .running ? "최근 관측" : state?.label ?? "관측 안 됨"
        return AnyView(HStack(spacing: 4) {
            Text((timing?.isSample == true ? "합성 · " : "") + label).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            Text(stamp, format: .dateTime.hour().minute()).lineLimit(1).minimumScaleFactor(0.8)
        }.font(.system(size: 9)).foregroundStyle(muted))
    }
    private var tokenFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(status).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            Text(snapshot.generatedAt, format: old ? .dateTime.month().day().hour().minute() : .dateTime.hour().minute())
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.system(size: 9)).foregroundStyle(muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(status). 마지막 집계 \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)). M은 백만 토큰입니다.")
    }
}

/// Exact resting silhouette/eye geometry from the app's BlobShape in
/// ContextOSApp.swift. A static brand mark, never an inferred activity state.
private struct MungchiWidgetMark: Shape {
    func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 48 * rect.width, y: rect.minY + y / 48 * rect.height)
        }
        var p = Path()
        p.move(to: pt(24, 6))
        p.addCurve(to: pt(40, 26), control1: pt(34, 6), control2: pt(40, 14))
        p.addCurve(to: pt(24, 42), control1: pt(40, 38), control2: pt(33, 42))
        p.addCurve(to: pt(8, 26), control1: pt(15, 42), control2: pt(8, 38))
        p.addCurve(to: pt(24, 6), control1: pt(8, 14), control2: pt(14, 6))
        p.closeSubpath()
        let er: CGFloat = 3.1
        for x: CGFloat in [18, 30] {
            p.addEllipse(in: CGRect(origin: pt(x - er, 24 - er),
                size: CGSize(width: er / 24 * rect.width, height: er / 24 * rect.height)))
        }
        return p
    }
}
