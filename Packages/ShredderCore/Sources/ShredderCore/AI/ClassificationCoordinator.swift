import CryptoKit
import Foundation

public struct ClassifiedFile: Sendable {
    public let context: ClassificationContext
    public let result: ClassificationResult
    public let assessment: ReliabilityAssessment
    /// 試したエンジンと、失敗した場合の理由。
    public let trail: [(source: AnalysisSource, note: String?)]
}

/// 分類の優先順位（仕様 8.4）に従って各エンジンを呼び分ける（仕様 3.2）。
///
/// ユーザールール → ユーザー修正 → 整理履歴 → Jev → Apple Foundation Models → 種類による推定。
/// どれも十分な信頼性に達しない場合は、最も良い候補を「要確認」として返す。
public struct ClassificationCoordinator: Sendable {
    let store: ShredderStore
    let learned: [any FileClassifier]
    let jev: (any FileClassifier)?
    let foundation: (any FileClassifier)?
    let fallback: any FileClassifier
    let evaluator = ReliabilityEvaluator()
    /// 整理履歴の学習（設定「整理履歴の学習」）。
    let learningEnabled: Bool

    public init(
        store: ShredderStore,
        jev: (any FileClassifier)?,
        foundation: (any FileClassifier)?,
        fallback: any FileClassifier = HeuristicClassifier(),
        learningEnabled: Bool = true
    ) {
        self.store = store
        var learned: [any FileClassifier] = [RuleClassifier(store: store)]
        if learningEnabled {
            learned += [CorrectionClassifier(store: store), HistoryClassifier(store: store)]
        }
        self.learned = learned
        self.jev = jev
        self.foundation = foundation
        self.fallback = fallback
        self.learningEnabled = learningEnabled
    }

    public func classify(_ context: ClassificationContext) async -> ClassifiedFile {
        var trail: [(AnalysisSource, String?)] = []
        let history = learningEnabled
            ? (try? await store.historicalDestinations(
                fileExtension: context.file.fileExtension,
                fromFolder: context.file.parentURL.path(percentEncoded: false)
            )) ?? []
            : []

        // ルール・修正・履歴は確定的なので、見つかればそのまま採用する。
        for classifier in learned {
            do {
                if let result = try await classifier.classify(context) {
                    let assessment = evaluator.assess(result, context: context, history: history)
                    if assessment.score >= ReliabilityEvaluator.acceptThreshold {
                        trail.append((classifier.source, nil))
                        return ClassifiedFile(context: context, result: result, assessment: assessment, trail: trail)
                    }
                    trail.append((classifier.source, "信頼性不足"))
                }
            } catch {
                trail.append((classifier.source, String(describing: error)))
            }
        }

        var best: (ClassificationResult, ReliabilityAssessment)?
        let fingerprint = Self.fingerprint(context)

        for classifier in [jev, foundation].compactMap({ $0 }) {
            guard await classifier.isAvailable() else {
                trail.append((classifier.source, "利用できません"))
                continue
            }
            do {
                let cacheKey = "\(classifier.source.rawValue):\(fingerprint)"
                var result = try? await store.cachedAnalysis(fingerprint: cacheKey)
                if result == nil {
                    result = try await classifier.classify(context)
                    if let result {
                        try? await store.cacheAnalysis(result, fingerprint: cacheKey, path: context.file.url.path(percentEncoded: false))
                    }
                }
                guard let result else {
                    trail.append((classifier.source, "判断できませんでした"))
                    continue
                }
                let assessment = evaluator.assess(result, context: context, history: history)
                if assessment.score >= ReliabilityEvaluator.acceptThreshold {
                    trail.append((classifier.source, nil))
                    return ClassifiedFile(context: context, result: result, assessment: assessment, trail: trail)
                }
                trail.append((classifier.source, "信頼性不足"))
                if best == nil || assessment.score > best!.1.score { best = (result, assessment) }
            } catch {
                trail.append((classifier.source, String(describing: error)))
            }
        }

        if let result = try? await fallback.classify(context) {
            let assessment = evaluator.assess(result, context: context, history: history)
            trail.append((fallback.source, nil))
            if best == nil || assessment.score > best!.1.score { best = (result, assessment) }
        }

        guard let (result, assessment) = best else {
            return ClassifiedFile(context: context, result: .undecided(reason: "どのエンジンでも分類できませんでした"), assessment: .none, trail: trail)
        }
        let flagged = ClassificationResult(
            category: result.category,
            subcategory: result.subcategory,
            suggestedDestination: result.suggestedDestination,
            confidence: result.confidence,
            reason: result.reason,
            requiresDeepAnalysis: true,
            source: result.source,
            probabilities: result.probabilities
        )
        return ClassifiedFile(context: context, result: flagged, assessment: assessment, trail: trail)
    }

    /// ファイルの状態と候補フォルダの組み合わせが同じなら同じ結果を再利用する。
    static func fingerprint(_ context: ClassificationContext) -> String {
        var parts = [
            context.file.url.path(percentEncoded: false),
            String(context.file.size),
            String(context.file.modifiedAt?.timeIntervalSince1970 ?? 0),
        ]
        parts += context.candidates.map { $0.url.path(percentEncoded: false) }.sorted()
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
