import Foundation

public enum ReliabilityLevel: Int, Comparable, Sendable, Codable {
    case low
    case medium
    case high

    public static func < (lhs: ReliabilityLevel, rhs: ReliabilityLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ReliabilityAssessment: Sendable, Hashable {
    public let score: Double
    public let factors: [String]

    public var level: ReliabilityLevel {
        if score >= ReliabilityEvaluator.highThreshold { return .high }
        if score >= ReliabilityEvaluator.mediumThreshold { return .medium }
        return .low
    }

    public static let none = ReliabilityAssessment(score: 0, factors: ["判断できませんでした"])
}

/// AI が返す信頼度をそのまま信じず、複数の根拠を組み合わせて評価する（仕様 3.5）。
public struct ReliabilityEvaluator: Sendable {
    static let highThreshold = 0.75
    static let mediumThreshold = 0.5
    /// これ以上なら次の段階の解析に進まない（仕様 3.2「Classification Reliable?」）。
    public static let acceptThreshold = 0.6

    public init() {}

    public func assess(
        _ result: ClassificationResult,
        context: ClassificationContext,
        history: [(folder: String, count: Int)]
    ) -> ReliabilityAssessment {
        var factors: [String] = []
        var score: Double

        switch result.source {
        case .userRule:
            return ReliabilityAssessment(score: 1, factors: ["明示的な整理ルール"])
        case .userCorrection:
            return ReliabilityAssessment(score: 0.9, factors: ["過去のユーザー修正"])
        case .history:
            let total = history.reduce(0) { $0 + $1.count }
            let top = history.first?.count ?? 0
            let volume = min(1, Double(top) / 3)
            score = min(0.9, (result.confidence ?? 0) * volume)
            factors.append("整理履歴 \(top)/\(total) 件が一致")
            return ReliabilityAssessment(score: score, factors: factors)
        case .jev:
            let confidence = result.confidence ?? 0.5
            score = confidence
            factors.append(String(format: "Jev の信頼度 %.0f%%", confidence * 100))
            if let probabilities = result.probabilities?.values.sorted(by: >), probabilities.count >= 2 {
                let margin = probabilities[0] - probabilities[1]
                score = 0.6 * confidence + 0.4 * margin
                factors.append(String(format: "候補間の差 %.0f%%", margin * 100))
            }
        case .foundationModels:
            // 言語モデルの自己申告は過信しやすいため上限を設ける。
            let confidence = min(result.confidence ?? 0.5, 0.8)
            score = confidence * 0.9
            factors.append("Apple Intelligence による内容解析")
        case .localHeuristic:
            score = min(result.confidence ?? 0.4, 0.55)
            factors.append("ファイルの種類のみで推定")
        case .none:
            return .none
        }

        guard let destination = result.suggestedDestination else { return .none }
        let destinationPath = ProtectedPaths.canonicalPath(destination)

        if context.candidates.contains(where: { ProtectedPaths.canonicalPath($0.url) == destinationPath })
            || destinationPath == ProtectedPaths.canonicalPath(context.file.parentURL) {
            score += 0.1
            factors.append("既存フォルダ")
        }
        if FolderIntelligence.nameMatches(destination, kind: context.file.kind) {
            score += 0.05
            factors.append("フォルダ名と種類が一致")
        }
        if let top = history.first {
            if ProtectedPaths.canonicalPath(URL(filePath: top.folder)) == destinationPath {
                score += 0.1
                factors.append("整理履歴と一致")
            } else if top.count >= 3 {
                score -= 0.15
                factors.append("整理履歴と不一致")
            }
        }
        return ReliabilityAssessment(score: min(max(score, 0), 1), factors: factors)
    }
}
