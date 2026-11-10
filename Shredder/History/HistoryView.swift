import ShredderCore
import SwiftUI

/// 履歴画面（仕様 13.7）。
struct HistoryView: View {
    @Bindable var history: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            if history.records.isEmpty {
                ContentUnavailableView("操作履歴はありません", systemImage: "clock", description: Text("ファイルの移動・フォルダ作成・ゴミ箱への移動がここに記録されます。"))
            } else {
                Table(history.records, selection: $history.selection) {
                    TableColumn("日時") { record in
                        Text(record.createdAt.formatted(date: .numeric, time: .shortened))
                    }
                    .width(min: 110, ideal: 130)
                    TableColumn("ファイル") { record in
                        Text(URL(filePath: record.sourcePath).lastPathComponent).lineLimit(1)
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("操作") { record in Text(record.type.title) }
                        .width(min: 80, ideal: 100)
                    TableColumn("元の場所") { record in
                        Text(abbreviate(URL(filePath: record.sourcePath).deletingLastPathComponent().path(percentEncoded: false)))
                            .lineLimit(1)
                            .help(record.sourcePath)
                    }
                    TableColumn("移動先") { record in
                        Text(record.destinationPath.map(abbreviate) ?? "-")
                            .lineLimit(1)
                            .help(record.destinationPath ?? "")
                    }
                    TableColumn("結果") { record in
                        Text(record.status.title)
                            .foregroundStyle(record.status == .failed ? .red : .primary)
                            .help(record.errorMessage ?? "")
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("Undo") { record in
                        if record.undoAvailable && record.status == .completed {
                            Button("元に戻す") { history.undo([record.id]) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .width(80)
                }
            }
            Divider()
            HStack {
                SelectAllControl(
                    selected: history.selection.count,
                    total: history.records.count,
                    selectAll: { history.selection = Set(history.records.map(\.id)) },
                    deselectAll: { history.selection = [] }
                )
                Spacer()
                Button {
                    history.undo(history.selection)
                } label: {
                    Label("選択した操作を元に戻す", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .disabled(history.selection.isEmpty)
            }
            .padding(12)
            if let message = history.message {
                Divider()
                HStack {
                    Text(message).font(.callout)
                    Spacer()
                    Button("閉じる", systemImage: "xmark") { history.message = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(10)
            }
        }
        .toolbar {
            Button("選択した操作を元に戻す", systemImage: "arrow.uturn.backward") { history.undo(history.selection) }
                .disabled(history.selection.isEmpty)
            Button("再読み込み", systemImage: "arrow.clockwise") { Task { await history.reload() } }
        }
        .task { await history.reload() }
    }

    private func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
