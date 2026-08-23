import SwiftUI

struct StatusBadge: View {
    enum Kind { case valid, expiring, expired, neutral(String) }
    let kind: Kind
    var body: some View {
        switch kind {
        case .valid: label("Valid", .green)
        case .expiring: label("Expiring Soon", .orange)
        case .expired: label("Expired", .red)
        case .neutral(let t): label(t, .gray)
        }
    }
    private func label(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
            .accessibilityLabel(text)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .system(.footnote, design: .monospaced) : .subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 10).opacity(0.15)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.5, dampingFraction: 0.9), value: progress)
        }
        .frame(width: 130, height: 130)
        .accessibilityLabel("Прогресс \(Int(progress * 100)) процентов")
    }
}

struct SuccessCheck: View {
    @State private var shown = false
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 72))
            .foregroundStyle(.green)
            .scaleEffect(shown ? 1 : 0.3)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { shown = true }
            }
            .accessibilityLabel("Успешно")
    }
}

struct ErrorCard: View {
    let message: String
    let logTail: [LogLine]
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout.weight(.medium))
            DisclosureGroup("Подробности") {
                ScrollView {
                    Text(logTail.suffix(40).map { "\($0.level.rawValue.uppercased()): \($0.message)" }
                        .joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            }
            .font(.footnote)
        }
        .card()
    }
}

struct EmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct ConsoleView: View {
    let lines: [LogLine]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text("\(Self.stamp(line.date)) [\(line.level.rawValue)] \(line.message)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Self.color(for: line.level))
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.35)))
            .onChange(of: lines.count) { _, n in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
    private static func stamp(_ d: Date) -> String {
        d.formatted(.dateTime.hour().minute().second())
    }
    private static func color(for l: LogLevel) -> Color {
        switch l { case .info: .primary; case .warn: .orange; case .error: .red; case .success: .green }
    }
}
