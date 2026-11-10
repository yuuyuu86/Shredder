import CryptoKit
import Foundation

public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public var id: String { hash }
    public let hash: String
    public let size: Int64
    /// 推奨して残すファイルが先頭（最も古いもの）。
    public let files: [StorageFile]

    public init(hash: String, size: Int64, files: [StorageFile]) {
        self.hash = hash
        self.size = size
        self.files = files
    }

    /// 物理的な領域を共有していない（クローンでない）ファイルの数。
    public var distinctStorageCount: Int {
        var seen: Set<Int64> = []
        var count = 0
        for file in files {
            if let id = file.contentIdentifier {
                if seen.insert(id).inserted { count += 1 }
            } else {
                count += 1
            }
        }
        return count
    }

    /// 1つを残して他を削除した場合に実際に空く容量。APFS クローンは容量を共有しているので数えない。
    public var reclaimableSize: Int64 { Int64(max(distinctStorageCount - 1, 0)) * size }
}

/// 内容が同一のファイルを探す（仕様 12.3）。
/// サイズでグループ化 → 先頭と末尾の部分ハッシュ → 全体ハッシュ の順に絞り込む。ファイル名は使わない。
public struct DuplicateFinder: Sendable {
    static let partialChunk = 64 * 1024
    static let readChunk = 1024 * 1024

    public init() {}

    @concurrent
    public func findDuplicates(in candidates: [StorageFile], progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [DuplicateGroup] {
        // ハードリンク（同じ inode）は同じファイルなので1つにする。
        var unique: [StorageFile] = []
        var seen: Set<FileIdentity> = []
        for file in candidates {
            if let identity = file.identity, !seen.insert(identity).inserted { continue }
            unique.append(file)
        }

        let bySize = Dictionary(grouping: unique, by: \.size).values.filter { $0.count > 1 }
        let total = bySize.reduce(0) { $0 + $1.count }
        var processed = 0
        var groups: [DuplicateGroup] = []

        for sameSize in bySize {
            try Task.checkCancellation()
            let byPartial = Dictionary(grouping: sameSize) { Self.partialHash($0.url, size: $0.size) ?? UUID().uuidString }
            for candidates in byPartial.values where candidates.count > 1 {
                let byFull = Dictionary(grouping: candidates) { file -> String in
                    (try? Self.fullHash(file.url)) ?? UUID().uuidString
                }
                for (hash, files) in byFull where files.count > 1 {
                    let sorted = files.sorted { ($0.modifiedAt ?? .distantFuture) < ($1.modifiedAt ?? .distantFuture) }
                    groups.append(DuplicateGroup(hash: hash, size: sorted[0].size, files: sorted))
                }
            }
            processed += sameSize.count
            progress?(processed, total)
        }
        return groups.sorted { $0.reclaimableSize > $1.reclaimableSize }
    }

    static func partialHash(_ url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: partialChunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(partialChunk * 2) {
            try? handle.seek(toOffset: UInt64(size) - UInt64(partialChunk))
            if let tail = try? handle.read(upToCount: partialChunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 大きなファイルも一括で読み込まずに少しずつハッシュする（仕様 24.2）。
    static func fullHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: readChunk) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
