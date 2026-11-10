import Foundation

public enum RiskLevel: Int, Comparable, Sendable {
    case low
    case medium
    case high

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PlanConflict: Sendable, Hashable {
    /// 移動先に同名の項目がある。上書きはせず、別名を提案する。
    case nameCollision(existing: URL, suggestedName: String)
}

public enum ExecutionDecision: Sendable, Hashable {
    /// 現在のモードで自動実行してよい。
    case automatic
    /// ユーザーの承認が必要。
    case needsApproval(String)
    /// 実行しない（保護領域など）。
    case blocked(String)
    /// 何もしない（keep）。
    case nothingToDo
}

/// 整理プレビューの1行（仕様 5.4）。
public struct PlanItem: Identifiable, Sendable {
    public let id: UUID
    public let file: FileRecord
    public var action: OrganizationAction
    public var destinationFolder: URL?
    public var classification: ClassificationResult
    public var assessment: ReliabilityAssessment
    public var risk: RiskLevel
    public var conflict: PlanConflict?
    public var decision: ExecutionDecision
    public let trail: [(source: AnalysisSource, note: String?)]

    /// 実際の移動先（衝突時はユーザーが別名を承認するまで nil）。
    public var destinationURL: URL? {
        guard let destinationFolder, action == .move || action == .createFolder else { return nil }
        if conflict != nil { return nil }
        return destinationFolder.appending(path: file.name)
    }
}

/// スキャン結果から整理プランを作る（仕様 3.2 Organization Plan → Safety Validation → Execution Policy）。
public struct OrganizationPlanner: Sendable {
    let coordinator: ClassificationCoordinator
    let validator: SafetyValidator
    let folderIntelligence: FolderIntelligence
    /// AI 解析の同時実行数（仕様 24.1）。
    let maxConcurrentClassifications: Int
    /// この秒数以内に変更されたファイルは「作業中かもしれない」として危険度を上げる。
    /// 書き込み完了を確認済みの自動整理では 0 にする。
    let recentActivityWindow: TimeInterval

    public init(
        coordinator: ClassificationCoordinator,
        validator: SafetyValidator,
        folderIntelligence: FolderIntelligence = FolderIntelligence(),
        maxConcurrentClassifications: Int = 4,
        recentActivityWindow: TimeInterval = 300
    ) {
        self.coordinator = coordinator
        self.validator = validator
        self.folderIntelligence = folderIntelligence
        self.maxConcurrentClassifications = maxConcurrentClassifications
        self.recentActivityWindow = recentActivityWindow
    }

    @concurrent
    public func plan(
        files: [FileRecord],
        organizationRoot: URL,
        mode: OrganizationMode,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [PlanItem] {
        let candidates = folderIntelligence.candidates(in: organizationRoot)
        let targets = files.filter { validator.isSafeToOrganize($0) }
        let skipped = files.filter { !validator.isSafeToOrganize($0) }

        var items: [PlanItem] = []
        try await withThrowingTaskGroup(of: PlanItem.self) { group in
            var iterator = targets.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                let context = ClassificationContext(file: file, organizationRoot: organizationRoot, candidates: candidates)
                group.addTask {
                    let classified = await coordinator.classify(context)
                    return makeItem(classified, mode: mode)
                }
                return true
            }
            while running < maxConcurrentClassifications, addNext() { running += 1 }
            while let item = try await group.next() {
                try Task.checkCancellation()
                items.append(item)
                progress?(items.count, targets.count)
                if !addNext() { running -= 1 }
            }
        }

        items += skipped.map { file in
            PlanItem(
                id: UUID(), file: file, action: .keep, destinationFolder: nil,
                classification: .undecided(reason: "書き込み中・保護領域などの理由で整理対象外です"),
                assessment: .none, risk: .high, conflict: nil,
                decision: .blocked("整理対象外"), trail: []
            )
        }
        return items.sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
    }

    /// ユーザーが整理先を変更した後などに、行を再評価する。
    public func reevaluate(_ item: PlanItem, destinationFolder: URL?, mode: OrganizationMode) -> PlanItem {
        var updated = item
        updated.destinationFolder = destinationFolder
        updated.action = Self.action(for: item.file, destination: destinationFolder)
        updated.conflict = Self.conflict(for: item.file, in: destinationFolder)
        updated.risk = risk(for: item.file, action: updated.action)
        updated.decision = decide(updated, mode: mode)
        return updated
    }

    // MARK: - Private

    func makeItem(_ classified: ClassifiedFile, mode: OrganizationMode) -> PlanItem {
        let file = classified.context.file
        let destination = classified.result.suggestedDestination
        let action: OrganizationAction = classified.result.source == .none
            ? .requestReview
            : Self.action(for: file, destination: destination)
        var item = PlanItem(
            id: UUID(),
            file: file,
            action: action,
            destinationFolder: destination,
            classification: classified.result,
            assessment: classified.assessment,
            risk: risk(for: file, action: action),
            conflict: Self.conflict(for: file, in: destination),
            decision: .nothingToDo,
            trail: classified.trail
        )
        item.decision = decide(item, mode: mode)
        return item
    }

    static func action(for file: FileRecord, destination: URL?) -> OrganizationAction {
        guard let destination else { return .requestReview }
        if ProtectedPaths.canonicalPath(destination) == ProtectedPaths.canonicalPath(file.parentURL) { return .keep }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? .move : .createFolder
    }

    static func conflict(for file: FileRecord, in folder: URL?) -> PlanConflict? {
        guard let folder else { return nil }
        let target = folder.appending(path: file.name)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return nil }
        return .nameCollision(existing: target, suggestedName: uniqueName(for: file.name, in: folder))
    }

    /// 「name 2.ext」形式で空いている名前を探す（Finder と同じ規則）。
    public static func uniqueName(for name: String, in folder: URL) -> String {
        let url = URL(filePath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for index in 2...999 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !FileManager.default.fileExists(atPath: folder.appending(path: candidate).path(percentEncoded: false)) {
                return candidate
            }
        }
        return "\(base) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// 操作の危険度（仕様 6.2「操作の危険度も利用する」）。
    func risk(for file: FileRecord, action: OrganizationAction) -> RiskLevel {
        if file.isPackage || file.kind == .application { return .high }
        if file.size > 2 * 1024 * 1024 * 1024 { return .high }
        if let modified = file.modifiedAt, Date().timeIntervalSince(modified) < recentActivityWindow { return .medium }
        if action == .createFolder { return .medium }
        return .low
    }

    func decide(_ item: PlanItem, mode: OrganizationMode) -> ExecutionDecision {
        switch item.action {
        case .keep:
            return .nothingToDo
        case .requestReview:
            return .needsApproval("AI が整理先を判断できませんでした")
        case .move, .createFolder:
            break
        }
        if let destination = item.destinationURL ?? item.destinationFolder {
            do {
                if item.action == .createFolder, let folder = item.destinationFolder {
                    try validator.validateCreateFolder(at: folder)
                }
                if item.conflict == nil {
                    try validator.validateMove(from: item.file.url, to: item.destinationURL ?? destination)
                }
            } catch {
                return .blocked(error.description)
            }
        }
        if item.conflict != nil {
            return .needsApproval("移動先に同名のファイルがあります")
        }

        switch mode {
        case .manual:
            return .needsApproval("手動モード")
        case .semiAutomatic:
            if item.assessment.level == .high && item.risk == .low && item.action == .move {
                return .automatic
            }
            return .needsApproval(item.assessment.level == .high ? "新しいフォルダの作成または危険度のある操作です" : "判断が曖昧です")
        case .fullyAutomatic:
            if item.assessment.level >= .medium && item.assessment.score >= ReliabilityEvaluator.acceptThreshold && item.risk < .high {
                return .automatic
            }
            return .needsApproval("確実ではないため自動では移動しません")
        }
    }
}
