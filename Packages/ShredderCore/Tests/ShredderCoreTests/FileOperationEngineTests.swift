import Foundation
import Testing
@testable import ShredderCore

@Suite struct FileOperationEngineTests {
    private func makeEngine(_ temp: TemporaryFolder) async throws -> FileOperationEngine {
        let store = try await ShredderStore.open(at: nil)
        return FileOperationEngine(store: store, validator: SafetyValidator(allowedRoots: [temp.url]), trasher: temp.fakeTrash)
    }

    @Test func moveIsRecordedAndUndoable() async throws {
        let temp = try TemporaryFolder()
        let source = try temp.file("Downloads/a.pdf")
        try temp.folder("Documents")
        let engine = try await makeEngine(temp)

        let record = try await engine.move(source, to: temp.url.appending(path: "Documents/a.pdf"))
        #expect(temp.exists("Documents/a.pdf"))
        #expect(!temp.exists("Downloads/a.pdf"))

        try await engine.undo(record)
        #expect(temp.exists("Downloads/a.pdf"))
        #expect(!temp.exists("Documents/a.pdf"))

        let stored = try #require(try await engine.store.operation(id: record.id))
        #expect(stored.status == .undone)
    }

    @Test func moveNeverOverwrites() async throws {
        let temp = try TemporaryFolder()
        let source = try temp.file("a.txt", contents: "new")
        try temp.file("Docs/a.txt", contents: "old")
        let engine = try await makeEngine(temp)

        await #expect(throws: FileOperationError.self) {
            try await engine.move(source, to: temp.url.appending(path: "Docs/a.txt"))
        }
        let kept = try String(contentsOf: temp.url.appending(path: "Docs/a.txt"), encoding: .utf8)
        #expect(kept == "old")

        let failures = try await engine.store.operations().filter { $0.status == .failed }
        #expect(failures.count == 1)
    }

    @Test func undoRefusesWhenOriginalLocationIsOccupied() async throws {
        let temp = try TemporaryFolder()
        let source = try temp.file("a.txt")
        let engine = try await makeEngine(temp)
        let record = try await engine.rename(source, to: "b.txt")
        try temp.file("a.txt", contents: "someone else")

        await #expect(throws: FileOperationError.self) { try await engine.undo(record) }
        #expect(temp.exists("b.txt"))
    }

    @Test func trashAndRestore() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("junk.txt")
        let engine = try await makeEngine(temp)

        let result = await engine.moveToTrash([file, temp.url.appending(path: "missing.txt")])
        #expect(result.status == .partialSuccess)
        #expect(result.failures.count == 1)
        #expect(!temp.exists("junk.txt"))

        let trashRecord = try #require(try await engine.store.operations().first { $0.type == .trash && $0.status == .completed })
        try await engine.undo(trashRecord)
        #expect(temp.exists("junk.txt"))
    }

    @Test func undoBatchRevertsMovesBeforeFolderCreation() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("a.png")
        let engine = try await makeEngine(temp)
        let batch = UUID()
        let folder = temp.url.appending(path: "Images", directoryHint: .isDirectory)

        try await engine.createFolder(at: folder, batchID: batch)
        try await engine.move(file, to: folder.appending(path: "a.png"), batchID: batch)

        let results = await engine.undoBatch(batch)
        #expect(results.allSatisfy { $0.1 == nil })
        #expect(temp.exists("a.png"))
        #expect(!temp.exists("Images"))
    }
}
