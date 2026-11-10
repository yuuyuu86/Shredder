import Foundation

/// Jev による一次分類アダプター（仕様 3.3, 27.1）。
///
/// Jev はクラウドAPIのため、ファイルの内容は送らずメタデータ（ファイル名・拡張子・種類・
/// サイズ・更新日・フォルダ名）だけを送る（仕様 22.1 との整合）。
public struct JevClassifier: FileClassifier {
    public static let keepOption = "keep"
    public static let newFolderOption = "new"
    static let maxFolderOptions = 200

    /// 新規フォルダを作るときのフォルダ名の候補。
    public static let newFolderCategories: [String: String] = [
        "Documents": "General documents and letters",
        "PDF": "PDF files that fit no more specific category",
        "Invoices": "Invoices, bills, receipts, payment statements",
        "Contracts": "Contracts, agreements, legal or official forms",
        "Manuals": "Manuals, guides, specifications",
        "Images": "Photos and pictures",
        "Screenshots": "Screen captures",
        "Videos": "Video files and screen recordings",
        "Audio": "Music, voice memos, audio recordings",
        "Archives": "Compressed archives (zip, tar, etc.)",
        "Installers": "Installers and disk images (.dmg, .pkg)",
        "Spreadsheets": "Spreadsheets and data tables",
        "Presentations": "Slide decks",
        "Code": "Source code and scripts",
        "Text": "Plain text notes",
        "Other": "Anything else",
    ]

    public let source: AnalysisSource = .jev
    private let client: JevClient?

    public init(client: JevClient?) {
        self.client = client
    }

    public func isAvailable() async -> Bool { client != nil }

    public func classify(_ context: ClassificationContext) async throws -> ClassificationResult? {
        guard let client else { throw JevError.notConfigured }
        let (request, folderOptions) = Self.makeRequest(for: context)
        let response = try await client.evaluate(request)
        return Self.result(from: response, context: context, folderOptions: folderOptions)
    }

    // MARK: - Mapping (テストから使えるよう static)

    static func makeRequest(for context: ClassificationContext) -> (JevRequest, [String: FolderCandidate]) {
        let file = context.file
        var options: [String: String?] = [
            keepOption: "Leave the file where it is (current folder: \(relativeName(file.parentURL, root: context.organizationRoot)))",
            newFolderOption: "None of the existing folders fits; a new folder is needed",
        ]
        var folderOptions: [String: FolderCandidate] = [:]
        for (index, candidate) in context.candidates.prefix(maxFolderOptions).enumerated() {
            let id = "f\(index)"
            folderOptions[id] = candidate
            var description = "Existing folder \"\(candidate.relativePath)\" with \(candidate.fileCount) files"
            if !candidate.sampleNames.isEmpty {
                description += ", e.g. " + candidate.sampleNames.prefix(5).joined(separator: ", ")
            }
            options[id] = description
        }

        var fileState: [String: JSONValue] = [
            "name": .string(file.name),
            "extension": .string(file.fileExtension.lowercased()),
            "kind": .string(file.kind.rawValue),
            "size_bytes": .number(Double(file.size)),
            "current_folder": .string(relativeName(file.parentURL, root: context.organizationRoot)),
        ]
        if let modified = file.modifiedAt {
            fileState["modified"] = .string(ISO8601DateFormatter().string(from: modified))
        }
        if !file.tags.isEmpty {
            fileState["finder_tags"] = .array(file.tags.map(JSONValue.string))
        }

        let request = JevRequest(
            state: .object(["file": .object(fileState)]),
            questions: [
                "destination": .choice(
                    "A Mac user is tidying up their files. Pick the folder this file belongs in. Prefer an existing folder whose name or contents match the file. Choose \"keep\" if the current folder already fits.",
                    options: options
                ),
                "category": .choice(
                    "If a new folder had to be created for this file, which name fits best?",
                    options: newFolderCategories.mapValues { Optional($0) }
                ),
            ]
        )
        return (request, folderOptions)
    }

    static func result(from response: JevResponse, context: ClassificationContext, folderOptions: [String: FolderCandidate]) -> ClassificationResult? {
        guard let destination = response.answers["destination"], let choice = destination.choice else { return nil }
        let category = response.answers["category"]?.choice ?? context.file.kind.defaultFolderName
        let target: URL
        let reason: String
        switch choice {
        case keepOption:
            target = context.file.parentURL
            reason = "Jev は現在のフォルダが適切だと判断しました"
        case newFolderOption:
            target = context.organizationRoot.appending(path: category, directoryHint: .isDirectory)
            reason = "Jev は既存フォルダに合うものがないと判断し、「\(category)」フォルダを提案しました"
        default:
            guard let candidate = folderOptions[choice] else { return nil }
            target = candidate.url
            reason = "Jev はファイル名と種類から既存フォルダ「\(candidate.relativePath)」が最も合うと判断しました"
        }
        // 選択肢IDのままでは表示に使えないため、確率のキーをフォルダ名へ置き換える。
        let probabilities = destination.probabilities.map { raw in
            Dictionary(uniqueKeysWithValues: raw.map { key, value in
                (folderOptions[key]?.relativePath ?? key, value)
            })
        }
        return ClassificationResult(
            category: category,
            subcategory: nil,
            suggestedDestination: target,
            confidence: destination.confidence,
            reason: reason,
            requiresDeepAnalysis: false,
            source: .jev,
            probabilities: probabilities
        )
    }

    static func relativeName(_ url: URL, root: URL) -> String {
        let path = ProtectedPaths.canonicalPath(url)
        let rootPath = ProtectedPaths.canonicalPath(root)
        guard ProtectedPaths.path(path, isInside: rootPath) else { return url.lastPathComponent }
        let relative = path.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? root.lastPathComponent : relative
    }
}
