import Foundation

public struct ExecutionReport: Sendable {
    public let batchID: UUID
    public let moved: [OperationRecord]
    public let failures: [(item: PlanItem, error: String)]
    public let status: OperationStatus
}

/// 承認された整理プランを実行する。削除は一切行わない（仕様 5.3）。
public struct OrganizationExecutor: Sendable {
    let engine: FileOperationEngine
    let store: ShredderStore
    /// 指定した場合はエンジン既定の安全性検証の代わりに使う（自動整理では書き込み完了を確認済みのため）。
    let validator: SafetyValidator?

    public init(engine: FileOperationEngine, store: ShredderStore, validator: SafetyValidator? = nil) {
        self.engine = engine
        self.store = store
        self.validator = validator
    }

    /// `items` はユーザーが承認したもの、または自動実行と判断されたものだけを渡す。
    /// `renamedTo` は名前の衝突を承認した行の新しいファイル名。
    public func execute(
        _ items: [PlanItem],
        renamedTo: [UUID: String] = [:],
        progress: (@Sendable (_ done: Int, _ total: Int, _ name: String) -> Void)? = nil
    ) async -> ExecutionReport {
        let batchID = UUID()
        var moved: [OperationRecord] = []
        var failures: [(PlanItem, String)] = []
        var createdFolders: Set<String> = []

        for (index, item) in items.enumerated() {
            progress?(index, items.count, item.file.name)
            if Task.isCancelled {
                failures.append((item, "キャンセルされました"))
                continue
            }
            guard item.action == .move || item.action == .createFolder, let folder = item.destinationFolder else { continue }
            if case .blocked(let reason) = item.decision {
                failures.append((item, reason))
                continue
            }
            let name = renamedTo[item.id] ?? item.file.name
            if item.conflict != nil && renamedTo[item.id] == nil {
                failures.append((item, "移動先に同名のファイルがあります"))
                continue
            }
            do {
                let folderPath = folder.path(percentEncoded: false)
                if !FileManager.default.fileExists(atPath: folderPath) && !createdFolders.contains(folderPath) {
                    try await engine.createFolder(at: folder, batchID: batchID, validator: validator)
                    createdFolders.insert(folderPath)
                }
                let record = try await engine.move(item.file.url, to: folder.appending(path: name), batchID: batchID, validator: validator)
                moved.append(record)
                try? await store.saveClassification(item.classification, forPath: item.file.url.path(percentEncoded: false))
            } catch {
                failures.append((item, error.description))
            }
        }

        progress?(items.count, items.count, "")
        let status: OperationStatus
        if Task.isCancelled {
            status = .cancelled
        } else if failures.isEmpty {
            status = .success
        } else {
            status = moved.isEmpty ? .failed : .partialSuccess
        }
        return ExecutionReport(batchID: batchID, moved: moved, failures: failures, status: status)
    }

    /// ユーザーが整理先を変更したことを学習する（仕様 8.1 の2）。
    public func recordCorrection(for item: PlanItem, correctedFolder: URL) async {
        let context = ClassificationContext(file: item.file, organizationRoot: item.file.parentURL, candidates: [])
        try? await store.insertCorrection(UserCorrection(
            fileCategory: context.learningKey,
            originalDestination: item.destinationFolder?.path(percentEncoded: false),
            correctedDestination: correctedFolder.path(percentEncoded: false)
        ))
    }
}
