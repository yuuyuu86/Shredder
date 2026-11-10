import Foundation

public enum FileOperationError: Error, Sendable, CustomStringConvertible {
    case unsafe(SafetyViolation)
    case system(String)
    case undo(UndoError)

    public var description: String {
        switch self {
        case .unsafe(let violation): violation.description
        case .system(let message): message
        case .undo(let error): error.description
        }
    }
}

/// 元に戻せない理由（仕様 21.3）。
public enum UndoError: Error, Sendable, Equatable, CustomStringConvertible {
    case notUndoable
    case fileMissing(String)
    case originalLocationOccupied(String)
    case permissionDenied(String)
    case trashEmptied(String)

    public var description: String {
        switch self {
        case .notUndoable: "この操作は元に戻せません"
        case .fileMissing(let path): "ファイルが存在しません: \(path)"
        case .originalLocationOccupied(let path): "元の場所に別のファイルがあります: \(path)"
        case .permissionDenied(let path): "権限が不足しています: \(path)"
        case .trashEmptied(let path): "ゴミ箱が空にされたため復元できません: \(path)"
        }
    }
}

public struct TrashItemResult: Sendable, Hashable {
    public let url: URL
    public let trashedURL: URL?
    public let error: String?

    public var succeeded: Bool { error == nil }
}

public struct TrashBatchResult: Sendable {
    public let batchID: UUID
    public let items: [TrashItemResult]

    public var status: OperationStatus {
        let succeeded = items.filter(\.succeeded).count
        if succeeded == items.count { return .success }
        if succeeded == 0 { return .failed }
        return .partialSuccess
    }

    public var failures: [TrashItemResult] { items.filter { !$0.succeeded } }
}

/// ファイル操作を一か所に集約するエンジン（仕様 2.2）。
/// すべての変更は安全性検証を通り、履歴に記録される。削除はゴミ箱への移動のみ（仕様 27.4）。
public actor FileOperationEngine {
    /// 項目をゴミ箱へ移し、ゴミ箱内の新しい場所を返す。テストでは差し替える。
    public typealias Trasher = @Sendable (URL) throws -> URL?

    public static let systemTrash: Trasher = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    public let store: ShredderStore
    public private(set) var validator: SafetyValidator
    private let trasher: Trasher

    public init(store: ShredderStore, validator: SafetyValidator, trasher: @escaping Trasher = FileOperationEngine.systemTrash) {
        self.store = store
        self.validator = validator
        self.trasher = trasher
    }

    public func updateValidator(_ validator: SafetyValidator) {
        self.validator = validator
    }

    // MARK: - Move / Rename / Create

    @discardableResult
    public func move(_ source: URL, to destination: URL, batchID: UUID? = nil, validator override: SafetyValidator? = nil) async throws(FileOperationError) -> OperationRecord {
        do {
            try (override ?? validator).validateMove(from: source, to: destination)
        } catch {
            try await recordFailure(.move, source: source, destination: destination, batchID: batchID, message: error.description)
            throw .unsafe(error)
        }
        return try await perform(.move, source: source, destination: destination, batchID: batchID) {
            // moveItem は移動先が存在すると失敗するため、上書きは起こらない。
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    @discardableResult
    public func rename(_ url: URL, to newName: String, batchID: UUID? = nil) async throws(FileOperationError) -> OperationRecord {
        let destination = url.deletingLastPathComponent().appending(path: newName)
        do {
            try validator.validateRename(url, to: newName)
        } catch {
            try await recordFailure(.rename, source: url, destination: destination, batchID: batchID, message: error.description)
            throw .unsafe(error)
        }
        return try await perform(.rename, source: url, destination: destination, batchID: batchID) {
            try FileManager.default.moveItem(at: url, to: destination)
        }
    }

    @discardableResult
    public func createFolder(at url: URL, batchID: UUID? = nil, validator override: SafetyValidator? = nil) async throws(FileOperationError) -> OperationRecord {
        do {
            try (override ?? validator).validateCreateFolder(at: url)
        } catch {
            throw .unsafe(error)
        }
        return try await perform(.createFolder, source: url, destination: nil, batchID: batchID) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    // MARK: - Trash

    /// 項目をゴミ箱へ移動する。呼び出し側で必ずユーザー承認を得てから呼ぶこと（仕様 10.3）。
    /// アプリ削除のように対象ごとに許可範囲が決まる場合は `validator` で上書きする。
    /// `stopOnFirstFailure` が true の場合、最初の失敗以降の項目は試さずに失敗として返す。
    public func moveToTrash(
        _ urls: [URL],
        batchID: UUID = UUID(),
        validator override: SafetyValidator? = nil,
        stopOnFirstFailure: Bool = false
    ) async -> TrashBatchResult {
        let validator = override ?? validator
        var results: [TrashItemResult] = []
        for url in urls {
            if stopOnFirstFailure, results.contains(where: { !$0.succeeded }) {
                results.append(TrashItemResult(url: url, trashedURL: nil, error: "前の項目の移動に失敗したため中止しました"))
                continue
            }
            do {
                try validator.validateTrash(url)
                let trashed = try trasher(url)
                try? await store.insertOperation(OperationRecord(
                    batchID: batchID,
                    type: .trash,
                    sourcePath: url.path(percentEncoded: false),
                    destinationPath: trashed?.path(percentEncoded: false),
                    status: .completed,
                    undoAvailable: trashed != nil
                ))
                results.append(TrashItemResult(url: url, trashedURL: trashed, error: nil))
            } catch {
                let message = (error as? SafetyViolation)?.description ?? FileScanner.describe(error)
                try? await store.insertOperation(OperationRecord(
                    batchID: batchID,
                    type: .trash,
                    sourcePath: url.path(percentEncoded: false),
                    destinationPath: nil,
                    status: .failed,
                    undoAvailable: false,
                    errorMessage: message
                ))
                results.append(TrashItemResult(url: url, trashedURL: nil, error: message))
            }
        }
        return TrashBatchResult(batchID: batchID, items: results)
    }

    // MARK: - Undo

    /// 操作を取り消す（仕様 21.2）。ゴミ箱に残っている項目は元の場所へ戻す。
    @discardableResult
    public func undo(_ record: OperationRecord) async throws(FileOperationError) -> OperationRecord {
        guard record.status == .completed, record.undoAvailable else { throw .undo(.notUndoable) }
        let original = URL(filePath: record.sourcePath)
        let fileManager = FileManager.default

        switch record.type {
        case .move, .rename, .trash:
            guard let destinationPath = record.destinationPath else { throw .undo(.notUndoable) }
            let current = URL(filePath: destinationPath)
            guard fileManager.fileExists(atPath: destinationPath) else {
                throw .undo(record.type == .trash ? .trashEmptied(destinationPath) : .fileMissing(destinationPath))
            }
            guard !fileManager.fileExists(atPath: record.sourcePath) else {
                throw .undo(.originalLocationOccupied(record.sourcePath))
            }
            let parent = original.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path(percentEncoded: false)) {
                do {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                } catch {
                    throw .undo(.permissionDenied(parent.path(percentEncoded: false)))
                }
            }
            let type: OperationType = record.type == .trash ? .restore : record.type
            let result = try await perform(type, source: current, destination: original, batchID: record.batchID, undoable: false) {
                try fileManager.moveItem(at: current, to: original)
            }
            try await markUndone(record)
            return result

        case .createFolder:
            // 作成したフォルダが空の場合のみ、ゴミ箱へ移動して取り消す。
            guard fileManager.fileExists(atPath: record.sourcePath) else { throw .undo(.fileMissing(record.sourcePath)) }
            let contents = (try? fileManager.contentsOfDirectory(atPath: record.sourcePath)) ?? []
            guard contents.filter({ $0 != ".DS_Store" }).isEmpty else {
                throw .undo(.originalLocationOccupied(record.sourcePath))
            }
            let result = await moveToTrash([original], batchID: record.batchID ?? UUID())
            guard result.status == .success else {
                throw .undo(.permissionDenied(record.sourcePath))
            }
            try await markUndone(record)
            var undone = record
            undone.status = .undone
            undone.undoAvailable = false
            return undone

        case .restore:
            throw .undo(.notUndoable)
        }
    }

    /// バッチ内の操作を新しい順に取り消す（フォルダ作成より先に移動を戻すため）。
    public func undoBatch(_ batchID: UUID) async -> [(OperationRecord, FileOperationError?)] {
        let records = ((try? await store.operations(limit: 10_000)) ?? [])
            .filter { $0.batchID == batchID && $0.status == .completed && $0.undoAvailable }
            .sorted { $0.createdAt > $1.createdAt }
        var results: [(OperationRecord, FileOperationError?)] = []
        for record in records {
            do {
                try await undo(record)
                results.append((record, nil))
            } catch {
                results.append((record, error))
            }
        }
        return results
    }

    // MARK: - Private

    private func perform(
        _ type: OperationType,
        source: URL,
        destination: URL?,
        batchID: UUID?,
        undoable: Bool = true,
        _ body: () throws -> Void
    ) async throws(FileOperationError) -> OperationRecord {
        do {
            try body()
        } catch {
            let message = FileScanner.describe(error)
            try await recordFailure(type, source: source, destination: destination, batchID: batchID, message: message)
            throw .system(message)
        }
        let record = OperationRecord(
            batchID: batchID,
            type: type,
            sourcePath: source.path(percentEncoded: false),
            destinationPath: destination?.path(percentEncoded: false),
            status: .completed,
            undoAvailable: undoable
        )
        do {
            try await store.insertOperation(record)
        } catch {
            throw .system("履歴の保存に失敗しました: \(error)")
        }
        return record
    }

    private func recordFailure(_ type: OperationType, source: URL, destination: URL?, batchID: UUID?, message: String) async throws(FileOperationError) {
        try? await store.insertOperation(OperationRecord(
            batchID: batchID,
            type: type,
            sourcePath: source.path(percentEncoded: false),
            destinationPath: destination?.path(percentEncoded: false),
            status: .failed,
            undoAvailable: false,
            errorMessage: message
        ))
    }

    private func markUndone(_ record: OperationRecord) async throws(FileOperationError) {
        do {
            try await store.updateOperation(id: record.id, status: .undone, undoAvailable: false)
        } catch {
            throw .system("履歴の更新に失敗しました: \(error)")
        }
    }
}
