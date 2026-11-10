import Foundation
import Testing
@testable import ShredderCore

/// 決まった結果を返す分類器。
struct FixedClassifier: FileClassifier {
    let source: AnalysisSource
    let available: Bool
    let destination: @Sendable (ClassificationContext) -> URL?
    let confidence: Double

    func isAvailable() async -> Bool { available }

    func classify(_ context: ClassificationContext) async throws -> ClassificationResult? {
        guard let url = destination(context) else { return nil }
        return ClassificationResult(
            category: url.lastPathComponent, suggestedDestination: url, confidence: confidence,
            reason: "fixed", requiresDeepAnalysis: false, source: source,
            probabilities: ["a": confidence, "b": 1 - confidence]
        )
    }
}

@Suite struct OrganizationTests {
    struct Fixture {
        let temp: TemporaryFolder
        let store: ShredderStore
        let validator: SafetyValidator
        let engine: FileOperationEngine
    }

    private func fixture() async throws -> Fixture {
        let temp = try TemporaryFolder()
        let store = try await ShredderStore.open(at: nil)
        let validator = SafetyValidator(allowedRoots: [temp.url])
        return Fixture(temp: temp, store: store, validator: validator, engine: FileOperationEngine(store: store, validator: validator, trasher: temp.fakeTrash))
    }

    private func scan(_ f: Fixture, _ folder: String) async throws -> [FileRecord] {
        try await FileScanner().scan(roots: [f.temp.url.appending(path: folder)], options: ScanOptions(excludedPaths: [], maxDepth: 0)).files
    }

    @Test func userRuleBeatsAI() async throws {
        let f = try await fixture()
        try f.temp.file("Downloads/invoice.pdf")
        let invoices = try f.temp.folder("Invoices")
        try await f.store.saveRule(OrganizationRule(
            folderPath: f.temp.url.appending(path: "Downloads").path(percentEncoded: false),
            condition: RuleCondition(nameContains: "invoice"),
            destination: invoices.path(percentEncoded: false)
        ))
        let jev = FixedClassifier(source: .jev, available: true, destination: { $0.organizationRoot.appending(path: "Other") }, confidence: 0.99)
        let coordinator = ClassificationCoordinator(store: f.store, jev: jev, foundation: nil)

        let files = try await scan(f, "Downloads")
        let classified = await coordinator.classify(ClassificationContext(file: files[0], organizationRoot: f.temp.url, candidates: []))
        #expect(classified.result.source == .userRule)
        #expect(classified.result.suggestedDestination?.lastPathComponent == "Invoices")
    }

    @Test func fallsBackToFoundationModelsWhenJevIsUnsure() async throws {
        let f = try await fixture()
        try f.temp.file("Downloads/notes.txt")
        let docs = try f.temp.folder("Docs")
        let jev = FixedClassifier(source: .jev, available: true, destination: { _ in docs }, confidence: 0.2)
        let foundation = FixedClassifier(source: .foundationModels, available: true, destination: { _ in docs }, confidence: 0.95)
        let coordinator = ClassificationCoordinator(store: f.store, jev: jev, foundation: foundation)

        let files = try await scan(f, "Downloads")
        let ctx = ClassificationContext(file: files[0], organizationRoot: f.temp.url, candidates: FolderIntelligence().candidates(in: f.temp.url))
        let classified = await coordinator.classify(ctx)
        #expect(classified.result.source == .foundationModels)
        #expect(classified.trail.map(\.source).contains(.jev))
    }

    @Test func undecidableFilesAreNotMoved() async throws {
        let f = try await fixture()
        try f.temp.file("Downloads/mystery.qqq")
        let coordinator = ClassificationCoordinator(store: f.store, jev: nil, foundation: nil)
        let planner = OrganizationPlanner(coordinator: coordinator, validator: f.validator)

        let items = try await planner.plan(files: try await scan(f, "Downloads"), organizationRoot: f.temp.url, mode: .fullyAutomatic)
        #expect(items.count == 1)
        #expect(items[0].action == .requestReview)
        #expect(items[0].decision != .automatic)
    }

    @Test func modesControlAutomaticExecution() async throws {
        let f = try await fixture()
        try f.temp.file("Downloads/photo.png")
        try f.temp.file("Images/old.png")
        let images = f.temp.url.appending(path: "Images", directoryHint: .isDirectory)
        let jev = FixedClassifier(source: .jev, available: true, destination: { _ in images }, confidence: 0.95)
        let planner = OrganizationPlanner(coordinator: ClassificationCoordinator(store: f.store, jev: jev, foundation: nil), validator: f.validator)
        let files = try await scan(f, "Downloads")

        let manual = try await planner.plan(files: files, organizationRoot: f.temp.url, mode: .manual)
        #expect(manual[0].action == .move)
        #expect(manual[0].decision == .needsApproval("手動モード"))

        let semi = try await planner.plan(files: files, organizationRoot: f.temp.url, mode: .semiAutomatic)
        #expect(semi[0].decision == .automatic)

        let report = await OrganizationExecutor(engine: f.engine, store: f.store).execute(semi.filter { $0.decision == .automatic })
        #expect(report.status == .success)
        #expect(f.temp.exists("Images/photo.png"))
    }

    @Test func semiAutomaticDoesNotCreateFoldersOnItsOwn() async throws {
        let f = try await fixture()
        try f.temp.file("Downloads/clip.mov")
        let jev = FixedClassifier(source: .jev, available: true, destination: { $0.organizationRoot.appending(path: "Videos") }, confidence: 0.95)
        let planner = OrganizationPlanner(coordinator: ClassificationCoordinator(store: f.store, jev: jev, foundation: nil), validator: f.validator)
        let files = try await scan(f, "Downloads")

        let semi = try await planner.plan(files: files, organizationRoot: f.temp.url, mode: .semiAutomatic)
        #expect(semi[0].action == .createFolder)
        #expect(semi[0].decision != .automatic)

        let full = try await planner.plan(files: files, organizationRoot: f.temp.url, mode: .fullyAutomatic)
        #expect(full[0].decision == .automatic)
        let report = await OrganizationExecutor(engine: f.engine, store: f.store).execute(full)
        #expect(report.status == .success)
        #expect(f.temp.exists("Videos/clip.mov"))

        // フォルダ作成と移動はまとめて取り消せる。
        _ = await f.engine.undoBatch(report.batchID)
        #expect(f.temp.exists("Downloads/clip.mov"))
        #expect(!f.temp.exists("Videos"))
    }

    @Test func nameCollisionsNeedApprovalAndNeverOverwrite() async throws {
        let f = try await fixture()
        try f.temp.file("Downloads/report.pdf", contents: "new")
        try f.temp.file("PDF/report.pdf", contents: "old")
        let pdf = f.temp.url.appending(path: "PDF", directoryHint: .isDirectory)
        let jev = FixedClassifier(source: .jev, available: true, destination: { _ in pdf }, confidence: 0.95)
        let planner = OrganizationPlanner(coordinator: ClassificationCoordinator(store: f.store, jev: jev, foundation: nil), validator: f.validator)

        let items = try await planner.plan(files: try await scan(f, "Downloads"), organizationRoot: f.temp.url, mode: .fullyAutomatic)
        guard case .nameCollision(_, let suggested) = items[0].conflict else {
            Issue.record("conflict expected")
            return
        }
        #expect(suggested == "report 2.pdf")
        #expect(items[0].decision == .needsApproval("移動先に同名のファイルがあります"))

        let executor = OrganizationExecutor(engine: f.engine, store: f.store)
        let blocked = await executor.execute(items)
        #expect(blocked.status == .failed)

        let renamed = await executor.execute(items, renamedTo: [items[0].id: suggested])
        #expect(renamed.status == .success)
        #expect(try String(contentsOf: pdf.appending(path: "report.pdf"), encoding: .utf8) == "old")
        #expect(f.temp.exists("PDF/report 2.pdf"))
    }

    @Test func correctionsAndHistoryAreLearned() async throws {
        let f = try await fixture()
        let first = try f.temp.file("Downloads/a.zip")
        let archive = try f.temp.folder("Stuff/Zips")
        let coordinator = ClassificationCoordinator(store: f.store, jev: nil, foundation: nil)
        let planner = OrganizationPlanner(coordinator: coordinator, validator: f.validator)
        let executor = OrganizationExecutor(engine: f.engine, store: f.store)

        // ユーザーが整理先を変更 → 修正を記録して実行。
        var items = try await planner.plan(files: try await scan(f, "Downloads"), organizationRoot: f.temp.url, mode: .manual)
        await executor.recordCorrection(for: items[0], correctedFolder: archive)
        items[0] = planner.reevaluate(items[0], destinationFolder: archive, mode: .manual)
        _ = await executor.execute(items)
        #expect(!FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))

        // 次の zip は修正内容から同じ場所が提案される。
        try f.temp.file("Downloads/b.zip")
        let next = try await planner.plan(files: try await scan(f, "Downloads"), organizationRoot: f.temp.url, mode: .manual)
        #expect(next[0].classification.source == .userCorrection)
        #expect(next[0].destinationFolder?.lastPathComponent == "Zips")
    }
}
