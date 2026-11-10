import AppKit
import Foundation
import Observation
import ShredderCore

/// 自動整理の状態と設定（仕様 7, 18, 19）。
@MainActor
@Observable
final class AutomationController {
    enum Key {
        static let realtime = "automation.realtime"
        static let schedules = "automation.schedules"
        static let idleScan = "automation.idleScan"
        static let powerSaving = "automation.powerSaving"
        static let paused = "automation.paused"
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let event: AutomationEvent
    }

    weak var app: AppModel?
    private(set) var engine: AutomationEngine?

    // 初期値は仕様 7.2 / 25 に従う。
    var realtimeEnabled = false { didSet { changed(Key.realtime, realtimeEnabled) } }
    var schedulesEnabled = false { didSet { changed(Key.schedules, schedulesEnabled) } }
    var idleScanEnabled = true { didSet { changed(Key.idleScan, idleScanEnabled) } }
    var powerSavingEnabled = true { didSet { changed(Key.powerSaving, powerSavingEnabled) } }
    private(set) var isPaused = false

    private(set) var watchFolders: [WatchFolder] = []
    private(set) var schedules: [ScheduledOrganization] = []
    private(set) var isWatching = false
    private(set) var pendingCount = 0
    private(set) var reviewItems: [QueuedTask] = []
    private(set) var log: [LogEntry] = []
    private(set) var conditions = SystemConditions()
    private var loading = false
    private var listenTask: Task<Void, Never>?

    var statusText: String {
        if isPaused { return "自動整理は一時停止中" }
        if !realtimeEnabled && !schedulesEnabled { return "自動整理はオフ" }
        if PowerPolicy(powerSavingEnabled: powerSavingEnabled).shouldPause(conditions) { return "省電力のため待機中" }
        if realtimeEnabled && isWatching { return "\(watchFolders.filter(\.enabled).count) 個のフォルダを監視中" }
        if schedulesEnabled { return "スケジュール整理が有効" }
        return "監視するフォルダがありません"
    }

    var organizedRecently: [LogEntry] {
        log.filter { if case .organized = $0.event { true } else { false } }
    }

    func start() async {
        guard engine == nil, let app, let store = app.store else { return }
        loading = true
        realtimeEnabled = (try? await store.setting(Key.realtime)) == "1"
        schedulesEnabled = (try? await store.setting(Key.schedules)) == "1"
        idleScanEnabled = (try? await store.setting(Key.idleScan)).map { $0 == "1" } ?? true
        powerSavingEnabled = (try? await store.setting(Key.powerSaving)).map { $0 == "1" } ?? true
        isPaused = (try? await store.setting(Key.paused)) == "1"
        loading = false

        let engine = AutomationEngine(
            store: store,
            configuration: configuration,
            makePlanner: { [weak app] root, limitHeavy in
                await MainActor.run { app?.makePlanner(root: root, forAutomation: true, limitHeavyAnalysis: limitHeavy) }
            },
            makeExecutor: { [weak app] root in
                await app?.makeExecutor(root: root, forAutomation: true)
            },
            defaultMode: { [weak app] in await MainActor.run { app?.mode ?? .manual } }
        )
        self.engine = engine
        await engine.setPaused(isPaused)
        await engine.start()
        listenTask = Task { [weak self] in
            for await event in engine.events {
                await self?.receive(event)
            }
        }
        await refresh()
    }

    /// 明示的な終了時に監視を止める（仕様 18.4）。
    func stop() async {
        await engine?.stop()
        listenTask?.cancel()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        app?.persist(Key.paused, paused ? "1" : "0")
        Task {
            await engine?.setPaused(paused)
            await refresh()
        }
    }

    /// ワンクリック整理と同じく、監視フォルダをすぐにキューへ入れて処理する。
    func organizeWatchFoldersNow() {
        Task {
            for folder in watchFolders where folder.enabled {
                await engine?.enqueueFolder(folder.url, reason: "manual")
            }
            await engine?.processReadyTasks()
            await refresh()
        }
    }

    /// 確認待ちのファイルがあるフォルダをファイル整理画面で開く。
    func reviewPending() {
        guard let app, let root = reviewItems.first?.root else { return }
        app.selection = .organizer
        app.organizer.root = URL(filePath: root, directoryHint: .isDirectory)
        app.organizer.filter = .needsReview
        app.organizer.scanAndPlan()
    }

    // MARK: - Watch folders

    func addWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "監視する"
        panel.message = "新しく追加されたファイルを自動で整理するフォルダを選んでください（例: ダウンロード、デスクトップ）。"
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls {
                await addWatchFolder(url)
            }
        }
    }

    func addWatchFolder(_ url: URL, mode: OrganizationMode? = nil) async {
        guard let store = app?.store else { return }
        let path = url.path(percentEncoded: false)
        guard !watchFolders.contains(where: { $0.path == path }) else { return }
        try? await store.saveWatchFolder(WatchFolder(path: path, mode: mode ?? app?.mode ?? .manual))
        await reloadFolders()
    }

    func update(_ folder: WatchFolder) {
        Task {
            try? await app?.store?.saveWatchFolder(folder)
            await reloadFolders()
        }
    }

    func remove(_ folder: WatchFolder) {
        Task {
            try? await app?.store?.deleteWatchFolder(id: folder.id)
            await reloadFolders()
        }
    }

    // MARK: - Schedules

    func addSchedule() {
        guard let store = app?.store else { return }
        let target = watchFolders.first?.path ?? URL.downloadsDirectory.path(percentEncoded: false)
        let schedule = ScheduledOrganization(
            name: "定期整理",
            schedule: ScheduleSpec(weekdays: ScheduleSpec.everyDay, hour: 9, minute: 0),
            targetFolder: target
        )
        Task {
            try? await store.saveScheduledOrganization(schedule)
            await refresh()
        }
    }

    func update(_ schedule: ScheduledOrganization) {
        Task {
            try? await app?.store?.saveScheduledOrganization(schedule)
            await refresh()
        }
    }

    func remove(_ schedule: ScheduledOrganization) {
        Task {
            try? await app?.store?.deleteScheduledOrganization(id: schedule.id)
            await refresh()
        }
    }

    func chooseTarget(for schedule: ScheduledOrganization) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(filePath: schedule.targetFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = schedule
        updated.targetFolder = url.path(percentEncoded: false)
        update(updated)
    }

    // MARK: - Private

    private var configuration: AutomationEngine.Configuration {
        AutomationEngine.Configuration(
            realtimeEnabled: realtimeEnabled,
            schedulesEnabled: schedulesEnabled,
            idleScanEnabled: idleScanEnabled,
            policy: PowerPolicy(powerSavingEnabled: powerSavingEnabled)
        )
    }

    private func changed(_ key: String, _ value: Bool) {
        guard !loading else { return }
        app?.persist(key, value ? "1" : "0")
        let configuration = configuration
        Task {
            await engine?.updateConfiguration(configuration)
            await refresh()
        }
    }

    private func reloadFolders() async {
        await engine?.reloadWatchFolders()
        await refresh()
    }

    func refresh() async {
        guard let store = app?.store else { return }
        watchFolders = (try? await store.watchFolders()) ?? []
        schedules = (try? await store.scheduledOrganizations()) ?? []
        pendingCount = (try? await store.pendingTaskCount()) ?? 0
        var review = (try? await store.tasks(status: .deferred, limit: 50)) ?? []
        // 手動で整理済み・削除済みのファイルは確認待ちから外す。
        for var task in review where !FileManager.default.fileExists(atPath: task.path) {
            task.status = .completed
            try? await store.updateTask(task)
        }
        review.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        reviewItems = review
        isWatching = await engine?.isWatching ?? false
        conditions = SystemConditions.current()
    }

    private func receive(_ event: AutomationEvent) async {
        if event != .stateChanged {
            log.insert(LogEntry(date: Date(), event: event), at: 0)
            if log.count > 50 { log.removeLast(log.count - 50) }
        }
        if case .organized = event { await app?.history.reload() }
        await refresh()
    }
}

extension AutomationEvent {
    var summary: (symbol: String, text: String) {
        switch self {
        case .organized(let path, let destination):
            ("checkmark.circle", "\(URL(filePath: path).lastPathComponent) → \(URL(filePath: destination).deletingLastPathComponent().lastPathComponent)")
        case .needsReview(let path, let reason):
            ("questionmark.circle", "\(URL(filePath: path).lastPathComponent): \(reason)")
        case .skipped(let path, let reason):
            ("minus.circle", "\(URL(filePath: path).lastPathComponent): \(reason)")
        case .failed(let path, let error):
            ("exclamationmark.triangle", "\(URL(filePath: path).lastPathComponent): \(error)")
        case .stateChanged:
            ("info.circle", "")
        }
    }
}
