import AppKit
import Foundation
import Observation
import ShredderCore

/// シュレッダーの状態（仕様 14.2）。
enum ShredderPhase: Equatable {
    case idle
    case hovering
    case analyzing
    case confirming
    case deleting
    case success
    case error(String)
}

/// 削除確認に表示する1項目。
struct TrashCandidate: Identifiable, Hashable {
    var id: String { url.path(percentEncoded: false) }
    let url: URL
    let size: Int64
    let symbol: String
    let note: String?

    init(url: URL, size: Int64, symbol: String = "doc", note: String? = nil) {
        self.url = url
        self.size = size
        self.symbol = symbol
        self.note = note
    }

    init(_ item: RelatedItem) {
        self.init(url: item.url, size: item.size, symbol: item.kind.symbol, note: item.kind.title)
    }
}

/// 削除確認シート（仕様 10.3）に渡す内容。
struct TrashConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let items: [TrashCandidate]
    let warnings: [String]
    /// ユーザーが確認画面で残した項目を受け取って実行する。
    let perform: @MainActor ([TrashCandidate]) -> Void
    var onCancel: (@MainActor () -> Void)?

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// 通常ファイルの削除フロー（シュレッダー・ストレージ分析・Finder 連携で共通）。
/// 必ず確認画面を経由し、ゴミ箱への移動だけを行う。アプリはアンインストール画面へ回す。
@MainActor
@Observable
final class TrashCoordinator {
    weak var app: AppModel?

    var phase: ShredderPhase = .idle
    var confirmation: TrashConfirmation?
    var lastResult: TrashBatchResult?
    /// 直近に削除した項目（シュレッダーの演出に使う）。
    var lastTrashedNames: [String] = []
    private var listeners: [UUID: @MainActor (Set<String>) -> Void] = [:]
    private var resetTask: Task<Void, Never>?

    /// 削除成功時に削除済みパスを受け取る。
    @discardableResult
    func onTrashed(_ handler: @escaping @MainActor (Set<String>) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func setHovering(_ hovering: Bool) {
        guard phase == .idle || phase == .hovering else { return }
        phase = hovering ? .hovering : .idle
    }

    /// ファイルやフォルダをシュレッダーへ送る。確認画面を表示するだけで、まだ削除しない。
    func request(_ urls: [URL], source: String = "シュレッダー") {
        let urls = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        guard !urls.isEmpty, let app else { return }

        // アプリは関連ファイルも含めて完全アンインストールの流れへ（仕様 9）。
        if let appURL = urls.first(where: { $0.pathExtension == "app" }) {
            phase = .idle
            app.showUninstaller(for: appURL)
            return
        }

        resetTask?.cancel()
        phase = .analyzing
        Task {
            let service = app.makeTrashService()
            let refused = service?.precheck(urls) ?? urls.map { ($0, "準備ができていません") }
            let refusedPaths = Set(refused.map { $0.url.path(percentEncoded: false) })
            let allowed = urls.filter { !refusedPaths.contains($0.path(percentEncoded: false)) }
            let candidates = await Task.detached(priority: .userInitiated) {
                allowed.map { url in
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    return TrashCandidate(
                        url: url,
                        size: RelatedFileFinder.size(of: url),
                        symbol: isDirectory ? "folder" : "doc",
                        note: isDirectory ? "フォルダ（中身も含む）" : nil
                    )
                }
            }.value

            guard !candidates.isEmpty else {
                fail(refused.first.map { "\($0.url.lastPathComponent): \($0.reason)" } ?? "削除できる項目がありません")
                return
            }
            var warnings: [String] = []
            if !refused.isEmpty {
                warnings.append("\(refused.count) 件は削除できない場所にあるため対象外です（\(refused.map(\.url.lastPathComponent).prefix(3).joined(separator: "、"))）。")
            }
            if candidates.contains(where: { $0.symbol == "folder" }) {
                warnings.append("フォルダはその中のファイルもすべてゴミ箱へ移動します。")
            }
            phase = .confirming
            confirmation = TrashConfirmation(
                title: candidates.count == 1 ? "「\(candidates[0].url.lastPathComponent)」をシュレッダーにかける" : "\(candidates.count) 項目をシュレッダーにかける",
                items: candidates,
                warnings: warnings,
                perform: { chosen in self.perform(chosen) },
                onCancel: { self.phase = .idle }
            )
        }
    }

    private func perform(_ candidates: [TrashCandidate]) {
        guard let service = app?.makeTrashService() else { return }
        phase = .deleting
        Task {
            let result = await service.trash(candidates.map(\.url))
            lastResult = result
            let trashed = Set(result.items.filter(\.succeeded).map { $0.url.path(percentEncoded: false) })
            lastTrashedNames = result.items.filter(\.succeeded).map(\.url.lastPathComponent)
            for listener in listeners.values { listener(trashed) }
            switch result.status {
            case .success:
                phase = .success
                app?.feedback.playShredding()
                Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    app?.feedback.playCompletion()
                }
                scheduleReset(after: .seconds(3))
            case .partialSuccess:
                phase = .error("\(result.failures.count) 件を移動できませんでした: \(result.failures.first?.error ?? "")")
                scheduleReset(after: .seconds(5))
            case .failed, .cancelled:
                fail(result.failures.first?.error ?? "ゴミ箱へ移動できませんでした")
            }
            await app?.history.reload()
        }
    }

    func undoLast() {
        guard let batchID = lastResult?.batchID, let engine = app?.engine else { return }
        Task {
            _ = await engine.undoBatch(batchID)
            lastResult = nil
            phase = .idle
            await app?.history.reload()
        }
    }

    private func fail(_ message: String) {
        phase = .error(message)
        scheduleReset(after: .seconds(5))
    }

    private func scheduleReset(after delay: Duration) {
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            phase = .idle
        }
    }
}
