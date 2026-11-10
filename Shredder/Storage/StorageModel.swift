import AppKit
import Foundation
import Observation
import ShredderCore

enum StorageTab: String, CaseIterable, Identifiable {
    case overview
    case treemap
    case largeFiles
    case duplicates
    case leftovers

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "概要"
        case .treemap: "ツリーマップ"
        case .largeFiles: "大容量ファイル"
        case .duplicates: "重複ファイル"
        case .leftovers: "アプリ残骸"
        }
    }
}

/// 分析対象（仕様 4.1: 指定フォルダ / Mac 全体のアクセス可能な領域）。
enum StorageTarget: Equatable {
    case home
    case wholeMac
    case folder(URL)

    var url: URL {
        switch self {
        case .home: URL.homeDirectory
        case .wholeMac: URL(filePath: "/", directoryHint: .isDirectory)
        case .folder(let url): url
        }
    }

    var title: String {
        switch self {
        case .home: "ホームフォルダ"
        case .wholeMac: "Mac 全体（アクセス可能な範囲）"
        case .folder(let url): url.lastPathComponent
        }
    }
}

@MainActor
@Observable
final class StorageModel {
    weak var app: AppModel?

    var tab: StorageTab = .overview
    var target: StorageTarget = .home
    var volume: VolumeInfo? = VolumeInfo.current()
    var analysis: StorageAnalysis?
    var duplicates: [DuplicateGroup] = []
    var lastAnalyzedAt: Date?

    var isAnalyzing = false
    var isFindingDuplicates = false
    var progressText = ""
    var message: String?

    /// ツリーマップで表示中のフォルダ（パンくず）。
    var treemapPath: [StorageNode] = []
    var largeFileSelection: Set<StorageFile.ID> = []
    var duplicateSelection: Set<StorageFile.ID> = []
    /// 分析後にゴミ箱へ移動した項目（表示から除く）。
    var removedPaths: Set<String> = []

    private var task: Task<Void, Never>?

    var currentNode: StorageNode? { treemapPath.last ?? analysis?.root }

    var largeFiles: [StorageFile] {
        (analysis?.largeFiles ?? []).filter { !removedPaths.contains($0.id) }
    }

    var visibleDuplicates: [DuplicateGroup] {
        duplicates.compactMap { group in
            let files = group.files.filter { !removedPaths.contains($0.id) }
            return files.count > 1 ? DuplicateGroup(hash: group.hash, size: group.size, files: files) : nil
        }
    }

    var duplicateReclaimable: Int64 { visibleDuplicates.reduce(0) { $0 + $1.reclaimableSize } }

    func attach() {
        app?.trash.onTrashed { [weak self] paths in
            self?.removedPaths.formUnion(paths)
            self?.duplicateSelection.subtract(paths)
            self?.largeFileSelection.subtract(paths)
            self?.volume = VolumeInfo.current()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "分析"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        target = .folder(url)
        analyze()
    }

    func analyze() {
        task?.cancel()
        isAnalyzing = true
        message = nil
        duplicates = []
        removedPaths = []
        treemapPath = []
        progressText = "分析中…"
        volume = VolumeInfo.current()
        let root = target.url
        let options = StorageOptions(excludedPaths: ProtectedPaths.defaultScanExclusions())
        task = Task {
            do {
                let result = try await StorageAnalyzer().analyze(root: root, options: options) { files, bytes in
                    Task { @MainActor in
                        self.progressText = "分析中… \(files.formatted()) 件 / \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
                    }
                }
                analysis = result
                lastAnalyzedAt = Date()
                app?.recordStorageAnalysis(result)
                if !result.inaccessible.isEmpty {
                    message = "\(result.inaccessible.count) 件のフォルダにアクセスできませんでした。フルディスクアクセスを許可すると、より正確に分析できます。"
                }
                isAnalyzing = false
                findDuplicates()
            } catch is CancellationError {
                isAnalyzing = false
                message = "キャンセルしました。"
            } catch {
                isAnalyzing = false
                message = "分析に失敗しました: \(error)"
            }
        }
    }

    func findDuplicates() {
        guard let candidates = analysis?.duplicateCandidates else { return }
        isFindingDuplicates = true
        task = Task {
            do {
                let groups = try await DuplicateFinder().findDuplicates(in: candidates) { done, total in
                    Task { @MainActor in self.progressText = "重複を確認中… \(done) / \(total)" }
                }
                duplicates = groups
                // 既定では各グループの最も古いファイルを残し、それ以外を選択する。
                duplicateSelection = Set(groups.flatMap { $0.files.dropFirst().map(\.id) })
            } catch {
                if !(error is CancellationError) { message = "重複の確認に失敗しました: \(error)" }
            }
            isFindingDuplicates = false
            progressText = ""
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Treemap navigation

    func drillDown(_ node: StorageNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        treemapPath.append(node)
    }

    func goUp(to index: Int?) {
        if let index { treemapPath = Array(treemapPath.prefix(index + 1)) } else { treemapPath = [] }
    }

    // MARK: - Send to shredder

    func shred(_ urls: [URL]) {
        app?.trash.request(urls, source: "ストレージ分析")
    }

    func shredSelectedDuplicates() {
        let urls = visibleDuplicates.flatMap(\.files).filter { duplicateSelection.contains($0.id) }.map(\.url)
        // 各グループで最低1つは残す。
        let groupsLosingAll = visibleDuplicates.filter { group in group.files.allSatisfy { duplicateSelection.contains($0.id) } }
        if !groupsLosingAll.isEmpty {
            message = "\(groupsLosingAll.count) 個のグループですべてのコピーが選択されています。少なくとも1つは残してください。"
            return
        }
        shred(urls)
    }
}
