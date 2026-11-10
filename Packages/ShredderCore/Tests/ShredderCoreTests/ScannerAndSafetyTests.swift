import Foundation
import Testing
@testable import ShredderCore

@Suite struct ScannerTests {
    @Test func scansRecursivelyAndTreatsPackagesAsSingleItems() async throws {
        let temp = try TemporaryFolder()
        try temp.file("a.pdf")
        try temp.file("sub/b.txt")
        try temp.file("sub/deeper/c.png")
        try temp.file("Thing.app/Contents/Info.plist")
        try temp.file(".hidden")

        let result = try await FileScanner().scan(roots: [temp.url], options: ScanOptions(excludedPaths: []))
        let names = Set(result.files.map(\.name))
        #expect(names == ["a.pdf", "b.txt", "c.png", "Thing.app"])
        #expect(result.files.first { $0.name == "Thing.app" }?.isPackage == true)
    }

    @Test func doesNotFollowSymlinkLoops() async throws {
        let temp = try TemporaryFolder()
        try temp.file("sub/a.txt")
        try FileManager.default.createSymbolicLink(at: temp.url.appending(path: "sub/loop"), withDestinationURL: temp.url)

        let result = try await FileScanner().scan(roots: [temp.url], options: ScanOptions(excludedPaths: []))
        #expect(result.files.map(\.name) == ["a.txt"])
        #expect(result.skippedSymlinks == 1)
    }

    @Test func honorsExclusionsAndMaxDepth() async throws {
        let temp = try TemporaryFolder()
        try temp.file("keep/a.txt")
        try temp.file("skip/b.txt")
        try temp.file("keep/deep/c.txt")

        let result = try await FileScanner().scan(
            roots: [temp.url],
            options: ScanOptions(excludedPaths: [temp.url.appending(path: "skip").path(percentEncoded: false)], maxDepth: 1)
        )
        #expect(result.files.map(\.name) == ["a.txt"])
    }

    @Test func reportsUnchangedFilesForIncrementalScans() async throws {
        let temp = try TemporaryFolder()
        try temp.file("a.txt")
        let first = try await FileScanner().scan(roots: [temp.url], options: ScanOptions(excludedPaths: []))
        let previous = Dictionary(uniqueKeysWithValues: first.files.map { ($0.url.path(percentEncoded: false), (size: $0.size, modifiedAt: $0.modifiedAt)) })

        let second = try await FileScanner().scan(roots: [temp.url], options: ScanOptions(excludedPaths: [], previousStates: previous))
        #expect(second.unchangedPaths.count == 1)
    }

    @Test func cancellationStopsTheScan() async throws {
        let temp = try TemporaryFolder()
        for index in 0..<50 { try temp.file("f\(index).txt") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileScanner().scan(roots: [temp.url], options: ScanOptions(excludedPaths: []))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct SafetyValidatorTests {
    @Test func allowsMoveInsideAllowedRoot() throws {
        let temp = try TemporaryFolder()
        let source = try temp.file("Downloads/a.pdf")
        try temp.folder("Documents")
        let validator = SafetyValidator(allowedRoots: [temp.url])
        try validator.validateMove(from: source, to: temp.url.appending(path: "Documents/a.pdf"))
    }

    @Test func rejectsOverwriteOutsideRootsAndSystemPaths() throws {
        let temp = try TemporaryFolder()
        let source = try temp.file("a.pdf")
        try temp.file("Documents/a.pdf")
        let validator = SafetyValidator(allowedRoots: [temp.url.appending(path: "Documents")] + [temp.url])

        #expect(throws: SafetyViolation.destinationExists(ProtectedPaths.canonicalPath(temp.url.appending(path: "Documents/a.pdf")))) {
            try validator.validateMove(from: source, to: temp.url.appending(path: "Documents/a.pdf"))
        }

        let narrow = SafetyValidator(allowedRoots: [temp.url.appending(path: "Documents")])
        #expect(throws: SafetyViolation.self) {
            try narrow.validateMove(from: source, to: temp.url.appending(path: "Documents/b.pdf"))
        }

        let everything = SafetyValidator(allowedRoots: [URL(filePath: "/")])
        #expect(throws: SafetyViolation.protectedLocation("/System/Library/x")) {
            try everything.validateCreateFolder(at: URL(filePath: "/System/Library/x"))
        }
    }

    @Test func rejectsFilesStillBeingWritten() throws {
        let temp = try TemporaryFolder()
        let downloading = try temp.file("movie.mp4.crdownload")
        let fresh = try temp.file("fresh.txt", age: 0)
        let validator = SafetyValidator(allowedRoots: [temp.url])

        #expect(throws: SafetyViolation.self) {
            try validator.validateMove(from: downloading, to: temp.url.appending(path: "x.crdownload2"))
        }
        #expect(throws: SafetyViolation.self) {
            try validator.validateMove(from: fresh, to: temp.url.appending(path: "fresh2.txt"))
        }
    }

    @Test func rejectsChangesInsidePackagesAndIntoSelf() throws {
        let temp = try TemporaryFolder()
        let inner = try temp.file("Thing.app/Contents/Info.plist")
        let folder = try temp.folder("Folder")
        let validator = SafetyValidator(allowedRoots: [temp.url])

        #expect(throws: SafetyViolation.self) {
            try validator.validateMove(from: inner, to: temp.url.appending(path: "Info.plist"))
        }
        #expect(throws: SafetyViolation.self) {
            try validator.validateMove(from: folder, to: folder.appending(path: "Folder"))
        }
    }

    @Test func userLibraryIsProtectedUnlessExplicitlyAllowed() throws {
        let temp = try TemporaryFolder()
        let cache = try temp.file("Library/Caches/com.example/data")
        let home = SafetyValidator(allowedRoots: [temp.url], protectedPaths: ProtectedPaths.userProtected(home: temp.url))
        #expect(throws: SafetyViolation.self) { try home.validateTrash(cache) }

        let explicit = SafetyValidator(
            allowedRoots: [temp.url.appending(path: "Library/Caches/com.example")],
            protectedPaths: ProtectedPaths.userProtected(home: temp.url)
        )
        try explicit.validateTrash(cache)
    }
}
