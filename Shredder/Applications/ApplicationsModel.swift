import AppKit
import Foundation
import Observation
import ShredderCore

enum ApplicationsTab: String, CaseIterable, Identifiable {
    case installed
    case leftovers

    var id: String { rawValue }
    var title: String {
        switch self {
        case .installed: "インストール済み"
        case .leftovers: "削除済みアプリの残骸"
        }
    }
}

struct UninstallOutcome: Identifiable {
    let id = UUID()
    let title: String
    let report: UninstallReport
}

@MainActor
@Observable
final class ApplicationsModel {
    weak var app: AppModel?

    var tab: ApplicationsTab = .installed
    var apps: [InstalledApp] = []
    var bundleSizes: [String: Int64] = [:]
    var searchText = ""
    var selectedAppID: InstalledApp.ID?
    var isLoadingApps = false

    var plan: UninstallPlan?
    var planSelection: Set<RelatedItem.ID> = []
    var isLoadingPlan = false
    var isRunning = false

    var leftovers: [LeftoverGroup] = []
    var leftoverSelection: Set<RelatedItem.ID> = []
    var isScanningLeftovers = false
    var leftoversScanned = false

    var confirmation: TrashConfirmation?
    var outcome: UninstallOutcome?
    var errorMessage: String?
    var isWorking = false

    private var planTask: Task<Void, Never>?

    var filteredApps: [InstalledApp] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.bundleID.localizedCaseInsensitiveContains(searchText) }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    // MARK: - Installed apps

    func loadApps() async {
        guard apps.isEmpty, !isLoadingApps else { return }
        await reloadApps()
    }

    func reloadApps() async {
        isLoadingApps = true
        apps = await AppDiscovery().discover()
        isLoadingApps = false
        // 本体サイズは時間がかかるので後から順に埋める。
        let targets = apps
        Task {
            for app in targets where bundleSizes[app.id] == nil {
                let url = app.url
                let size = await Task.detached(priority: .utility) { FileScanner.allocatedSize(ofDirectory: url) }.value
                bundleSizes[app.id] = size
            }
        }
    }

    /// 指定したアプリを選択する（シュレッダーや Finder から .app が渡されたとき）。
    func select(appAt url: URL) async {
        tab = .installed
        if apps.isEmpty { await reloadApps() }
        let path = ProtectedPaths.canonicalPath(url)
        if let match = apps.first(where: { ProtectedPaths.canonicalPath($0.url) == path }) {
            select(match.id)
        } else if let single = AppDiscovery().app(at: url), !single.isAppleApp {
            apps.append(single)
            select(single.id)
        } else {
            errorMessage = "「\(url.lastPathComponent)」は削除できるアプリとして認識できませんでした。"
        }
    }

    func select(_ id: InstalledApp.ID?) {
        selectedAppID = id
        plan = nil
        planSelection = []
        planTask?.cancel()
        guard let selected = selectedApp, let uninstaller = app?.makeUninstaller() else { return }
        isLoadingPlan = true
        let all = apps
        planTask = Task {
            let plan = await uninstaller.plan(for: selected, installedApps: all)
            guard !Task.isCancelled, selectedAppID == selected.id else { return }
            self.plan = plan
            planSelection = plan.defaultSelection
            isLoadingPlan = false
            refreshRunningState()
        }
    }

    func refreshRunningState() {
        guard let selected = selectedApp else { return }
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: selected.bundleID).isEmpty
    }

    /// 実行中のアプリに終了を依頼する。強制終了はしない（仕様 9.6）。
    func requestQuit() {
        guard let selected = selectedApp else { return }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: selected.bundleID) {
            running.terminate()
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            refreshRunningState()
        }
    }

    func confirmUninstall() {
        guard let plan else { return }
        let items = plan.items.filter { planSelection.contains($0.id) && $0.isSelectable }
        var warnings: [String] = []
        if plan.items.contains(where: { if case .shared = $0.safety { planSelection.contains($0.id) } else { false } }) {
            warnings.append("他のアプリと共有しているデータが含まれています。削除すると、そのアプリの動作に影響する可能性があります。")
        }
        let adminItems = plan.items.filter { $0.safety == .requiresAdmin }
        if !adminItems.isEmpty {
            warnings.append("管理者権限が必要な \(adminItems.count) 件は削除しません。必要な場合は Finder から手動で削除してください。")
        }
        if !plan.app.isDeletable {
            warnings.append("アプリ本体の削除には管理者権限が必要です。Finder でアプリをゴミ箱へ移動してください。")
        }
        confirmation = TrashConfirmation(title: "「\(plan.app.name)」を完全に削除", items: items.map(TrashCandidate.init), warnings: warnings) { [weak self] chosen in
            guard let self else { return }
            // 確認画面で外した項目は対象から除く。
            self.planSelection = Set(chosen.map(\.id))
            self.performUninstall()
        }
    }

    private func performUninstall() {
        guard let plan, let uninstaller = app?.makeUninstaller() else { return }
        let selection = planSelection
        isWorking = true
        Task {
            do {
                let report = try await uninstaller.uninstall(plan, selection: selection)
                outcome = UninstallOutcome(title: plan.app.name, report: report)
                if report.status == .success || report.status == .partialSuccess, report.result.items.first?.succeeded == true {
                    apps.removeAll { $0.id == plan.app.id }
                    selectedAppID = nil
                    self.plan = nil
                }
            } catch {
                errorMessage = String(describing: error)
                refreshRunningState()
            }
            isWorking = false
            await app?.history.reload()
        }
    }

    // MARK: - Leftovers

    func scanLeftovers() {
        isScanningLeftovers = true
        leftoverSelection = []
        Task {
            if apps.isEmpty { await reloadApps() }
            leftovers = await LeftoverScanner(installedApps: apps).scan()
            leftoversScanned = true
            isScanningLeftovers = false
        }
    }

    func toggleGroup(_ group: LeftoverGroup, selected: Bool) {
        for item in group.items where item.isSelectable {
            if selected { leftoverSelection.insert(item.id) } else { leftoverSelection.remove(item.id) }
        }
    }

    func confirmLeftovers() {
        let items = leftovers.flatMap(\.items).filter { leftoverSelection.contains($0.id) && $0.isSelectable }
        guard !items.isEmpty else { return }
        var warnings = ["アプリ本体が見つからないだけで、不要と確定したわけではありません。別の場所にあるアプリやツールが使っている可能性があります。"]
        let recent = leftovers.filter { group in group.recentlyUsed && group.items.contains { leftoverSelection.contains($0.id) } }
        let vendorShared = leftovers.filter { group in group.relatedInstalledApp != nil && group.items.contains { leftoverSelection.contains($0.id) } }
        if !vendorShared.isEmpty {
            warnings.append("同じ開発元のアプリがインストールされている項目が含まれています。共通のサービスが使っている可能性があります: \(vendorShared.map(\.bundleID).joined(separator: ", "))")
        }
        if !recent.isEmpty {
            warnings.append("最近30日以内に更新された項目が含まれています: \(recent.map(\.bundleID).joined(separator: ", "))")
        }
        confirmation = TrashConfirmation(title: "残骸をゴミ箱へ移動", items: items.map(TrashCandidate.init), warnings: warnings) { [weak self] chosen in
            let ids = Set(chosen.map(\.id))
            self?.performLeftoverRemoval(items.filter { ids.contains($0.id) })
        }
    }

    private func performLeftoverRemoval(_ items: [RelatedItem]) {
        guard let uninstaller = app?.makeUninstaller() else { return }
        isWorking = true
        Task {
            do {
                let label = Set(items.compactMap { item in leftovers.first { $0.items.contains(item) }?.bundleID }).sorted().joined(separator: ", ")
                let report = try await uninstaller.trashLeftovers(items, label: label)
                outcome = UninstallOutcome(title: "残骸 \(items.count) 件", report: report)
                let removed = Set(report.result.items.filter(\.succeeded).map { $0.url.path(percentEncoded: false) })
                leftovers = leftovers.compactMap { group in
                    let remaining = group.items.filter { !removed.contains($0.id) }
                    return remaining.isEmpty ? nil : LeftoverGroup(bundleID: group.bundleID, items: remaining, relatedInstalledApp: group.relatedInstalledApp)
                }
                leftoverSelection.subtract(removed)
            } catch {
                errorMessage = String(describing: error)
            }
            isWorking = false
            await app?.history.reload()
        }
    }

    // MARK: - Undo

    func undo(_ outcome: UninstallOutcome) {
        guard let engine = app?.engine else { return }
        Task {
            let results = await engine.undoBatch(outcome.report.sessionID)
            let failed = results.filter { $0.1 != nil }
            errorMessage = failed.isEmpty ? nil : "\(failed.count) 件を元に戻せませんでした: \(failed.first?.1?.description ?? "")"
            self.outcome = nil
            apps = []
            await reloadApps()
            if leftoversScanned { scanLeftovers() }
            await app?.history.reload()
        }
    }
}

extension RelatedItemKind {
    var title: String {
        switch self {
        case .appBundle: "アプリ本体"
        case .caches: "キャッシュ"
        case .preferences: "設定ファイル"
        case .applicationSupport: "Application Support"
        case .logs: "ログ"
        case .savedState: "ウインドウの状態"
        case .container: "専用コンテナ"
        case .groupContainer: "グループコンテナ"
        case .webData: "Web データ"
        case .launchAgent: "Launch Agent"
        case .launchDaemon: "Launch Daemon"
        case .privilegedHelper: "特権ヘルパー"
        }
    }

    var symbol: String {
        switch self {
        case .appBundle: "app"
        case .caches: "internaldrive"
        case .preferences: "slider.horizontal.3"
        case .applicationSupport: "folder"
        case .logs: "doc.text"
        case .savedState: "macwindow"
        case .container, .groupContainer: "shippingbox"
        case .webData: "globe"
        case .launchAgent, .launchDaemon: "gearshape.2"
        case .privilegedHelper: "lock.shield"
        }
    }
}

extension MatchReason {
    var title: String {
        switch self {
        case .appBundle: "アプリ本体"
        case .bundleID: "Bundle ID が一致"
        case .bundleIDPrefix: "Bundle ID で始まる"
        case .appName: "アプリ名が一致"
        case .appGroup: "アプリの App Group"
        case .launchItemProgram: "アプリ内のプログラムを起動"
        }
    }
}
