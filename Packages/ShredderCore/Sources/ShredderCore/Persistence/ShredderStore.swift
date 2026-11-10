import Foundation

/// アプリ全体の永続化窓口。テーブルごとの読み書きをまとめる。
public struct ShredderStore: Sendable {
    public let database: SQLiteDatabase

    public static func open(at url: URL?) async throws -> ShredderStore {
        let database = try SQLiteDatabase(url: url)
        try await Schema.migrate(database)
        return ShredderStore(database: database)
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Shredder", directoryHint: .isDirectory)
            .appending(path: "shredder.sqlite")
    }

    // MARK: - files

    public func upsertFiles(_ files: [FileRecord], scannedAt: Date = Date()) async throws {
        guard !files.isEmpty else { return }
        try await database.transaction { db in
            for file in files {
                try db.execute(
                    """
                    INSERT INTO files (id, path, name, extension, size, created_at, modified_at, content_hash, last_scanned_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        name = excluded.name,
                        extension = excluded.extension,
                        size = excluded.size,
                        created_at = excluded.created_at,
                        modified_at = excluded.modified_at,
                        content_hash = COALESCE(excluded.content_hash, files.content_hash),
                        last_scanned_at = excluded.last_scanned_at
                    """,
                    [
                        SQLValue(file.id), SQLValue(file.url.path(percentEncoded: false)), SQLValue(file.name),
                        SQLValue(file.fileExtension), SQLValue(file.size), SQLValue(file.createdAt),
                        SQLValue(file.modifiedAt), SQLValue(file.contentHash), SQLValue(scannedAt),
                    ]
                )
            }
        }
    }

    /// パスに対応する files.id を返す。files 行が既存なら既存IDを使う。
    public func fileID(forPath path: String) async throws -> UUID? {
        try await database.query("SELECT id FROM files WHERE path = ?", [.text(path)]).first?.uuid("id")
    }

    /// 前回スキャン時のサイズと更新日時（差分スキャン用）。
    public func knownFileStates(under folder: String) async throws -> [String: (size: Int64, modifiedAt: Date?)] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let rows = try await database.query(
            "SELECT path, size, modified_at FROM files WHERE path LIKE ? ESCAPE '\\'",
            [.text(Self.escapeLike(prefix) + "%")]
        )
        var states: [String: (size: Int64, modifiedAt: Date?)] = [:]
        for row in rows {
            guard let path = row.string("path") else { continue }
            states[path] = (row.int("size") ?? 0, row.date("modified_at"))
        }
        return states
    }

    // MARK: - classifications

    public func saveClassification(_ result: ClassificationResult, forPath path: String) async throws {
        guard let fileID = try await fileID(forPath: path) else { return }
        try await database.execute(
            """
            INSERT INTO classifications (id, file_id, category, subcategory, suggested_destination, confidence, analysis_source, reason, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                SQLValue(UUID()), SQLValue(fileID), SQLValue(result.category), SQLValue(result.subcategory),
                SQLValue(result.suggestedDestination?.path(percentEncoded: false)), SQLValue(result.confidence),
                SQLValue(result.source.rawValue), SQLValue(result.reason), SQLValue(Date()),
            ]
        )
    }

    // MARK: - operations

    public func insertOperation(_ record: OperationRecord) async throws {
        try await database.execute(
            """
            INSERT INTO operations (id, batch_id, operation_type, source_path, destination_path, status, created_at, undo_available, error_message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                SQLValue(record.id), SQLValue(record.batchID), SQLValue(record.type.rawValue),
                SQLValue(record.sourcePath), SQLValue(record.destinationPath), SQLValue(record.status.rawValue),
                SQLValue(record.createdAt), SQLValue(record.undoAvailable), SQLValue(record.errorMessage),
            ]
        )
    }

    public func updateOperation(id: UUID, status: OperationRecordStatus, undoAvailable: Bool) async throws {
        try await database.execute(
            "UPDATE operations SET status = ?, undo_available = ? WHERE id = ?",
            [SQLValue(status.rawValue), SQLValue(undoAvailable), SQLValue(id)]
        )
    }

    public func operations(limit: Int = 200, offset: Int = 0) async throws -> [OperationRecord] {
        try await database.query(
            "SELECT * FROM operations ORDER BY created_at DESC LIMIT ? OFFSET ?",
            [SQLValue(limit), SQLValue(offset)]
        ).compactMap(Self.operation(from:))
    }

    public func operation(id: UUID) async throws -> OperationRecord? {
        try await database.query("SELECT * FROM operations WHERE id = ?", [SQLValue(id)])
            .first.flatMap(Self.operation(from:))
    }

    /// 過去の整理履歴から、同じ元フォルダ・同じ拡張子のファイルの移動先を集計する（仕様 8.1 の1）。
    public func historicalDestinations(fileExtension: String, fromFolder folder: String) async throws -> [(folder: String, count: Int)] {
        guard !fileExtension.isEmpty else { return [] }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let rows = try await database.query(
            """
            SELECT source_path, destination_path FROM operations
            WHERE operation_type = 'move' AND status = 'completed'
              AND source_path LIKE ? ESCAPE '\\' AND lower(source_path) LIKE ? ESCAPE '\\'
            ORDER BY created_at DESC LIMIT 500
            """,
            [.text(Self.escapeLike(prefix) + "%"), .text("%." + Self.escapeLike(fileExtension.lowercased()))]
        )
        var counts: [String: Int] = [:]
        for row in rows {
            guard let source = row.string("source_path"), let destination = row.string("destination_path") else { continue }
            // 元フォルダ直下のファイルのみを対象にする。
            guard URL(filePath: source).deletingLastPathComponent().path(percentEncoded: false) == URL(filePath: prefix).path(percentEncoded: false) else { continue }
            counts[URL(filePath: destination).deletingLastPathComponent().path(percentEncoded: false), default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    // MARK: - organization_rules

    public func saveRule(_ rule: OrganizationRule) async throws {
        let condition = String(decoding: try JSONEncoder().encode(rule.condition), as: UTF8.self)
        try await database.execute(
            """
            INSERT INTO organization_rules (id, folder_path, condition, destination, priority, enabled)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                folder_path = excluded.folder_path, condition = excluded.condition,
                destination = excluded.destination, priority = excluded.priority, enabled = excluded.enabled
            """,
            [
                SQLValue(rule.id), SQLValue(rule.folderPath), SQLValue(condition),
                SQLValue(rule.destination), SQLValue(rule.priority), SQLValue(rule.enabled),
            ]
        )
    }

    public func deleteRule(id: UUID) async throws {
        try await database.execute("DELETE FROM organization_rules WHERE id = ?", [SQLValue(id)])
    }

    public func rules(enabledOnly: Bool = false) async throws -> [OrganizationRule] {
        let sql = enabledOnly
            ? "SELECT * FROM organization_rules WHERE enabled = 1 ORDER BY priority DESC"
            : "SELECT * FROM organization_rules ORDER BY priority DESC"
        return try await database.query(sql).compactMap { row in
            guard
                let id = row.uuid("id"),
                let folder = row.string("folder_path"),
                let destination = row.string("destination"),
                let conditionJSON = row.string("condition"),
                let condition = try? JSONDecoder().decode(RuleCondition.self, from: Data(conditionJSON.utf8))
            else { return nil }
            return OrganizationRule(
                id: id,
                folderPath: folder,
                condition: condition,
                destination: destination,
                priority: Int(row.int("priority") ?? 0),
                enabled: row.bool("enabled")
            )
        }
    }

    // MARK: - user_corrections

    public func insertCorrection(_ correction: UserCorrection) async throws {
        try await database.execute(
            "INSERT INTO user_corrections (id, file_category, original_destination, corrected_destination, created_at) VALUES (?, ?, ?, ?, ?)",
            [
                SQLValue(correction.id), SQLValue(correction.fileCategory), SQLValue(correction.originalDestination),
                SQLValue(correction.correctedDestination), SQLValue(correction.createdAt),
            ]
        )
    }

    public func corrections(forCategory category: String, limit: Int = 20) async throws -> [UserCorrection] {
        try await database.query(
            "SELECT * FROM user_corrections WHERE file_category = ? ORDER BY created_at DESC LIMIT ?",
            [.text(category), SQLValue(limit)]
        ).compactMap { row in
            guard let id = row.uuid("id"), let corrected = row.string("corrected_destination") else { return nil }
            return UserCorrection(
                id: id,
                fileCategory: category,
                originalDestination: row.string("original_destination"),
                correctedDestination: corrected,
                createdAt: row.date("created_at") ?? .distantPast
            )
        }
    }

    public func correctionCount() async throws -> Int {
        Int(try await database.query("SELECT COUNT(*) AS n FROM user_corrections").first?.int("n") ?? 0)
    }

    /// 学習データ（修正履歴と解析キャッシュ）を消去する。整理ルールと操作履歴は残す。
    public func clearLearningData() async throws {
        try await database.executeScript("DELETE FROM user_corrections; DELETE FROM analysis_cache;")
    }

    // MARK: - analysis_cache

    public func cachedAnalysis(fingerprint: String) async throws -> ClassificationResult? {
        guard let json = try await database.query(
            "SELECT analysis_result FROM analysis_cache WHERE file_fingerprint = ?",
            [.text(fingerprint)]
        ).first?.string("analysis_result") else { return nil }
        return try? JSONDecoder().decode(ClassificationResult.self, from: Data(json.utf8))
    }

    public func cacheAnalysis(_ result: ClassificationResult, fingerprint: String, path: String) async throws {
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        let fileID = try await fileID(forPath: path)
        try await database.execute(
            """
            INSERT INTO analysis_cache (id, file_id, file_fingerprint, analysis_result, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(file_fingerprint) DO UPDATE SET analysis_result = excluded.analysis_result, created_at = excluded.created_at
            """,
            [SQLValue(UUID()), SQLValue(fileID), .text(fingerprint), .text(json), SQLValue(Date())]
        )
    }

    // MARK: - uninstall_sessions / uninstall_items

    public func insertUninstallSession(id: UUID, bundleID: String, name: String, status: String) async throws {
        try await database.execute(
            "INSERT INTO uninstall_sessions (id, bundle_id, application_name, status, created_at) VALUES (?, ?, ?, ?, ?)",
            [SQLValue(id), .text(bundleID), .text(name), .text(status), SQLValue(Date())]
        )
    }

    public func updateUninstallSession(id: UUID, status: String) async throws {
        try await database.execute("UPDATE uninstall_sessions SET status = ? WHERE id = ?", [.text(status), SQLValue(id)])
    }

    public func insertUninstallItem(sessionID: UUID, path: String, type: String, size: Int64, status: String) async throws {
        try await database.execute(
            "INSERT INTO uninstall_items (id, session_id, file_path, file_type, size, status) VALUES (?, ?, ?, ?, ?, ?)",
            [SQLValue(UUID()), SQLValue(sessionID), .text(path), .text(type), SQLValue(size), .text(status)]
        )
    }

    public func uninstallItems(sessionID: UUID) async throws -> [(path: String, status: String)] {
        try await database.query(
            "SELECT file_path, status FROM uninstall_items WHERE session_id = ?",
            [SQLValue(sessionID)]
        ).compactMap { row in
            guard let path = row.string("file_path"), let status = row.string("status") else { return nil }
            return (path, status)
        }
    }

    // MARK: - application_settings

    public func setting(_ key: String) async throws -> String? {
        try await database.query("SELECT value FROM application_settings WHERE key = ?", [.text(key)]).first?.string("value")
    }

    public func setSetting(_ key: String, _ value: String) async throws {
        try await database.execute(
            "INSERT INTO application_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }

    // MARK: - Helpers

    static func escapeLike(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func operation(from row: Row) -> OperationRecord? {
        guard
            let id = row.uuid("id"),
            let type = row.string("operation_type").flatMap(OperationType.init(rawValue:)),
            let source = row.string("source_path"),
            let status = row.string("status").flatMap(OperationRecordStatus.init(rawValue:))
        else { return nil }
        return OperationRecord(
            id: id,
            batchID: row.uuid("batch_id"),
            type: type,
            sourcePath: source,
            destinationPath: row.string("destination_path"),
            status: status,
            createdAt: row.date("created_at") ?? .distantPast,
            undoAvailable: row.bool("undo_available"),
            errorMessage: row.string("error_message")
        )
    }
}
