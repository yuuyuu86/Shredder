import AppKit
import ShredderCore
import SwiftUI
import UniformTypeIdentifiers

/// シュレッダー本体のパネル。Finder からのドラッグ＆ドロップを受け付ける（仕様 14, 17.1）。
/// ドロップしても確認画面を出すだけで、すぐには削除しない。
struct ShredderPanel: View {
    @Environment(AppModel.self) private var app
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            ShredderStage(phase: app.trash.phase, settings: app.shredderSettings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(minHeight: 40)
            HStack {
                // ドラッグ操作の代替手段（仕様 24.3）。
                Button("ファイルを選択…", systemImage: "plus") { chooseFiles() }
                    .buttonStyle(.glass)
                if app.trash.phase == .success, app.trash.lastResult != nil {
                    Button("元に戻す", systemImage: "arrow.uturn.backward") { app.trash.undoLast() }
                        .buttonStyle(.glass)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .dropDestination(for: URL.self) { urls, _ in
            app.trash.setHovering(false)
            app.trash.request(urls.filter(\.isFileURL))
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
            if targeted && app.trash.phase == .idle { app.feedback.playDragReaction() }
            app.trash.setHovering(targeted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("シュレッダー。ファイルをドロップするか、ファイルを選択ボタンを使います。")
    }

    private var statusText: String {
        switch app.trash.phase {
        case .idle: "ファイルやアプリをここへドラッグ"
        case .hovering: "ドロップして確認画面へ"
        case .analyzing: "関連ファイルを確認しています…"
        case .confirming: "削除する内容を確認してください"
        case .deleting: "ゴミ箱へ移動しています…"
        case .success: "\(app.trash.lastTrashedNames.count) 項目をゴミ箱へ移動しました"
        case .error(let message): message
        }
    }

    private var statusColor: Color {
        if case .error = app.trash.phase { return .red }
        return .secondary
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "シュレッダーへ"
        guard panel.runModal() == .OK else { return }
        app.trash.request(panel.urls)
    }
}

/// シュレッダーの演出設定（仕様 14.4, 25）。
struct ShredderSettings: Equatable {
    var animationEnabled = true
    var completionEffectEnabled = true
}
