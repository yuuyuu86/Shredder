import Foundation

/// 監視フォルダ（watch_folders, 仕様 20.7）。
public struct WatchFolder: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var path: String
    public var mode: OrganizationMode
    public var enabled: Bool
    public var lastScanAt: Date?

    public init(id: UUID = UUID(), path: String, mode: OrganizationMode, enabled: Bool = true, lastScanAt: Date? = nil) {
        self.id = id
        self.path = path
        self.mode = mode
        self.enabled = enabled
        self.lastScanAt = lastScanAt
    }

    public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

/// スケジュール整理（scheduled_tasks, 仕様 20.11）。
public struct ScheduledOrganization: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var schedule: ScheduleSpec
    public var targetFolder: String
    public var enabled: Bool
    public var lastRunAt: Date?

    public init(id: UUID = UUID(), name: String, schedule: ScheduleSpec, targetFolder: String, enabled: Bool = true, lastRunAt: Date? = nil) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.targetFolder = targetFolder
        self.enabled = enabled
        self.lastRunAt = lastRunAt
    }
}

/// 「指定した曜日の指定時刻」に実行する（仕様 7.1）。weekday は Calendar と同じ 1=日曜 … 7=土曜。
public struct ScheduleSpec: Codable, Sendable, Hashable {
    public var weekdays: Set<Int>
    public var hour: Int
    public var minute: Int

    public init(weekdays: Set<Int>, hour: Int, minute: Int) {
        self.weekdays = weekdays
        self.hour = hour
        self.minute = minute
    }

    public static let everyDay: Set<Int> = Set(1...7)

    /// `date` 以前で直近の実行予定時刻。
    public func latestFire(atOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire <= date
            else { continue }
            return fire
        }
        return nil
    }

    public func nextFire(after date: Date, calendar: Calendar = .current) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire > date
            else { continue }
            return fire
        }
        return nil
    }

    /// 前回の実行以降に予定時刻を過ぎていれば実行する（アプリが閉じていた間の分は1回だけ実行）。
    public func isDue(lastRun: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let fire = latestFire(atOrBefore: now, calendar: calendar) else { return false }
        guard let lastRun else { return true }
        return lastRun < fire
    }
}

public struct QueuedTask: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let path: String
    public let root: String
    public let reason: String
    public var status: TaskStatus
    public var attempts: Int
    public var notBefore: Date
    public var observedSize: Int64?
    public var observedModified: Date?
    public var lastError: String?
    public let createdAt: Date
}

extension ShredderStore {
    // MARK: - watch_folders

    public func watchFolders() async throws -> [WatchFolder] {
        try await database.query("SELECT * FROM watch_folders ORDER BY folder_path").compactMap { row in
            guard let id = row.uuid("id"), let path = row.string("folder_path") else { return nil }
            return WatchFolder(
                id: id,
                path: path,
                mode: row.string("mode").flatMap(OrganizationMode.init(rawValue:)) ?? .manual,
                enabled: row.bool("enabled"),
                lastScanAt: row.date("last_scan_at")
            )
        }
    }

    public func saveWatchFolder(_ folder: WatchFolder) async throws {
        try await database.execute(
            """
            INSERT INTO watch_folders (id, folder_path, mode, enabled, last_scan_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET folder_path = excluded.folder_path, mode = excluded.mode,
                enabled = excluded.enabled, last_scan_at = excluded.last_scan_at
            """,
            [SQLValue(folder.id), .text(folder.path), .text(folder.mode.rawValue), SQLValue(folder.enabled), SQLValue(folder.lastScanAt)]
        )
    }

    public func deleteWatchFolder(id: UUID) async throws {
        try await database.execute("DELETE FROM watch_folders WHERE id = ?", [SQLValue(id)])
    }

    // MARK: - scheduled_tasks

    public func scheduledOrganizations() async throws -> [ScheduledOrganization] {
        try await database.query("SELECT * FROM scheduled_tasks ORDER BY name").compactMap { row in
            guard
                let id = row.uuid("id"),
                let json = row.string("schedule"),
                let schedule = try? JSONDecoder().decode(ScheduleSpec.self, from: Data(json.utf8)),
                let target = row.string("target_folder")
            else { return nil }
            return ScheduledOrganization(
                id: id, name: row.string("name") ?? "", schedule: schedule, targetFolder: target,
                enabled: row.bool("enabled"), lastRunAt: row.date("last_run_at")
            )
        }
    }

    public func saveScheduledOrganization(_ task: ScheduledOrganization) async throws {
        let json = String(decoding: try JSONEncoder().encode(task.schedule), as: UTF8.self)
        try await database.execute(
            """
            INSERT INTO scheduled_tasks (id, name, schedule, target_folder, enabled, last_run_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, schedule = excluded.schedule,
                target_folder = excluded.target_folder, enabled = excluded.enabled, last_run_at = excluded.last_run_at
            """,
            [SQLValue(task.id), .text(task.name), .text(json), .text(task.targetFolder), SQLValue(task.enabled), SQLValue(task.lastRunAt)]
        )
    }

    public func deleteScheduledOrganization(id: UUID) async throws {
        try await database.execute("DELETE FROM scheduled_tasks WHERE id = ?", [SQLValue(id)])
    }

    // MARK: - task_queue

    /// 同じパスの未処理タスクがあれば、待ち時間だけ更新する。
    public func enqueue(path: String, root: String, reason: String, notBefore: Date) async throws {
        let now = Date()
        try await database.execute(
            """
            INSERT INTO task_queue (id, path, root, reason, status, attempts, not_before, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'pending', 0, ?, ?, ?)
            ON CONFLICT(path) WHERE status IN ('pending', 'processing') DO UPDATE SET
                not_before = MAX(task_queue.not_before, excluded.not_before), updated_at = excluded.updated_at
            """,
            [SQLValue(UUID()), .text(path), .text(root), .text(reason), SQLValue(notBefore), SQLValue(now), SQLValue(now)]
        )
    }

    public func readyTasks(now: Date, limit: Int) async throws -> [QueuedTask] {
        try await database.query(
            "SELECT * FROM task_queue WHERE status = 'pending' AND not_before <= ? ORDER BY not_before LIMIT ?",
            [SQLValue(now), SQLValue(limit)]
        ).compactMap(Self.queuedTask(from:))
    }

    public func tasks(status: TaskStatus, limit: Int = 200) async throws -> [QueuedTask] {
        try await database.query(
            "SELECT * FROM task_queue WHERE status = ? ORDER BY updated_at DESC LIMIT ?",
            [.text(status.rawValue), SQLValue(limit)]
        ).compactMap(Self.queuedTask(from:))
    }

    public func updateTask(_ task: QueuedTask) async throws {
        try await database.execute(
            """
            UPDATE task_queue SET status = ?, attempts = ?, not_before = ?, observed_size = ?, observed_modified = ?,
                last_error = ?, updated_at = ? WHERE id = ?
            """,
            [
                .text(task.status.rawValue), SQLValue(task.attempts), SQLValue(task.notBefore), SQLValue(task.observedSize),
                SQLValue(task.observedModified), SQLValue(task.lastError), SQLValue(Date()), SQLValue(task.id),
            ]
        )
    }

    /// 処理中のまま終了したタスクを再開できる状態に戻す（仕様 19.4）。
    public func resumeInterruptedTasks() async throws {
        try await database.execute("UPDATE task_queue SET status = 'pending', updated_at = ? WHERE status = 'processing'", [SQLValue(Date())])
    }

    public func pendingTaskCount() async throws -> Int {
        Int(try await database.query("SELECT COUNT(*) AS n FROM task_queue WHERE status = 'pending'").first?.int("n") ?? 0)
    }

    /// 古い完了済みタスクを片付ける。
    public func pruneTasks(olderThan date: Date) async throws {
        try await database.execute(
            "DELETE FROM task_queue WHERE status IN ('completed', 'cancelled', 'failed') AND updated_at < ?",
            [SQLValue(date)]
        )
    }

    static func queuedTask(from row: Row) -> QueuedTask? {
        guard
            let id = row.uuid("id"), let path = row.string("path"), let root = row.string("root"),
            let status = row.string("status").flatMap(TaskStatus.init(rawValue:))
        else { return nil }
        return QueuedTask(
            id: id, path: path, root: root, reason: row.string("reason") ?? "", status: status,
            attempts: Int(row.int("attempts") ?? 0), notBefore: row.date("not_before") ?? .distantPast,
            observedSize: row.int("observed_size"), observedModified: row.date("observed_modified"),
            lastError: row.string("last_error"), createdAt: row.date("created_at") ?? .distantPast
        )
    }
}
