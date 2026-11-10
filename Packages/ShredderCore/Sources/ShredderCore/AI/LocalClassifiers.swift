import Foundation

/// ユーザーの明示的な整理ルール（優先度1）。
public struct RuleClassifier: FileClassifier {
    public let source: AnalysisSource = .userRule
    let store: ShredderStore

    public init(store: ShredderStore) { self.store = store }

    public func isAvailable() async -> Bool { true }

    public func classify(_ context: ClassificationContext) async throws -> ClassificationResult? {
        let filePath = ProtectedPaths.canonicalPath(context.file.url)
        let rules = try await store.rules(enabledOnly: true)
        guard let rule = rules.first(where: {
            ProtectedPaths.path(filePath, isInside: ProtectedPaths.canonicalPath(URL(filePath: $0.folderPath)))
                && $0.condition.matches(context.file)
        }) else { return nil }
        let destination = URL(filePath: rule.destination, directoryHint: .isDirectory)
        return ClassificationResult(
            category: destination.lastPathComponent,
            suggestedDestination: destination,
            confidence: 1,
            reason: "整理ルールに一致しました",
            requiresDeepAnalysis: false,
            source: .userRule
        )
    }
}

/// 過去のユーザー修正から学習した整理先（優先度2）。
public struct CorrectionClassifier: FileClassifier {
    public let source: AnalysisSource = .userCorrection
    let store: ShredderStore

    public init(store: ShredderStore) { self.store = store }

    public func isAvailable() async -> Bool { true }

    public func classify(_ context: ClassificationContext) async throws -> ClassificationResult? {
        guard let latest = try await store.corrections(forCategory: context.learningKey, limit: 1).first else { return nil }
        let destination = URL(filePath: latest.correctedDestination, directoryHint: .isDirectory)
        return ClassificationResult(
            category: destination.lastPathComponent,
            suggestedDestination: destination,
            confidence: 1,
            reason: "以前あなたが同じ種類のファイルの整理先をここへ変更しました",
            requiresDeepAnalysis: false,
            source: .userCorrection
        )
    }
}

/// 整理履歴のパターン（優先度3）。
public struct HistoryClassifier: FileClassifier {
    public let source: AnalysisSource = .history
    let store: ShredderStore
    /// 学習に使う最低件数。
    let minimumCount: Int

    public init(store: ShredderStore, minimumCount: Int = 2) {
        self.store = store
        self.minimumCount = minimumCount
    }

    public func isAvailable() async -> Bool { true }

    public func classify(_ context: ClassificationContext) async throws -> ClassificationResult? {
        let history = try await store.historicalDestinations(
            fileExtension: context.file.fileExtension,
            fromFolder: context.file.parentURL.path(percentEncoded: false)
        )
        guard let top = history.first, top.count >= minimumCount else { return nil }
        let total = history.reduce(0) { $0 + $1.count }
        let ratio = Double(top.count) / Double(total)
        let destination = URL(filePath: top.folder, directoryHint: .isDirectory)
        return ClassificationResult(
            category: destination.lastPathComponent,
            suggestedDestination: destination,
            confidence: ratio,
            reason: "このフォルダの .\(context.file.fileExtension.lowercased()) ファイルは過去\(total)件中\(top.count)件が「\(destination.lastPathComponent)」へ整理されています",
            requiresDeepAnalysis: false,
            source: .history
        )
    }
}

/// AI が使えない場合の最後の手段。ファイルの種類と既存フォルダ名だけで提案する。
/// 信頼度は低く評価されるため、自動実行には使われない。
public struct HeuristicClassifier: FileClassifier {
    public let source: AnalysisSource = .localHeuristic

    public init() {}

    public func isAvailable() async -> Bool { true }

    public func classify(_ context: ClassificationContext) async throws -> ClassificationResult? {
        let kind = context.file.kind
        if FolderIntelligence.nameMatches(context.file.parentURL, kind: kind) {
            return ClassificationResult(
                category: kind.defaultFolderName,
                suggestedDestination: context.file.parentURL,
                confidence: 0.6,
                reason: "現在のフォルダ名がファイルの種類と一致しています",
                requiresDeepAnalysis: true,
                source: .localHeuristic
            )
        }
        let existing = context.candidates.first { FolderIntelligence.nameMatches($0.url, kind: kind) }
            ?? context.candidates.first { $0.dominantKinds.first == kind && $0.fileCount >= 3 }
        if let existing {
            return ClassificationResult(
                category: kind.defaultFolderName,
                suggestedDestination: existing.url,
                confidence: 0.5,
                reason: "既存フォルダ「\(existing.relativePath)」に同じ種類のファイルがまとまっています",
                requiresDeepAnalysis: true,
                source: .localHeuristic
            )
        }
        guard kind != .other else { return nil }
        return ClassificationResult(
            category: kind.defaultFolderName,
            suggestedDestination: context.organizationRoot.appending(path: kind.defaultFolderName, directoryHint: .isDirectory),
            confidence: 0.4,
            reason: "ファイルの種類（\(kind.defaultFolderName)）から新しいフォルダを提案しました",
            requiresDeepAnalysis: true,
            source: .localHeuristic
        )
    }
}
