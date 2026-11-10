import Foundation
import Testing
@testable import ShredderCore

@Suite struct StoreTests {
    @Test func migrationCreatesAllSpecTables() async throws {
        let store = try await ShredderStore.open(at: nil)
        let rows = try await store.database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
        let names = Set(rows.compactMap { $0.string("name") })
        let expected: Set<String> = [
            "files", "classifications", "operations", "organization_rules", "user_corrections",
            "watch_folders", "uninstall_sessions", "uninstall_items", "analysis_cache",
            "scheduled_tasks", "application_settings",
        ]
        #expect(expected.isSubset(of: names))
        #expect(try await store.database.userVersion() == Schema.migrations.count)
    }

    @Test func operationsRoundTrip() async throws {
        let store = try await ShredderStore.open(at: nil)
        let record = OperationRecord(
            type: .move,
            sourcePath: "/Users/me/Downloads/a.pdf",
            destinationPath: "/Users/me/Documents/a.pdf",
            status: .completed,
            undoAvailable: true
        )
        try await store.insertOperation(record)
        try await store.updateOperation(id: record.id, status: .undone, undoAvailable: false)

        let loaded = try #require(try await store.operation(id: record.id))
        #expect(loaded.type == .move)
        #expect(loaded.status == .undone)
        #expect(loaded.undoAvailable == false)
    }

    @Test func historicalDestinationsOnlyCountDirectChildren() async throws {
        let store = try await ShredderStore.open(at: nil)
        for name in ["a", "b"] {
            try await store.insertOperation(OperationRecord(
                type: .move, sourcePath: "/d/Downloads/\(name).pdf",
                destinationPath: "/d/Documents/PDF/\(name).pdf", status: .completed, undoAvailable: true
            ))
        }
        try await store.insertOperation(OperationRecord(
            type: .move, sourcePath: "/d/Downloads/sub/c.pdf",
            destinationPath: "/d/Elsewhere/c.pdf", status: .completed, undoAvailable: true
        ))

        let history = try await store.historicalDestinations(fileExtension: "PDF", fromFolder: "/d/Downloads")
        #expect(history.count == 1)
        #expect(history.first?.folder == "/d/Documents/PDF/")
        #expect(history.first?.count == 2)
    }

    @Test func rulesAndSettingsPersist() async throws {
        let store = try await ShredderStore.open(at: nil)
        let rule = OrganizationRule(
            folderPath: "/d/Downloads",
            condition: RuleCondition(extensions: ["pdf"], nameContains: "invoice"),
            destination: "/d/Invoices",
            priority: 10
        )
        try await store.saveRule(rule)
        #expect(try await store.rules(enabledOnly: true) == [rule])

        try await store.setSetting("mode", "manual")
        try await store.setSetting("mode", "semiAutomatic")
        #expect(try await store.setting("mode") == "semiAutomatic")
    }
}

@Suite struct LearningDataTests {
    @Test func clearingLearningDataKeepsRulesAndHistory() async throws {
        let store = try await ShredderStore.open(at: nil)
        try await store.insertCorrection(UserCorrection(fileCategory: "pdf@/d/", originalDestination: nil, correctedDestination: "/d/PDF"))
        try await store.saveRule(OrganizationRule(folderPath: "/d", condition: RuleCondition(extensions: ["pdf"]), destination: "/d/PDF"))
        try await store.insertOperation(OperationRecord(type: .move, sourcePath: "/a", destinationPath: "/b", status: .completed, undoAvailable: true))

        #expect(try await store.correctionCount() == 1)
        try await store.clearLearningData()
        #expect(try await store.correctionCount() == 0)
        #expect(try await store.rules().count == 1)
        #expect(try await store.operations().count == 1)
    }
}
