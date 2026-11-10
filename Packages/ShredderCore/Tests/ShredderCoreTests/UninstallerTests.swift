import Foundation
import Testing
@testable import ShredderCore

@Suite struct UninstallerTests {
    /// 一時フォルダ内に偽の Applications と Library を作る。
    struct Fixture {
        let temp: TemporaryFolder
        let locations: LibraryLocations
        let store: ShredderStore
        let engine: FileOperationEngine

        var applications: URL { temp.url.appending(path: "Applications", directoryHint: .isDirectory) }

        @discardableResult
        func makeApp(_ name: String, bundleID: String, program: String = "") throws -> URL {
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": "1.0"]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let url = applications.appending(path: "\(name).app", directoryHint: .isDirectory)
            try temp.folder("Applications/\(name).app/Contents/MacOS")
            try data.write(to: url.appending(path: "Contents/Info.plist"))
            try Data("binary".utf8).write(to: url.appending(path: "Contents/MacOS/\(name)"))
            return url
        }

        func discovery(groups: [String: [String]] = [:]) -> AppDiscovery {
            AppDiscovery(searchRoots: [applications], excludedBundleIDs: []) { url in
                let name = url.deletingPathExtension().lastPathComponent
                return (nil, groups[name] ?? [])
            }
        }

        func uninstaller(running: Set<String> = []) -> AppUninstaller {
            AppUninstaller(store: store, engine: engine, locations: locations) { running.contains($0) }
        }
    }

    private func fixture() async throws -> Fixture {
        let temp = try TemporaryFolder()
        let store = try await ShredderStore.open(at: nil)
        let engine = FileOperationEngine(store: store, validator: SafetyValidator(allowedRoots: []), trasher: temp.fakeTrash)
        let locations = LibraryLocations(
            userLibrary: temp.url.appending(path: "Home/Library", directoryHint: .isDirectory),
            systemLibrary: temp.url.appending(path: "SystemLibrary", directoryHint: .isDirectory)
        )
        try temp.folder("Applications")
        return Fixture(temp: temp, locations: locations, store: store, engine: engine)
    }

    @Test func discoversAppsAndSkipsSystemApps() async throws {
        let f = try await fixture()
        try f.makeApp("Sketchy", bundleID: "com.example.sketchy")
        try f.makeApp("Notes Helper", bundleID: "com.apple.noteshelper")
        try f.temp.folder("Applications/Utilities")
        try FileManager.default.moveItem(
            at: try f.makeApp("Tool", bundleID: "com.example.tool"),
            to: f.applications.appending(path: "Utilities/Tool.app")
        )

        let apps = await f.discovery().discover()
        #expect(apps.map(\.bundleID) == ["com.example.sketchy", "com.example.tool"])
        #expect(apps.first?.version == "1.0")
    }

    @Test func findsDedicatedFilesAndProtectsSharedOnes() async throws {
        let f = try await fixture()
        try f.makeApp("Sketchy", bundleID: "com.example.sketchy")
        try f.makeApp("Sketchy Pro", bundleID: "com.example.sketchy.pro")
        try f.makeApp("Other", bundleID: "com.other.app")
        try f.temp.file("Home/Library/Caches/com.example.sketchy/cache.db")
        try f.temp.file("Home/Library/Preferences/com.example.sketchy.plist")
        try f.temp.file("Home/Library/Preferences/ByHost/com.example.sketchy.0F0B4D3C-1A2B-4C5D-8E9F-001122334455.plist")
        try f.temp.file("Home/Library/Application Support/Sketchy/data.json")
        try f.temp.file("Home/Library/Saved Application State/com.example.sketchy.savedState/window.data")
        try f.temp.file("Home/Library/Containers/com.example.sketchy/Data/x")
        try f.temp.file("Home/Library/Caches/com.example.sketchy.pro/cache.db")
        try f.temp.file("Home/Library/Group Containers/TEAM.sketchy/shared.db")
        try f.temp.file("Home/Library/Group Containers/TEAM.private/own.db")
        try f.temp.file("Home/Library/Documents-like/Sketchy notes.txt")
        try f.temp.file("SystemLibrary/LaunchDaemons/com.example.sketchy.helper.plist")

        let apps = await f.discovery(groups: ["Sketchy": ["TEAM.sketchy", "TEAM.private"], "Sketchy Pro": ["TEAM.sketchy"]]).discover()
        let sketchy = try #require(apps.first { $0.bundleID == "com.example.sketchy" })
        let plan = await f.uninstaller().plan(for: sketchy, installedApps: apps)
        let byName = Dictionary(plan.items.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(plan.items.contains { $0.kind == .container && $0.safety == .safe })

        #expect(byName["Sketchy.app"]?.kind == .appBundle)
        #expect(byName["com.example.sketchy"]?.safety == .safe)
        #expect(byName["com.example.sketchy.plist"]?.match == .bundleID)
        #expect(byName["com.example.sketchy.0F0B4D3C-1A2B-4C5D-8E9F-001122334455.plist"]?.match == .bundleIDPrefix)
        #expect(byName["Sketchy"]?.match == .appName)
        #expect(byName["com.example.sketchy.savedState"] != nil)
        #expect(byName["TEAM.private"]?.safety == .safe)
        // 共有されている App Group と、別アプリ (Pro) の項目は既定で除外。
        #expect(byName["TEAM.sketchy"]?.selectedByDefault == false)
        #expect(byName["com.example.sketchy.pro"]?.selectedByDefault == false)
        // システム領域は管理者権限が必要なので選べない。
        #expect(byName["com.example.sketchy.helper.plist"]?.isSelectable == false)
        // ユーザーデータは対象外。
        #expect(byName["Sketchy notes.txt"] == nil)
    }

    @Test func uninstallMovesSelectedItemsToTrashAndRecordsSession() async throws {
        let f = try await fixture()
        try f.makeApp("Sketchy", bundleID: "com.example.sketchy")
        try f.temp.file("Home/Library/Caches/com.example.sketchy/cache.db")
        try f.temp.file("Home/Library/Logs/com.example.sketchy/app.log")

        let apps = await f.discovery().discover()
        let plan = await f.uninstaller().plan(for: apps[0], installedApps: apps)
        let report = try await f.uninstaller().uninstall(plan, selection: plan.defaultSelection)

        #expect(report.status == .success)
        #expect(!f.temp.exists("Applications/Sketchy.app"))
        #expect(!f.temp.exists("Home/Library/Caches/com.example.sketchy"))
        let items = try await f.store.uninstallItems(sessionID: report.sessionID)
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.status == "trashed" })

        // 履歴からまとめて元に戻せる。
        _ = await f.engine.undoBatch(report.sessionID)
        #expect(f.temp.exists("Applications/Sketchy.app"))
        #expect(f.temp.exists("Home/Library/Logs/com.example.sketchy/app.log"))
    }

    @Test func refusesWhileAppIsRunning() async throws {
        let f = try await fixture()
        try f.makeApp("Sketchy", bundleID: "com.example.sketchy")
        let apps = await f.discovery().discover()
        let uninstaller = f.uninstaller(running: ["com.example.sketchy"])
        let plan = await uninstaller.plan(for: apps[0], installedApps: apps)

        await #expect(throws: UninstallError.appRunning("Sketchy")) {
            try await uninstaller.uninstall(plan, selection: plan.defaultSelection)
        }
        #expect(f.temp.exists("Applications/Sketchy.app"))
    }

    @Test func keepsDataWhenTheAppBundleCannotBeTrashed() async throws {
        let f = try await fixture()
        let app = try f.makeApp("Sketchy", bundleID: "com.example.sketchy")
        try f.temp.file("Home/Library/Caches/com.example.sketchy/cache.db")
        let apps = await f.discovery().discover()
        let plan = await f.uninstaller().plan(for: apps[0], installedApps: apps)
        // 本体を先に消して移動を失敗させる。
        try FileManager.default.removeItem(at: app)

        let report = try await f.uninstaller().uninstall(plan, selection: plan.defaultSelection)
        #expect(report.status == .failed)
        #expect(f.temp.exists("Home/Library/Caches/com.example.sketchy/cache.db"))
    }

    @Test func detectsLeftoversOfRemovedApps() async throws {
        let f = try await fixture()
        try f.makeApp("Sketchy", bundleID: "com.example.sketchy")
        try f.temp.file("Home/Library/Caches/com.example.sketchy/a")
        try f.temp.file("Home/Library/Caches/com.example.sketchy.helper/a")
        try f.temp.file("Home/Library/Caches/com.gone.oldapp/a", contents: String(repeating: "x", count: 5000))
        try f.temp.file("Home/Library/Preferences/com.gone.oldapp.plist")
        try f.temp.file("Home/Library/Caches/com.apple.Safari/a")
        try f.temp.file("Home/Library/Caches/com.elsewhere.app/a")
        try f.temp.file("Home/Library/Caches/com.example.updater/a")
        try f.temp.file("Home/Library/Caches/org.swift.swiftpm/a")
        try f.temp.file("Home/Library/Application Support/Random Folder/a")

        let apps = await f.discovery().discover()
        let scanner = LeftoverScanner(locations: f.locations, installedApps: apps) { $0 == "com.elsewhere.app" }
        let groups = await scanner.scan()

        #expect(groups.map(\.bundleID) == ["com.gone.oldapp", "com.example.updater"])
        #expect(groups.first?.items.count == 2)
        #expect(groups.first?.relatedInstalledApp == nil)
        #expect(groups.last?.relatedInstalledApp == "Sketchy")

        let report = try await f.uninstaller().trashLeftovers(groups[0].items, label: groups[0].bundleID)
        #expect(report.status == .success)
        #expect(!f.temp.exists("Home/Library/Preferences/com.gone.oldapp.plist"))
    }

    @Test func parsesBundleIDsFromLibraryEntryNames() {
        #expect(LeftoverScanner.bundleID(fromEntryName: "com.example.App.plist") == "com.example.App")
        #expect(LeftoverScanner.bundleID(fromEntryName: "com.example.App.0F0B4D3C-1A2B-4C5D-8E9F-001122334455.plist") == "com.example.App")
        #expect(LeftoverScanner.bundleID(fromEntryName: "com.example.App.savedState") == "com.example.App")
        #expect(LeftoverScanner.bundleID(fromEntryName: "Google") == nil)
        #expect(LeftoverScanner.bundleID(fromEntryName: "v1.2.3") == nil)
        #expect(LeftoverScanner.bundleID(fromEntryName: "My App.v2.data") == nil)
    }
}
