import CoreGraphics
import Foundation
import Testing
@testable import ShredderCore

@Suite struct StorageTests {
    @Test func analyzesFolderSizesKindsAndLargeFiles() async throws {
        let temp = try TemporaryFolder()
        try temp.file("Movies/big.mov", contents: String(repeating: "m", count: 300_000))
        try temp.file("Docs/a.txt", contents: "small")
        try temp.file("Docs/b.txt", contents: "small")
        let hard = temp.url.appending(path: "Movies/hardlink.mov")
        try FileManager.default.linkItem(at: temp.url.appending(path: "Movies/big.mov"), to: hard)

        let analysis = try await StorageAnalyzer().analyze(
            root: temp.url,
            options: StorageOptions(excludedPaths: [], minimumNodeSize: 100_000, largeFileThreshold: 200_000, minimumDuplicateSize: 1)
        )
        let movies = try #require(analysis.root.children.first { $0.name == "Movies" })
        // ハードリンクは1回だけ数える。
        #expect(movies.fileCount == 1)
        #expect(analysis.root.children.first?.name == "Movies")
        // 小さなフォルダは「その他」にまとめられる。
        #expect(analysis.root.children.contains { $0.isAggregate && $0.fileCount == 2 })
        #expect(analysis.largeFiles.map(\.url.lastPathComponent).count == 1)
        #expect((analysis.sizeByKind[.video] ?? 0) > 0)
        #expect(analysis.root.size == analysis.root.children.reduce(0) { $0 + $1.size })
    }

    @Test func findsDuplicatesByContentNotName() async throws {
        let temp = try TemporaryFolder()
        let payload = String(repeating: "dup", count: 50_000)
        try temp.file("a/report.pdf", contents: payload)
        try temp.file("b/copy of report.pdf", contents: payload)
        try temp.file("c/report.pdf", contents: String(repeating: "dif", count: 50_000))
        // APFS クローン（同じ物理領域を共有）。
        try FileManager.default.copyItem(at: temp.url.appending(path: "a/report.pdf"), to: temp.url.appending(path: "a/clone.pdf"))

        let analysis = try await StorageAnalyzer().analyze(root: temp.url, options: StorageOptions(excludedPaths: [], minimumDuplicateSize: 1))
        let groups = try await DuplicateFinder().findDuplicates(in: analysis.duplicateCandidates)

        #expect(groups.count == 1)
        let names = Set(groups[0].files.map(\.url.lastPathComponent))
        #expect(names == ["report.pdf", "copy of report.pdf", "clone.pdf"])
        // クローンは容量を共有しているので、空く容量はコピー1つ分。
        #expect(groups[0].reclaimableSize == groups[0].size * Int64(groups[0].distinctStorageCount - 1))
        #expect(groups[0].distinctStorageCount <= 3)
    }

    @Test func treemapAreasAreProportionalAndFillTheRect() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(values, in: rect)
        let total = values.reduce(0, +)

        #expect(rects.count == values.count)
        for (value, r) in zip(values, rects) {
            let expected = Double(rect.width * rect.height) * value / total
            #expect(abs(Double(r.width * r.height) - expected) < 1)
            #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(r))
        }
        let covered = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(covered - Double(rect.width * rect.height)) < 1)
    }

    @Test func trashServiceRefusesLibraryAndSystemPaths() async throws {
        let temp = try TemporaryFolder()
        let store = try await ShredderStore.open(at: nil)
        let engine = FileOperationEngine(store: store, validator: SafetyValidator(allowedRoots: []), trasher: temp.fakeTrash)
        let service = TrashService(engine: engine, home: temp.url)
        let junk = try temp.file("Downloads/junk.zip")
        let pref = try temp.file("Library/Preferences/x.plist")

        let refused = service.precheck([junk, pref, URL(filePath: "/System/Library")])
        #expect(refused.map(\.url) == [pref, URL(filePath: "/System/Library")])

        let result = await service.trash([junk, pref])
        #expect(result.status == .partialSuccess)
        #expect(!temp.exists("Downloads/junk.zip"))
        #expect(temp.exists("Library/Preferences/x.plist"))
    }
}
