import AppKit
import Foundation

/// Finder 連携（仕様 17）。
/// - 右クリック > サービス（クイックアクション）「Shredderで削除」
/// - Dock アイコンへのドロップ / 「このアプリケーションで開く」
/// どちらも削除確認画面を開くだけで、直接削除はしない。
@MainActor
final class FinderServiceProvider: NSObject {
    static let shared = FinderServiceProvider()

    /// Info.plist の NSServices > NSMessage と同じ名前。
    @objc func shredFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "ファイルを受け取れませんでした" as NSString
            return
        }
        handle(urls: urls)
    }

    func handle(urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        let app = AppModel.shared
        app.showMainWindow()
        Task {
            // 起動直後の場合はデータベースの準備を待つ。
            await app.start()
            app.selection = .home
            app.trash.request(files, source: "Finder")
        }
    }
}
