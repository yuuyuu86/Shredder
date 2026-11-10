import Foundation
import Observation
import ShredderCore

@MainActor
@Observable
final class HistoryModel {
    weak var app: AppModel?

    var records: [OperationRecord] = []
    var selection: Set<OperationRecord.ID> = []
    var message: String?

    func reload() async {
        guard let store = app?.store else { return }
        records = (try? await store.operations(limit: 1_000)) ?? []
    }

    func undo(_ ids: Set<OperationRecord.ID>) {
        guard let engine = app?.engine else { return }
        // 新しい操作から順に戻す。
        let targets = records.filter { ids.contains($0.id) && $0.undoAvailable && $0.status == .completed }
            .sorted { $0.createdAt > $1.createdAt }
        Task {
            var errors: [String] = []
            for record in targets {
                do {
                    try await engine.undo(record)
                } catch {
                    errors.append(String(describing: error))
                }
            }
            message = errors.isEmpty ? "\(targets.count) 件の操作を元に戻しました。" : errors.joined(separator: "\n")
            await reload()
        }
    }
}

extension OperationType {
    var title: String {
        switch self {
        case .move: "移動"
        case .rename: "名前変更"
        case .createFolder: "フォルダ作成"
        case .trash: "ゴミ箱へ移動"
        case .restore: "ゴミ箱から復元"
        }
    }
}

extension OperationRecordStatus {
    var title: String {
        switch self {
        case .completed: "完了"
        case .failed: "失敗"
        case .undone: "取り消し済み"
        }
    }
}
