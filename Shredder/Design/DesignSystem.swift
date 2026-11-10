import SwiftUI

/// アプリ全体で使う見た目の部品。
enum Theme {
    static let accent = LinearGradient(
        colors: [Color(red: 0.36, green: 0.42, blue: 1.0), Color(red: 0.72, green: 0.36, blue: 0.98)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let danger = LinearGradient(
        colors: [Color(red: 1.0, green: 0.38, blue: 0.36), Color(red: 0.93, green: 0.2, blue: 0.48)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let success = LinearGradient(
        colors: [Color(red: 0.2, green: 0.8, blue: 0.55), Color(red: 0.1, green: 0.65, blue: 0.85)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static func gradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.95), color.mix(with: .black, by: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 色付きの角丸アイコン（システム設定風）。
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.gradient(color), in: .rect(cornerRadius: size * 0.28))
            .shadow(color: color.opacity(0.35), radius: 3, y: 1)
    }
}

/// 各画面の上部に置く見出し。
struct ScreenHeader<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(symbol: String, color: Color, title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.symbol = symbol
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, color: color, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background {
            LinearGradient(colors: [color.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// ガラス調のカード。
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            }
    }
}

/// 「すべて選択 / 選択解除」ボタン（一覧で共通）。
struct SelectAllControl: View {
    let selected: Int
    let total: Int
    let selectAll: () -> Void
    let deselectAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(selected) / \(total) 選択")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Button(action: selectAll) { Label("すべて選択", systemImage: "checkmark.circle") }
                .disabled(total == 0 || selected == total)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button(action: deselectAll) { Label("選択解除", systemImage: "circle") }
                .disabled(selected == 0)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .animation(.snappy, value: selected)
    }
}

/// 処理中の進捗カード（整理・分析で共通）。
struct ProgressCard: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    /// 0...1。nil の場合は不定。
    let fraction: Double?
    var steps: [String] = []
    var currentStep: Int = 0
    var cancel: (() -> Void)?

    var body: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(color.opacity(0.15)).frame(width: 54, height: 54)
                        Image(systemName: symbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.gradient(color))
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .symbolEffect(.bounce, options: .repeating.speed(0.4))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    if let fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.gradient(color))
                            .contentTransition(.numericText())
                    }
                    if let cancel {
                        Button("キャンセル", action: cancel).buttonStyle(.glass)
                    }
                }
                AnimatedProgressBar(fraction: fraction, color: color)
                if !steps.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(spacing: 6) {
                                Image(systemName: index < currentStep ? "checkmark.circle.fill" : (index == currentStep ? "circle.dotted.circle" : "circle"))
                                    .foregroundStyle(index <= currentStep ? color : .secondary)
                                    .symbolEffect(.rotate, isActive: index == currentStep)
                                Text(step).font(.caption.weight(index == currentStep ? .semibold : .regular))
                                    .foregroundStyle(index <= currentStep ? .primary : .secondary)
                            }
                            if index < steps.count - 1 {
                                Rectangle().fill(index < currentStep ? color : Color.secondary.opacity(0.3)).frame(height: 1.5).padding(.horizontal, 8)
                            }
                        }
                    }
                }
            }
        }
        .animation(.smooth, value: fraction)
        .animation(.smooth, value: currentStep)
    }
}

/// 光が流れるアニメーション付きの進捗バー。
struct AnimatedProgressBar: View {
    let fraction: Double?
    let color: Color
    @State private var shimmer = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Theme.gradient(color))
                    .frame(width: fraction.map { max(width * $0, 8) } ?? width * 0.3)
                    .offset(x: fraction == nil ? (shimmer ? width * 0.7 : 0) : 0)
                    .overlay {
                        LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 60)
                            .offset(x: shimmer ? width : -width)
                            .mask(Capsule())
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: 10)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: fraction == nil)) { shimmer = true }
        }
    }
}

/// 数値を大きく見せるタイル。
struct StatTile: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String
    let detail: String
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconBadge(symbol: symbol, color: color, size: 30)
                    Spacer()
                    if action != nil {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }
}

extension SidebarItem {
    var color: Color {
        switch self {
        case .home: .blue
        case .organizer: .indigo
        case .storage: .teal
        case .applications: .pink
        case .history: .orange
        case .settings: .gray
        }
    }

    var subtitle: String {
        switch self {
        case .home: "Mac の状態をひと目で"
        case .organizer: "AI が整理先を提案します"
        case .storage: "容量・大容量ファイル・重複を分析"
        case .applications: "アプリと関連ファイルをまとめて削除"
        case .history: "すべての操作を記録・元に戻せます"
        case .settings: "AI・自動化・外観など"
        }
    }
}
