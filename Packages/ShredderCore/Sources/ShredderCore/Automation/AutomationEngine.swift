import Foundation

public enum AutomationEvent: Sendable, Hashable {
    case organized(path: String, destination: String)
    case needsReview(path: String, reason: String)
    case skipped(path: String, reason: String)
    case failed(path: String, error: String)
    case stateChanged
}

/// 自動整理（仕様 7, 19）: リアルタイム監視・スケジュール・アイドル時スキャンで見つけたファイルを
/// 永続化したキューに入れ、書き込み完了を確認してから整理する。削除は一切行わない。
public actor AutomationEngine {
    public struct Configuration: Sendable, Hashable {
        public var realtimeEnabled: Bool
        public var schedulesEnabled: Bool
        public var idleScanEnabled: Bool
        public var policy: PowerPolicy
        /// サイズと更新日時がこの秒数変わらなければ書き込み完了とみなす（仕様 7.4）。
        public var stabilityWindow: TimeInterval
        public var idleThreshold: TimeInterval
        public var idleScanInterval: TimeInterval
        /// これ以上待っても安定しないファイルは判断保留にする。
        public var maxStabilityChecks: Int

        public init(
            realtimeEnabled: Bool = false,
            schedulesEnabled: Bool = false,
            idleScanEnabled: Bool = true,
            policy: PowerPolicy = PowerPolicy(),
            stabilityWindow: TimeInterval = 10,
            idleThreshold: TimeInterval = 300,
            idleScanInterval: TimeInterval = 3_600,
            maxStabilityChecks: Int = 120
        ) {
            self.realtimeEnabled = realtimeEnabled
            self.schedulesEnabled = schedulesEnabled
            self.idleScanEnabled = idleScanEnabled
            self.policy = policy
            self.stabilityWindow = stabilityWindow
            self.idleThreshold = idleThreshold
            self.idleScanInterval = idleScanInterval
            self.maxStabilityChecks = maxStabilityChecks
        }
    }

    /// 自動整理用のプランナーを作る。書き込み完了はこのエンジンが確認するので、
    /// プランナー側の SafetyValidator.minimumFileAge と recentActivityWindow は 0 にしてよい。
    public typealias PlannerFactory = @Sendable (_ root: URL, _ limitHeavyAnalysis: Bool) async -> OrganizationPlanner?
    public typealias ExecutorFactory = @Sendable (_ root: URL) async -> OrganizationExecutor?

    public nonisolated let events: AsyncStream<AutomationEvent>
    private let continuation: AsyncStream<AutomationEvent>.Continuation

    let store: ShredderStore
    let makePlanner: PlannerFactory
    let makeExecutor: ExecutorFactory
    let defaultMode: @Sendable () async -> OrganizationMode
    let conditions: @Sendable () -> SystemConditions

    public private(set) var configuration: Configuration
    public private(set) var isPaused = false
    public private(set) var isWatching = false
    public private(set) var watchFolders: [WatchFolder] = []
    private var watcher: FolderWatcher?
    private var loop: Task<Void, Never>?
    private var lastIdleScan: Date?

    public init(
        store: ShredderStore,
        configuration: Configuration = Configuration(),
        makePlanner: @escaping PlannerFactory,
        makeExecutor: @escaping ExecutorFactory,
        defaultMode: @escaping @Sendable () async -> OrganizationMode,
        conditions: @escaping @Sendable () -> SystemConditions = SystemConditions.current
    ) {
        self.store = store
        self.configuration = configuration
        self.makePlanner = makePlanner
        self.makeExecutor = makeExecutor
        self.defaultMode = defaultMode
        self.conditions = conditions
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(200))
    }

    // MARK: - Lifecycle

    /// 中断されたタスクを復元し、監視と定期処理を始める。
    public func start(tickInterval: Duration = .seconds(5)) async {
        try? await store.resumeInterruptedTasks()
        try? await store.pruneTasks(olderThan: Date().addingTimeInterval(-7 * 24 * 3_600))
        await reloadWatchFolders()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: tickInterval)
            }
        }
    }

    /// 明示的にアプリを終了するときは監視も止める（仕様 18.4）。
    public func stop() {
        loop?.cancel()
        loop = nil
        watcher?.stop()
        watcher = nil
        isWatching = false
        continuation.yield(.stateChanged)
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
        continuation.yield(.stateChanged)
    }

    public func updateConfiguration(_ configuration: Configuration) async {
        self.configuration = configuration
        await reloadWatchFolders()
    }

    public func reloadWatchFolders() async {
        watchFolders = ((try? await store.watchFolders()) ?? []).filter(\.enabled)
        watcher?.stop()
        watcher = nil
        isWatching = false
        if configuration.realtimeEnabled, !watchFolders.isEmpty {
            let watcher = FolderWatcher(paths: watchFolders.map { ProtectedPaths.canonicalPath($0.url) }) { [weak self] events in
                Task { await self?.handle(events) }
            }
            isWatching = watcher.start()
            self.watcher = watcher
        }
        continuation.yield(.stateChanged)
    }

    // MARK: - Intake

    /// 監視フォルダ直下のファイルの追加・変更だけを受け付ける。
    /// 整理でサブフォルダへ移したファイルは直下ではないので、自分の操作に反応し続けることはない。
    public func handle(_ events: [FileEvent], now: Date = Date()) async {
        let roots = watchFolders.map { ProtectedPaths.canonicalPath($0.url) }
        for event in events where !event.isDirectory && !event.kind.isDisjoint(with: [.created, .modified, .renamed]) {
            let url = URL(filePath: event.path)
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            let parent = ProtectedPaths.canonicalPath(url.deletingLastPathComponent())
            guard let root = roots.first(where: { $0 == parent }) else { continue }
            guard FileManager.default.fileExists(atPath: event.path) else { continue }
            try? await store.enqueue(path: event.path, root: root, reason: "realtime", notBefore: now.addingTimeInterval(configuration.stabilityWindow))
        }
    }

    /// フォルダ直下のファイルをすべてキューに入れる（スケジュール・アイドル時スキャン・ワンクリック用）。
    public func enqueueFolder(_ folder: URL, reason: String, now: Date = Date()) async {
        let root = ProtectedPaths.canonicalPath(folder)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true { continue }
            try? await store.enqueue(path: child.path(percentEncoded: false), root: root, reason: reason, notBefore: now)
        }
    }

    // MARK: - Periodic work

    public func tick(now: Date = Date()) async {
        let current = conditions()
        if isPaused || configuration.policy.shouldPause(current) { return }

        if configuration.schedulesEnabled {
            for var task in (try? await store.scheduledOrganizations()) ?? [] where task.enabled {
                guard task.schedule.isDue(lastRun: task.lastRunAt, now: now) else { continue }
                await enqueueFolder(URL(filePath: task.targetFolder, directoryHint: .isDirectory), reason: "schedule", now: now)
                task.lastRunAt = now
                try? await store.saveScheduledOrganization(task)
            }
        }

        if configuration.idleScanEnabled, !watchFolders.isEmpty,
           configuration.policy.allowsIdleScan(current, idleThreshold: configuration.idleThreshold),
           lastIdleScan.map({ now.timeIntervalSince($0) >= configuration.idleScanInterval }) ?? true {
            lastIdleScan = now
            for var folder in watchFolders {
                await enqueueFolder(folder.url, reason: "idle", now: now)
                folder.lastScanAt = now
                try? await store.saveWatchFolder(folder)
            }
        }

        _ = await processReadyTasks(now: now, conditions: current)
    }

    @discardableResult
    public func processReadyTasks(now: Date = Date(), conditions current: SystemConditions? = nil, limit: Int = 20) async -> [AutomationEvent] {
        let current = current ?? conditions()
        if isPaused || configuration.policy.shouldPause(current) { return [] }
        let limitHeavy = configuration.policy.limitsHeavyAnalysis(current)
        var produced: [AutomationEvent] = []

        for var task in (try? await store.readyTasks(now: now, limit: limit)) ?? [] {
            if Task.isCancelled || isPaused { break }
            let event = await process(&task, now: now, limitHeavy: limitHeavy)
            try? await store.updateTask(task)
            if let event {
                produced.append(event)
                continuation.yield(event)
            }
        }
        return produced
    }

    private func process(_ task: inout QueuedTask, now: Date, limitHeavy: Bool) async -> AutomationEvent? {
        let url = URL(filePath: task.path)
        guard FileManager.default.fileExists(atPath: task.path) else {
            task.status = .completed
            task.lastError = "ファイルが見つかりません"
            return nil
        }

        // 書き込み完了の判定（仕様 7.4）。判断できないものは保留する。
        switch stability(of: url, task: &task, now: now) {
        case .stable:
            break
        case .wait:
            task.attempts += 1
            if task.attempts >= configuration.maxStabilityChecks {
                task.status = .deferred
                task.lastError = "書き込みが完了しないため保留しました"
                return .needsReview(path: task.path, reason: task.lastError!)
            }
            task.notBefore = now.addingTimeInterval(configuration.stabilityWindow)
            return nil
        }

        let root = URL(filePath: task.root, directoryHint: .isDirectory)
        guard let record = FileScanner.record(for: url),
              let planner = await makePlanner(root, limitHeavy),
              let executor = await makeExecutor(root)
        else {
            task.status = .failed
            task.lastError = "整理の準備ができませんでした"
            return .failed(path: task.path, error: task.lastError!)
        }

        var mode = watchFolders.first { ProtectedPaths.canonicalPath($0.url) == task.root }?.mode
        if mode == nil { mode = await defaultMode() }
        let resolvedMode = mode ?? .manual
        task.status = .processing
        try? await store.updateTask(task)

        do {
            guard let item = try await planner.plan(files: [record], organizationRoot: root, mode: resolvedMode).first else {
                task.status = .completed
                return nil
            }
            switch item.decision {
            case .automatic:
                let report = await executor.execute([item])
                if let moved = report.moved.first {
                    task.status = .completed
                    return .organized(path: task.path, destination: moved.destinationPath ?? "")
                }
                task.status = .failed
                task.lastError = report.failures.first?.error ?? "移動できませんでした"
                return .failed(path: task.path, error: task.lastError!)
            case .needsApproval(let reason):
                task.status = .deferred
                task.lastError = reason
                return .needsReview(path: task.path, reason: reason)
            case .blocked(let reason):
                task.status = .completed
                task.lastError = reason
                return .skipped(path: task.path, reason: reason)
            case .nothingToDo:
                task.status = .completed
                return nil
            }
        } catch {
            task.status = .cancelled
            task.lastError = "キャンセルされました"
            return nil
        }
    }

    enum Stability { case stable, wait }

    private func stability(of url: URL, task: inout QueuedTask, now: Date) -> Stability {
        if SafetyValidator.temporaryExtensions.contains(url.pathExtension.lowercased()) { return .wait }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .totalFileSizeKey])
        let size = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
        let modified = values?.contentModificationDate
        let age = modified.map { now.timeIntervalSince($0) } ?? .infinity
        defer {
            task.observedSize = size
            task.observedModified = modified
        }
        // データベースに保存した日時は精度が落ちるため、1ミリ秒未満の差は同じとみなす。
        let sameDate = switch (task.observedModified, modified) {
        case (nil, nil): true
        case (let a?, let b?): abs(a.timeIntervalSince(b)) < 0.001
        default: false
        }
        let unchanged = task.observedSize == size && sameDate
        // 監視で検知したファイルは、2回観測して変化がないことを確認する。
        // スケジュールやアイドル時スキャンで見つけた古いファイルはすぐに処理してよい。
        let firstLook = task.observedSize == nil
        if firstLook && task.reason == "realtime" { return .wait }
        if age >= configuration.stabilityWindow && (firstLook || unchanged) { return .stable }
        return .wait
    }
}
