import Foundation

/// アプリ以外の通常ファイル・フォルダをゴミ箱へ移す（シュレッダー・ストレージ分析・Finder 連携から使う）。
///
/// 許可範囲はホームフォルダと外部ボリューム。~/Library やシステム領域、Shredder 自身は対象外で、
/// アプリやその関連データは `AppUninstaller` を通して削除する。呼び出し前に必ずユーザー承認を得ること。
public struct TrashService: Sendable {
    let engine: FileOperationEngine
    let home: URL

    public init(engine: FileOperationEngine, home: URL = URL.homeDirectory) {
        self.engine = engine
        self.home = home
    }

    public var validator: SafetyValidator {
        var protected = ProtectedPaths.system + ProtectedPaths.userProtected(home: home)
        protected.append(Bundle.main.bundleURL.path(percentEncoded: false))
        return SafetyValidator(
            allowedRoots: [home, URL(filePath: "/Volumes", directoryHint: .isDirectory)],
            protectedPaths: protected,
            minimumFileAge: 0
        )
    }

    /// 削除前に、対象外になる項目を理由つきで返す。
    public func precheck(_ urls: [URL]) -> [(url: URL, reason: String)] {
        let validator = validator
        return urls.compactMap { url -> (url: URL, reason: String)? in
            do {
                try validator.validateTrash(url)
                return nil
            } catch {
                return (url, String(describing: error))
            }
        }
    }

    public func trash(_ urls: [URL], batchID: UUID = UUID()) async -> TrashBatchResult {
        await engine.moveToTrash(urls, batchID: batchID, validator: validator)
    }
}
