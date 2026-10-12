import SwiftUI
#if canImport(ContextOSUsage)
import ContextOSUsage
#endif

public struct UsageWidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public var body: some View {
        (scheme == .dark ? Color(red: 0.09, green: 0.135, blue: 0.12)
                        : Color(red: 0.95, green: 0.98, blue: 0.96))
    }
}

/// Identical content is used by the real WidgetKit extension and the explicitly
/// labelled, synthetic layout review. No live data is replaced by preview data.
public struct UsageWidgetView: View {
    public enum Size: String, CaseIterable { case small, medium, large }
    @Environment(\.colorScheme) private var scheme
    public let snapshot: WidgetUsageSnapshot
    public let size: Size
    public let now: Date
    public init(snapshot: WidgetUsageSnapshot, size: Size, now: Date = Date()) {
        self.snapshot = snapshot; self.size = size; self.now = now
    }
    private var green: Color {
        scheme == .dark ? Color(red: 0.48, green: 0.80, blue: 0.62) : Color(red: 0.17, green: 0.47, blue: 0.33)
    }
    private var ink: Color {
        scheme == .dark ? Color(red: 0.93, green: 0.97, blue: 0.94) : Color(red: 0.12, green: 0.22, blue: 0.17)
    }
    private var secondary: Color {
        scheme == .dark ? Color(red: 0.66, green: 0.76, blue: 0.70) : Color(red: 0.35, green: 0.44, blue: 0.39)
    }
    private var old: Bool { snapshot.stale(at: now) }
    private var health: String {
        if old { return "예전 기록 · 앱에서 갱신" }
        if snapshot.isSample { return "예시 데이터" }
        if snapshot.providers.isEmpty { return "앱 연결이 필요해요" }
        if snapshot.providers.allSatisfy({ $0.state == .unsupported }) { return "아직 지원하지 않는 AI예요" }
        if snapshot.providers.contains(where: { $0.state == .partial || $0.state == .unavailable }) { return "일부 AI 수집 불가" }
        return snapshot.today == nil ? "아직 사용 기록이 없어요" : "로컬 기록 연결됨"
    }
    private var comparison: String {
        snapshot.comparison.replacingOccurrences(of: "전일 전체 대비", with: "어제 하루 대비")
            .replacingOccurrences(of: "전일 비교 기록 없음", with: "어제 기록은 없어요")
            .replacingOccurrences(of: "전일과 동일", with: "어제와 같아요")
            .replacingOccurrences(of: "전일 0 · 오늘 기록 있음", with: "오늘 사용을 시작했어요")
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 5 : 10) {
            switch size {
            case .small: small
            case .medium: medium
            case .large: large
            }
            footer
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .privacySensitive()
        .accessibilityElement(children: .contain)
    }
    private func heading(_ title: String) -> some View {
        HStack(spacing: 7) {
            mascot
            Text(title).font(.system(size: 12, weight: .medium, design: .rounded))
            Spacer(minLength: 0)
            if snapshot.nearBudget {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .font(.system(size: 11)).accessibilityLabel("내 일일 예산 80% 이상")
            }
        }
    }
    private var mascot: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(green.opacity(scheme == .dark ? 0.23 : 0.14))
            HStack(spacing: 4) {
                Capsule().frame(width: 3, height: 6)
                Capsule().frame(width: 3, height: 6)
            }.foregroundStyle(green).offset(y: 1)
        }.frame(width: 24, height: 22).accessibilityHidden(true)
    }
    private var small: some View {
        Group {
            heading(old ? "마지막 사용 기록" : "오늘 쓴 토큰")
            number(snapshot.today, points: 32)
            Text(comparison).font(.system(size: 10, weight: .medium)).foregroundStyle(secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
    }
    private var medium: some View {
        Group {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    heading(old ? "마지막 기록" : "오늘 쓴 토큰")
                    number(snapshot.today, points: 28)
                    chart(height: 22, labels: false)
                }.frame(width: 128)
                VStack(alignment: .leading, spacing: 9) {
                    Text(old ? "집계일 AI 사용량" : "어떤 AI를 썼나요?")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                    if snapshot.agents.isEmpty { Text("기록을 기다려요").font(.system(size: 11)).foregroundStyle(secondary) }
                    ForEach(Array(snapshot.agents.prefix(3).enumerated()), id: \.element.id) { index, rank in
                        agentBar(rank, index: index)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
    }
    private var large: some View {
        Group {
            heading("한 주의 AI 사용")
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    number(snapshot.weekTotal, points: 36)
                    Text("최근 7일에 쓴 토큰").font(.system(size: 11)).foregroundStyle(secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(old ? "집계일" : "오늘").font(.system(size: 10)).foregroundStyle(secondary)
                    Text(UsageNumbers.compact(snapshot.today)).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(green)
                }
            }
            chart(height: 56, labels: true).padding(.top, 2)
            HStack(alignment: .top, spacing: 20) {
                ranks(old ? "집계일 모델" : "오늘 많이 쓴 모델", snapshot.models)
                ranks("이번 주 프로젝트", snapshot.projects)
            }.padding(.top, 2)
            Spacer(minLength: 0)
            if snapshot.nearBudget {
                Text(snapshot.today! >= snapshot.dailyBudget! ? "정해 둔 하루 예산에 도달했어요" : "하루 예산의 80%를 넘었어요")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
            }
        }
    }
    private func number(_ tokens: Int64?, points: CGFloat) -> some View {
        Text(UsageNumbers.compact(tokens))
            .font(.system(size: points, weight: .semibold, design: .rounded))
            .tracking(-0.7).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityLabel(tokens.map { "\($0) 토큰" } ?? "사용 기록 없음")
    }
    private func agentBar(_ rank: UsageRank, index: Int) -> some View {
        let color = index == 0 ? green : (scheme == .dark ? Color(red: 0.72, green: 0.69, blue: 0.88) : Color(red: 0.48, green: 0.40, blue: 0.66))
        let total = max(1, snapshot.agents.reduce(Int64(0)) { UsageNumbers.add($0, $1.tokens) })
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(rank.name).lineLimit(1)
                Spacer(minLength: 2)
                Text(UsageNumbers.compact(rank.tokens)).fontWeight(.semibold).fixedSize()
            }.font(.system(size: 11, design: .rounded))
            GeometryReader { proxy in
                Capsule().fill(color.opacity(0.12))
                Capsule().fill(color).frame(width: max(rank.tokens > 0 ? 3 : 0, proxy.size.width * Double(rank.tokens) / Double(total)))
            }.frame(height: 5)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(rank.name), \(rank.tokens) 토큰")
    }
    private func ranks(_ title: String, _ values: [UsageRank]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
            if values.isEmpty { Text("아직 기록이 없어요").font(.system(size: 10)).foregroundStyle(secondary) }
            ForEach(values.prefix(3)) { rank in
                HStack(spacing: 6) {
                    Text(rank.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(UsageNumbers.compact(rank.tokens)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(green).fixedSize()
                }.accessibilityElement(children: .ignore).accessibilityLabel("\(rank.name), \(rank.tokens) 토큰")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func chart(height: CGFloat, labels: Bool) -> some View {
        let maximum = max(1, snapshot.days.compactMap(\.tokens).max() ?? 1)
        return HStack(alignment: .bottom, spacing: labels ? 12 : 5) {
            ForEach(snapshot.days) { day in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Color.clear
                        if let tokens = day.tokens {
                            RoundedRectangle(cornerRadius: labels ? 6 : 3)
                                .fill(green.opacity(day.id == snapshot.days.last?.id ? 1 : 0.45))
                                .frame(height: max(tokens > 0 ? 3 : 1, height * Double(tokens) / Double(maximum)))
                        } else { Text("·").foregroundStyle(secondary) }
                    }.frame(height: height)
                    if labels {
                        Text(day.date, format: Date.FormatStyle(date: .omitted, time: .omitted,
                            timeZone: TimeZone(identifier: snapshot.timeZoneID) ?? .gmt).day())
                            .font(.system(size: 9, design: .rounded)).foregroundStyle(secondary)
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.tokens.map { "\($0) 토큰" } ?? "기록 없음")")
            }
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(old || health.contains("불가") ? Color.orange : green).frame(width: 4, height: 4)
                Text(health).lineLimit(1).minimumScaleFactor(0.8)
                if size != .small { Spacer(minLength: 2); updated }
            }
            if size == .small { updated }
        }.font(.system(size: 9)).foregroundStyle(secondary)
    }
    private var updated: some View {
        HStack(spacing: 3) {
            Text(snapshot.generatedAt, format: old ? .dateTime.month().day().hour().minute() : .dateTime.hour().minute())
            Text("갱신")
        }.lineLimit(1).fixedSize()
    }
}
