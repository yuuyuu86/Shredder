import Foundation

/// データベーススキーマ（仕様 20）。`PRAGMA user_version` で段階的に移行する。
enum Schema {
    static let migrations: [String] = [
        // v1
        """
        CREATE TABLE files (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            extension TEXT NOT NULL,
            size INTEGER NOT NULL,
            created_at REAL,
            modified_at REAL,
            content_hash TEXT,
            last_scanned_at REAL NOT NULL
        );

        CREATE TABLE classifications (
            id TEXT PRIMARY KEY,
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            category TEXT NOT NULL,
            subcategory TEXT,
            suggested_destination TEXT,
            confidence REAL,
            analysis_source TEXT NOT NULL,
            reason TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX classifications_file_id ON classifications(file_id);

        CREATE TABLE operations (
            id TEXT PRIMARY KEY,
            batch_id TEXT,
            operation_type TEXT NOT NULL,
            source_path TEXT NOT NULL,
            destination_path TEXT,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            undo_available INTEGER NOT NULL,
            error_message TEXT
        );
        CREATE INDEX operations_created_at ON operations(created_at DESC);

        CREATE TABLE organization_rules (
            id TEXT PRIMARY KEY,
            folder_path TEXT NOT NULL,
            condition TEXT NOT NULL,
            destination TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE user_corrections (
            id TEXT PRIMARY KEY,
            file_category TEXT NOT NULL,
            original_destination TEXT,
            corrected_destination TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX user_corrections_category ON user_corrections(file_category, created_at DESC);

        CREATE TABLE watch_folders (
            id TEXT PRIMARY KEY,
            folder_path TEXT NOT NULL UNIQUE,
            mode TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            last_scan_at REAL
        );

        CREATE TABLE uninstall_sessions (
            id TEXT PRIMARY KEY,
            bundle_id TEXT NOT NULL,
            application_name TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE TABLE uninstall_items (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES uninstall_sessions(id) ON DELETE CASCADE,
            file_path TEXT NOT NULL,
            file_type TEXT NOT NULL,
            size INTEGER NOT NULL,
            status TEXT NOT NULL
        );

        CREATE TABLE analysis_cache (
            id TEXT PRIMARY KEY,
            file_id TEXT REFERENCES files(id) ON DELETE CASCADE,
            file_fingerprint TEXT NOT NULL UNIQUE,
            analysis_result TEXT NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE TABLE scheduled_tasks (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            schedule TEXT NOT NULL,
            target_folder TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 0,
            last_run_at REAL
        );

        CREATE TABLE application_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """,
        // v2: 自動整理の処理キュー（仕様 7.5, 19.4）。アプリ終了後も復元できるよう永続化する。
        """
        CREATE TABLE task_queue (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            root TEXT NOT NULL,
            reason TEXT NOT NULL,
            status TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            not_before REAL NOT NULL,
            observed_size INTEGER,
            observed_modified REAL,
            last_error TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX task_queue_ready ON task_queue(status, not_before);
        CREATE UNIQUE INDEX task_queue_active_path ON task_queue(path) WHERE status IN ('pending', 'processing');
        """,
    ]

    static func migrate(_ database: SQLiteDatabase) async throws {
        let current = try await database.userVersion()
        guard current < migrations.count else { return }
        for version in current..<migrations.count {
            let sql = migrations[version]
            try await database.transaction { db in
                try db.executeScript(sql)
                try db.setUserVersion(version + 1)
            }
        }
    }
}
