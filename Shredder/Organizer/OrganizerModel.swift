import AppKit
import Foundation
import Observation
import ShredderCore

/// 1行ごとのユーザー判断（仕様 6.1）。
enum ReviewState: String {
    case undecided
    case approved
    case held
    case excluded
}

enum PlanFilter: String, CaseIterable, Identifiable {
    case all
    case needsReview
    case automatic
    case blocked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "すべて"
        case .needsReview: "確認待ち"
        case .automatic: "自動実行可"
        case .blocked: "対象外"
        }
    }
}

@MainActor
@Observable
final class OrganizerModel {
    weak var app: AppModel?

    var root: URL?
    var includeSubfolders = false
    var items: [PlanItem] = []
    var review: [UUID: ReviewState] = [:]
    /// 名前の衝突を承認した行の新しい名前。
    var renames: [UUID: String] = [:]
    var selection: Set<PlanItem.ID> = []
    var filter: PlanFilter = .all

    var isWorking = false
    var progressText = ""
    /// 進捗表示（0=スキャン, 1=分類, 2=整理）。
    var stage = 0
    var stageTitle = ""
    var fraction: Double?
    var currentName = ""
    /// 直前の整理で動かしたファイル（完了アニメーション用）。
    var justOrganized = 0
    var message: String?
    var lastBatchID: UUID?
    private var task: Task<Void, Never>?

    var visibleItems: [PlanItem] {
        items.filter { item in
            switch filter {
            case .all: true
            case .needsReview: if case .needsApproval = item.decision { true } else { false }
            case .automatic: item.decision == .automatic
            case .blocked: if case .blocked = item.decision { true } else { false }
            }
        }
    }

    var selectedItem: PlanItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    var approvedCount: Int { review.values.filter { $0 == .approved }.count }
    var automaticCount: Int { items.filter { $0.decision == .automatic && review[$0.id] != .excluded && review[$0.id] != .held }.count }

    // MARK: - Actions

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "このフォルダを整理"
        panel.message = "整理するフォルダを選んでください。Shredder はこのフォルダの中だけを変更します。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        items = []
        review = [:]
        app?.rememberRoot(url)
    }

    var candidateCount: Int {
        items.filter { ($0.action == .move || $0.action == .createFolder) && review[$0.id] != .excluded }.count
    }

    /// ワンクリック整理（仕様 7.1）: スキャンし、手動モード以外では自動実行可の項目をそのまま整理する。
    func oneClickOrganize() {
        guard root != nil else {
            chooseFolder()
            guard root != nil else { return }
            oneClickOrganize()
            return
        }
        scanAndPlan { [weak self] in
            guard let self, let app = self.app, app.mode != .manual else { return }
            if self.automaticCount > 0 { self.execute(includeAutomatic: true) }
        }
    }

    func scanAndPlan(then completion: (@MainActor () -> Void)? = nil) {
        guard let root, let app, let planner = app.makePlanner(root: root) else { return }
        let mode = app.mode
        let includeSubfolders = includeSubfolders
        task?.cancel()
        isWorking = true
        message = nil
        progressText = "スキャン中…"
        stage = 0
        stageTitle = "フォルダをスキャンしています"
        fraction = nil
        currentName = root.lastPathComponent
        items = []
        review = [:]
        renames = [:]

        task = Task {
            do {
                let scan = try await FileScanner().scan(
                    roots: [root],
                    options: ScanOptions(excludedPaths: [], maxDepth: includeSubfolders ? nil : 0)
                ) { progress in
                    Task { @MainActor in
                        self.progressText = "スキャン中… \(progress.filesVisited) 件"
                        self.currentName = "\(progress.filesVisited) 件のファイルを確認"
                    }
                }
                try? await app.store?.upsertFiles(scan.files)
                progressText = "分類中… 0 / \(scan.files.count)"
                stage = 1
                stageTitle = "AI がファイルを分類しています"
                fraction = 0
                currentName = "\(scan.files.count) 件を分類"
                let plan = try await planner.plan(files: scan.files, organizationRoot: root, mode: mode) { done, total in
                    Task { @MainActor in
                        self.progressText = "分類中… \(done) / \(total)"
                        self.fraction = total > 0 ? Double(done) / Double(total) : 1
                        self.currentName = "\(done) / \(total) 件"
                    }
                }
                items = plan
                app.recordOrganizerScan(candidates: candidateCount)
                if !scan.inaccessible.isEmpty {
                    message = "\(scan.inaccessible.count) 件の項目にアクセスできませんでした。"
                }
                isWorking = false
                progressText = ""
                completion?()
                return
            } catch is CancellationError {
                message = "キャンセルしました。"
            } catch {
                message = "スキャンに失敗しました: \(error)"
            }
            isWorking = false
            progressText = ""
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// シュレッダーで削除したファイルを一覧から外す。
    func attach() {
        app?.trash.onTrashed { [weak self] paths in
            self?.items.removeAll { paths.contains($0.file.url.path(percentEncoded: false)) }
        }
    }

    func setReview(_ state: ReviewState, for ids: Set<PlanItem.ID>) {
        for id in ids { review[id] = state }
    }

    var visibleIDs: Set<PlanItem.ID> { Set(visibleItems.map(\.id)) }

    func selectAllVisible() { selection = visibleIDs }
    func deselectAll() { selection = [] }

    func approveAllSuggestions() {
        for item in items where item.action == .move || item.action == .createFolder {
            if case .blocked = item.decision { continue }
            if item.conflict != nil { continue }
            if review[item.id] == nil || review[item.id] == .undecided { review[item.id] = .approved }
        }
    }

    func acceptSuggestedName(for item: PlanItem) {
        guard case .nameCollision(_, let suggested) = item.conflict else { return }
        renames[item.id] = suggested
        review[item.id] = .approved
    }

    /// 整理先を変更し、学習データとして記録する（仕様 8.1 の2）。
    func changeDestination(for item: PlanItem) {
        guard let root, let app else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = item.destinationFolder ?? root
        panel.prompt = "ここへ移動"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard let planner = app.makePlanner(root: root), let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = planner.reevaluate(item, destinationFolder: folder, mode: app.mode)
        review[item.id] = .approved
        if app.learningEnabled {
            Task {
                await app.makeExecutor(root: root)?.recordCorrection(for: item, correctedFolder: folder)
            }
        }
    }

    /// 承認済みの行と、現在のモードで自動実行してよい行を実行する。
    func execute(includeAutomatic: Bool) {
        guard let root, let app else { return }
        let targets = items.filter { item in
            switch review[item.id] ?? .undecided {
            case .approved: return true
            case .held, .excluded: return false
            case .undecided: return includeAutomatic && item.decision == .automatic
            }
        }
        guard !targets.isEmpty else { return }
        let renames = renames
        isWorking = true
        progressText = "整理しています…"
        stage = 2
        stageTitle = "ファイルを整理しています"
        fraction = 0
        currentName = ""
        Task {
            guard let executor = await app.makeExecutor(root: root) else { return }
            let report = await executor.execute(targets, renamedTo: renames) { done, total, name in
                Task { @MainActor in
                    self.fraction = total > 0 ? Double(done) / Double(total) : 1
                    self.currentName = name.isEmpty ? "完了" : name
                }
            }
            justOrganized = report.moved.count
            lastBatchID = report.batchID
            let done = Set(report.moved.map(\.sourcePath))
            items.removeAll { done.contains($0.file.url.path(percentEncoded: false)) }
            switch report.status {
            case .success: message = "\(report.moved.count) 件を整理しました。"
            case .partialSuccess: message = "\(report.moved.count) 件を整理しました。\(report.failures.count) 件は移動できませんでした: \(report.failures.first?.error ?? "")"
            case .failed: message = "整理できませんでした: \(report.failures.first?.error ?? "")"
            case .cancelled: message = "キャンセルしました。"
            }
            isWorking = false
            progressText = ""
            await app.history.reload()
        }
    }

    func undoLastBatch() {
        guard let batchID = lastBatchID, let engine = app?.engine else { return }
        Task {
            let results = await engine.undoBatch(batchID)
            let failed = results.filter { $0.1 != nil }
            message = failed.isEmpty ? "直前の整理を元に戻しました。" : "\(failed.count) 件を元に戻せませんでした: \(failed.first?.1?.description ?? "")"
            lastBatchID = nil
            await app?.history.reload()
            scanAndPlan()
        }
    }
}
