import Foundation
import FoundationModels

@Generable
struct FolderDecision {
    @Guide(description: "The id of the chosen option, exactly as written in the option list (for example f3, keep or new)")
    var optionID: String

    @Guide(description: "Short English folder name to use if a new folder is needed, such as Invoices or Travel")
    var newFolderName: String

    @Guide(description: "One sentence in Japanese explaining why")
    var reason: String

    @Guide(description: "How sure you are, from 0 to 100", .range(0...100))
    var certainty: Int
}

/// Apple Foundation Models による二次解析（仕様 3.4）。
/// オンデバイスで動作し、Jev で判断できなかったファイルの内容を使って分類する。
public struct FoundationModelsClassifier: FileClassifier {
    static let maxOptions = 40
    static let maxExcerptCharacters = 1_500

    public let source: AnalysisSource = .foundationModels
    private let extractor: ContentExtractor

    public init(extractor: ContentExtractor = ContentExtractor()) {
        self.extractor = extractor
    }

    public static var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    public func isAvailable() async -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    public func classify(_ context: ClassificationContext) async throws -> ClassificationResult? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let excerpt = await extractor.excerpt(of: context.file.url, maxCharacters: Self.maxExcerptCharacters)
        var options: [String: FolderCandidate] = [:]
        var lines = [
            "- keep: leave it in the current folder (\(JevClassifier.relativeName(context.file.parentURL, root: context.organizationRoot)))",
            "- new: none of these fit, create a new folder",
        ]
        for (index, candidate) in context.candidates.prefix(Self.maxOptions).enumerated() {
            let id = "f\(index)"
            options[id] = candidate
            let samples = candidate.sampleNames.prefix(3).joined(separator: ", ")
            lines.append("- \(id): \(candidate.relativePath)" + (samples.isEmpty ? "" : " (e.g. \(samples))"))
        }

        let prompt = """
        File name: \(context.file.name)
        Kind: \(context.file.kind.rawValue)
        Content excerpt:
        \(excerpt ?? "(not available)")

        Options:
        \(lines.joined(separator: "\n"))
        """

        let session = LanguageModelSession(instructions: """
        You help a Mac user organize files into folders. Read the file's name and content excerpt, \
        then choose the option that best fits. Prefer existing folders. Only choose "new" when nothing fits.
        """)
        let decision = try await session.respond(to: prompt, generating: FolderDecision.self).content

        let target: URL
        switch decision.optionID {
        case JevClassifier.keepOption:
            target = context.file.parentURL
        case JevClassifier.newFolderOption:
            let name = Self.sanitizedFolderName(decision.newFolderName) ?? context.file.kind.defaultFolderName
            target = context.organizationRoot.appending(path: name, directoryHint: .isDirectory)
        default:
            // モデルが一覧にない ID を返した場合は判断不能として扱う。
            guard let candidate = options[decision.optionID] else { return nil }
            target = candidate.url
        }

        return ClassificationResult(
            category: target.lastPathComponent,
            suggestedDestination: target,
            confidence: Double(decision.certainty) / 100,
            reason: decision.reason,
            requiresDeepAnalysis: false,
            source: .foundationModels
        )
    }

    static func sanitizedFolderName(_ name: String) -> String? {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !cleaned.isEmpty, cleaned.count <= 60 else { return nil }
        return cleaned
    }
}
