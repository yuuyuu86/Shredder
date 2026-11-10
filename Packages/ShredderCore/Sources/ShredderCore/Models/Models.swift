import Foundation

// MARK: - Files

/// スキャンで取得したファイル情報（仕様 4.2）。
public struct FileRecord: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let fileExtension: String
    public let size: Int64
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let contentType: String?
    public var contentHash: String?
    public let isPackage: Bool
    /// lstat の (st_dev, st_ino)。ハードリンク判定や同一性確認に使う。
    public let fileIdentity: FileIdentity?
    public let linkCount: Int?
    public let tags: [String]

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        fileExtension: String,
        size: Int64,
        createdAt: Date?,
        modifiedAt: Date?,
        contentType: String?,
        contentHash: String? = nil,
        isPackage: Bool = false,
        fileIdentity: FileIdentity? = nil,
        linkCount: Int? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.fileExtension = fileExtension
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.contentType = contentType
        self.contentHash = contentHash
        self.isPackage = isPackage
        self.fileIdentity = fileIdentity
        self.linkCount = linkCount
        self.tags = tags
    }

    public var parentURL: URL { url.deletingLastPathComponent() }
    public var kind: FileKind { FileKind(name: name, contentType: contentType, fileExtension: fileExtension) }
}

public struct FileIdentity: Hashable, Sendable, Codable {
    public let device: Int64
    public let inode: UInt64

    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

// MARK: - Classification

public enum AnalysisSource: String, Codable, Sendable, CaseIterable {
    case userRule
    case userCorrection
    case history
    case jev
    case foundationModels
    case localHeuristic
    case none
}

/// 分類結果の共通形式（仕様 3.3）。各AIエンジンの出力はこの形に変換する。
public struct ClassificationResult: Codable, Hashable, Sendable {
    public let category: String
    public let subcategory: String?
    public let suggestedDestination: URL?
    /// エンジンが返した生の信頼度。正解確率としては扱わない（仕様 3.5）。
    public let confidence: Double?
    public let reason: String
    public let requiresDeepAnalysis: Bool
    public let source: AnalysisSource
    /// 選択肢ごとの確率（Jev の Choice など、取得できる場合のみ）。
    public let probabilities: [String: Double]?

    public init(
        category: String,
        subcategory: String? = nil,
        suggestedDestination: URL?,
        confidence: Double?,
        reason: String,
        requiresDeepAnalysis: Bool,
        source: AnalysisSource,
        probabilities: [String: Double]? = nil
    ) {
        self.category = category
        self.subcategory = subcategory
        self.suggestedDestination = suggestedDestination
        self.confidence = confidence
        self.reason = reason
        self.requiresDeepAnalysis = requiresDeepAnalysis
        self.source = source
        self.probabilities = probabilities
    }

    public static func undecided(reason: String) -> ClassificationResult {
        ClassificationResult(
            category: "Unknown",
            suggestedDestination: nil,
            confidence: nil,
            reason: reason,
            requiresDeepAnalysis: false,
            source: .none
        )
    }
}

// MARK: - Organization

/// 整理アクション（仕様 5.3）。削除はここに含めない。
public enum OrganizationAction: String, Codable, Sendable {
    /// 既存フォルダへ移動する。
    case move
    /// 整理先フォルダを作成してから移動する。
    case createFolder
    /// 現在の場所に残す。
    case keep
    /// ユーザーの判断を待つ。
    case requestReview
}

public enum OrganizationMode: String, Codable, Sendable, CaseIterable {
    case manual
    case semiAutomatic
    case fullyAutomatic
}

public enum TaskStatus: String, Codable, Sendable {
    case pending
    case processing
    case deferred
    case completed
    case failed
    case cancelled
}

/// 一連の処理の結果（仕様 23）。
public enum OperationStatus: String, Codable, Sendable {
    case success
    case partialSuccess
    case failed
    case cancelled
}

// MARK: - Operations / History

public enum OperationType: String, Codable, Sendable {
    case move
    case rename
    case createFolder
    case trash
    case restore
}

public enum OperationRecordStatus: String, Codable, Sendable {
    case completed
    case failed
    case undone
}

/// operations テーブルの1行（仕様 20.4）。
public struct OperationRecord: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let batchID: UUID?
    public let type: OperationType
    public let sourcePath: String
    public let destinationPath: String?
    public var status: OperationRecordStatus
    public let createdAt: Date
    public var undoAvailable: Bool
    public let errorMessage: String?

    public init(
        id: UUID = UUID(),
        batchID: UUID? = nil,
        type: OperationType,
        sourcePath: String,
        destinationPath: String?,
        status: OperationRecordStatus,
        createdAt: Date = Date(),
        undoAvailable: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.type = type
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.status = status
        self.createdAt = createdAt
        self.undoAvailable = undoAvailable
        self.errorMessage = errorMessage
    }
}

// MARK: - Rules / Learning

/// フォルダ別の整理ルール（仕様 8.1）。指定された条件はすべて満たす必要がある。
public struct RuleCondition: Codable, Hashable, Sendable {
    public var extensions: [String]?
    public var nameContains: String?
    public var kind: FileKind?

    public init(extensions: [String]? = nil, nameContains: String? = nil, kind: FileKind? = nil) {
        self.extensions = extensions
        self.nameContains = nameContains
        self.kind = kind
    }

    public func matches(_ file: FileRecord) -> Bool {
        if extensions == nil && nameContains == nil && kind == nil { return false }
        if let extensions, !extensions.map({ $0.lowercased() }).contains(file.fileExtension.lowercased()) {
            return false
        }
        if let nameContains, !file.name.localizedCaseInsensitiveContains(nameContains) {
            return false
        }
        if let kind, file.kind != kind {
            return false
        }
        return true
    }
}

public struct OrganizationRule: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// ルールを適用する元フォルダ。
    public var folderPath: String
    public var condition: RuleCondition
    /// 移動先フォルダの絶対パス。
    public var destination: String
    public var priority: Int
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        folderPath: String,
        condition: RuleCondition,
        destination: String,
        priority: Int = 0,
        enabled: Bool = true
    ) {
        self.id = id
        self.folderPath = folderPath
        self.condition = condition
        self.destination = destination
        self.priority = priority
        self.enabled = enabled
    }
}

public struct UserCorrection: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// `FileKind` の rawValue と元フォルダを組み合わせたキー。
    public let fileCategory: String
    public let originalDestination: String?
    public let correctedDestination: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        fileCategory: String,
        originalDestination: String?,
        correctedDestination: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fileCategory = fileCategory
        self.originalDestination = originalDestination
        self.correctedDestination = correctedDestination
        self.createdAt = createdAt
    }
}
