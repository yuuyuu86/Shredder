import Foundation

/// 整理先の候補になる既存フォルダ。
public struct FolderCandidate: Sendable, Hashable {
    public let url: URL
    /// 整理ルートからの相対パス（AIに渡す表示名）。
    public let relativePath: String
    public let fileCount: Int
    /// フォルダ内の代表的なファイル名（意味的な比較に使う）。
    public let sampleNames: [String]
    public let dominantKinds: [FileKind]
}

/// 分類に渡す入力。
public struct ClassificationContext: Sendable {
    public let file: FileRecord
    /// 新規フォルダを作ってよい整理ルート。
    public let organizationRoot: URL
    public let candidates: [FolderCandidate]

    public init(file: FileRecord, organizationRoot: URL, candidates: [FolderCandidate]) {
        self.file = file
        self.organizationRoot = organizationRoot
        self.candidates = candidates
    }

    /// 学習データ（user_corrections.file_category）のキー。
    public var learningKey: String {
        "\(file.kind.rawValue)@\(file.parentURL.path(percentEncoded: false))"
    }
}

/// AIエンジンの共通インターフェース（仕様 2.2「AIエンジンを交換可能な構造とする」）。
public protocol FileClassifier: Sendable {
    var source: AnalysisSource { get }
    func isAvailable() async -> Bool
    /// 判断できない場合は nil を返す。
    func classify(_ context: ClassificationContext) async throws -> ClassificationResult?
}
