import Foundation
import Testing
@testable import ShredderCore

@Suite struct AutomationTests {
    struct Fixture {
        let temp: TemporaryFolder
        let store: ShredderStore
        let engine: AutomationEngine
        var downloads: URL { temp.url.appending(path: "Downloads", directoryHint: .isDirectory) }
    }

    private func fixture(mode: OrganizationMode = .semiAutomatic, conditions: SystemConditions = SystemConditions(), config: AutomationEngine.Configuration = .init()) async throws -> Fixture {
        let temp = try TemporaryFolder()
        let store = try await ShredderStore.open(at: nil)
        let downloads = try temp.folder("Downloads")
        try temp.file("Downloads/Images/existing.png")
        try await store.saveWatchFolder(WatchFolder(path: downloads.path(percentEncoded: false), mode: mode))
        let images = downloads.appending(path: "Images", directoryHint: .isDirectory)
        let fileEngine = FileOperationEngine(store: store, validator: SafetyValidator(allowedRoots: [temp.url]), trasher: temp.fakeTrash)
        let engine = AutomationEngine(
            store: store,
            configuration: config,
            makePlanner: { root, _ in
                let jev = FixedClassifier(source: .jev, available: true, destination: { _ in images }, confidence: 0.95)
                return OrganizationPlanner(
                    coordinator: ClassificationCoordinator(store: store, jev: jev, foundation: nil),
                    validator: SafetyValidator(allowedRoots: [root], minimumFileAge: 0),
                    recentActivityWindow: 0
                )
            },
            makeExecutor: { root in
                OrganizationExecutor(engine: fileEngine, store: store, validator: SafetyValidator(allowedRoots: [root], minimumFileAge: 0))
            },
            defaultMode: { .manual },
            conditions: { conditions }
        )
        await engine.reloadWatchFolders()
        return Fixture(temp: temp, store: store, engine: engine)
    }

    @Test func organizesStableFilesFromWatchedFolder() async throws {
        let f = try await fixture()
        let photo = try f.temp.file("Downloads/photo.png", age: 600)
        await f.engine.handle([FileEvent(path: photo.path(percentEncoded: false), kind: .created, isDirectory: false)])

        // 1回目は観測のみ、2回目で変化がなければ整理する。
        let start = Date().addingTimeInterval(11)
        #expect(await f.engine.processReadyTasks(now: start).isEmpty)
        let events = await f.engine.processReadyTasks(now: start.addingTimeInterval(11))
        #expect(events.count == 1)
        guard case .organized = events.first else {
            Issue.record("expected organized, got \(events)")
            return
        }
        #expect(f.temp.exists("Downloads/Images/photo.png"))
    }

    @Test func waitsUntilWritesFinish() async throws {
        let f = try await fixture()
        let fresh = try f.temp.file("Downloads/fresh.png", age: 0)
        let downloading = try f.temp.file("Downloads/movie.mp4.crdownload", age: 600)
        await f.engine.handle([
            FileEvent(path: fresh.path(percentEncoded: false), kind: .created, isDirectory: false),
            FileEvent(path: downloading.path(percentEncoded: false), kind: .created, isDirectory: false),
        ])

        // 安定待ちの間は移動しない。
        let now = Date().addingTimeInterval(11)
        #expect(await f.engine.processReadyTasks(now: now).isEmpty)
        #expect(f.temp.exists("Downloads/fresh.png"))

        // 書き込みが止まって一定時間たてば整理される。ダウンロード中のファイルは残る。
        let later = now.addingTimeInterval(11)
        let events = await f.engine.processReadyTasks(now: later)
        #expect(events.count == 1)
        #expect(f.temp.exists("Downloads/Images/fresh.png"))
        #expect(f.temp.exists("Downloads/movie.mp4.crdownload"))
    }

    @Test func manualModeOnlyQueuesForReviewAndIgnoresSubfolders() async throws {
        let f = try await fixture(mode: .manual)
        let photo = try f.temp.file("Downloads/photo.png", age: 600)
        let nested = try f.temp.file("Downloads/Images/other.png", age: 600)
        await f.engine.handle([
            FileEvent(path: photo.path(percentEncoded: false), kind: .created, isDirectory: false),
            FileEvent(path: nested.path(percentEncoded: false), kind: .created, isDirectory: false),
        ])

        let start = Date().addingTimeInterval(11)
        _ = await f.engine.processReadyTasks(now: start)
        let events = await f.engine.processReadyTasks(now: start.addingTimeInterval(11))
        #expect(events.count == 1)
        guard case .needsReview = events.first else {
            Issue.record("expected review")
            return
        }
        #expect(f.temp.exists("Downloads/photo.png"))
        #expect(try await f.store.tasks(status: .deferred).count == 1)
    }

    @Test func pausesOnLowPowerBatteryAndThermalPressure() async throws {
        let f = try await fixture(conditions: SystemConditions(onBattery: true, lowPowerMode: true))
        let photo = try f.temp.file("Downloads/photo.png", age: 600)
        await f.engine.handle([FileEvent(path: photo.path(percentEncoded: false), kind: .created, isDirectory: false)])
        #expect(await f.engine.processReadyTasks(now: Date().addingTimeInterval(10)).isEmpty)
        #expect(try await f.store.pendingTaskCount() == 1)

        await f.engine.setPaused(true)
        #expect(await f.engine.processReadyTasks(now: Date().addingTimeInterval(10)).isEmpty)
    }

    @Test func queueSurvivesRestart() async throws {
        let f = try await fixture()
        let photo = try f.temp.file("Downloads/photo.png", age: 600)
        try await f.store.enqueue(path: photo.path(percentEncoded: false), root: ProtectedPaths.canonicalPath(f.downloads), reason: "test", notBefore: Date())
        var task = try #require(try await f.store.readyTasks(now: Date(), limit: 1).first)
        task.status = .processing
        try await f.store.updateTask(task)

        try await f.store.resumeInterruptedTasks()
        #expect(try await f.store.pendingTaskCount() == 1)
        // 同じパスを重複して登録しない。
        try await f.store.enqueue(path: photo.path(percentEncoded: false), root: "x", reason: "dup", notBefore: Date())
        #expect(try await f.store.pendingTaskCount() == 1)
    }

    @Test func schedulesRunWhenDueAndCatchUpOnce() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let spec = ScheduleSpec(weekdays: [2], hour: 9, minute: 0) // 毎週月曜 9:00
        let monday9 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
        #expect(spec.isDue(lastRun: nil, now: monday9.addingTimeInterval(60), calendar: calendar))
        #expect(!spec.isDue(lastRun: monday9.addingTimeInterval(60), now: monday9.addingTimeInterval(3_600), calendar: calendar))
        #expect(spec.isDue(lastRun: monday9.addingTimeInterval(60), now: monday9.addingTimeInterval(7 * 86_400 + 60), calendar: calendar))
        #expect(spec.nextFire(after: monday9, calendar: calendar) == monday9.addingTimeInterval(7 * 86_400))

        let f = try await fixture(config: .init(schedulesEnabled: true, idleScanEnabled: false))
        try f.temp.file("Downloads/photo.png", age: 600)
        try await f.store.saveScheduledOrganization(ScheduledOrganization(
            name: "毎日", schedule: ScheduleSpec(weekdays: ScheduleSpec.everyDay, hour: 0, minute: 0),
            targetFolder: f.downloads.path(percentEncoded: false)
        ))
        await f.engine.tick(now: Date())
        #expect(f.temp.exists("Downloads/Images/photo.png"))
        let saved = try await f.store.scheduledOrganizations()
        #expect(saved.first?.lastRunAt != nil)
    }

    @Test func folderWatcherReportsNewFiles() async throws {
        let temp = try TemporaryFolder()
        let received = Mutex<[FileEvent]>([])
        let watcher = FolderWatcher(paths: [ProtectedPaths.canonicalPath(temp.url)], latency: 0.1) { events in
            received.withLock { $0 += events }
        }
        #expect(watcher.start())
        try await Task.sleep(for: .milliseconds(300))
        try temp.file("new.txt", age: 0)
        for _ in 0..<50 {
            if received.withLock({ $0.contains { $0.path.hasSuffix("new.txt") } }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        watcher.stop()
        #expect(received.withLock { $0.contains { $0.path.hasSuffix("new.txt") && $0.kind.contains(.created) } })
    }
}

import Synchronization
