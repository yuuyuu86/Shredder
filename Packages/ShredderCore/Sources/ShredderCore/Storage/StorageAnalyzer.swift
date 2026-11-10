import Foundation

/// ボリューム全体の容量（OS の値）。Shredder が集計した値とは区別して表示する（仕様 12.2）。
public struct VolumeInfo: Sendable, Hashable {
    public let name: String
    public let total: Int64
    public let available: Int64

    public var used: Int64 { max(total - available, 0) }

    public static func current(for url: URL = URL.homeDirectory) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeInfo(name: values.volumeName ?? "Macintosh HD", total: Int64(total), available: available)
    }
}

/// フォルダ容量ツリーの1ノード。小さな項目は「その他」にまとめてメモリを抑える（仕様 24.2）。
public struct StorageNode: Identifiable, Sendable, Hashable {
    public var id: String { url.path(percentEncoded: false) + (isAggregate ? "#others" : "") }
    public let url: URL
    public let name: String
    public let size: Int64
    public let fileCount: Int
    public let isDirectory: Bool
    /// 小さな項目をまとめたノード。
    public let isAggregate: Bool
    public let kind: FileKind?
    public let children: [StorageNode]

    public var isLeaf: Bool { children.isEmpty }
}

/// ストレージ分析の結果（仕様 12）。
public struct StorageAnalysis: Sendable {
    public let root: StorageNode
    public let sizeByKind: [FileKind: Int64]
    public let largeFiles: [StorageFile]
    /// 重複検出の候補（一定サイズ以上のファイル）。
    public let duplicateCandidates: [StorageFile]
    public let inaccessible: [InaccessibleItem]
    public let duration: TimeInterval

    public var totalSize: Int64 { root.size }
}

public struct StorageFile: Identifiable, Sendable, Hashable {
    public var id: String { url.path(percentEncoded: false) }
    public let url: URL
    public let size: Int64
    public let modifiedAt: Date?
    public let kind: FileKind
    public let identity: FileIdentity?
    /// APFS クローン同士は同じ値になる（同じ物理領域を共有）。
    public let contentIdentifier: Int64?
}

public struct StorageOptions: Sendable {
    public var excludedPaths: [String]
    /// これより小さい項目は親フォルダの「その他」にまとめる。
    public var minimumNodeSize: Int64
    public var largeFileThreshold: Int64
    public var maxLargeFiles: Int
    public var minimumDuplicateSize: Int64
    public var includeHidden: Bool

    public init(
        excludedPaths: [String] = ProtectedPaths.defaultScanExclusions(),
        minimumNodeSize: Int64 = 1_000_000,
        largeFileThreshold: Int64 = 100_000_000,
        maxLargeFiles: Int = 500,
        minimumDuplicateSize: Int64 = 1_000_000,
        includeHidden: Bool = true
    ) {
        self.excludedPaths = excludedPaths
        self.minimumNodeSize = minimumNodeSize
        self.largeFileThreshold = largeFileThreshold
        self.maxLargeFiles = maxLargeFiles
        self.minimumDuplicateSize = minimumDuplicateSize
        self.includeHidden = includeHidden
    }
}

/// フォルダ容量・ファイル種類別容量・大容量ファイルを1回の走査で集計する。
/// 実使用量（割り当てサイズ）で数え、ハードリンクは1回だけ数える。
public struct StorageAnalyzer: Sendable {
    public init() {}

    @concurrent
    public func analyze(
        root: URL,
        options: StorageOptions = StorageOptions(),
        progress: (@Sendable (Int, Int64) -> Void)? = nil
    ) async throws -> StorageAnalysis {
        let start = Date()
        var state = WalkState(
            options: options,
            excluded: options.excludedPaths.map { ProtectedPaths.canonicalPath(URL(filePath: $0)) },
            progress: progress
        )
        let node = try state.walk(root.standardizedFileURL)
            ?? StorageNode(url: root, name: root.lastPathComponent, size: 0, fileCount: 0, isDirectory: true, isAggregate: false, kind: nil, children: [])
        progress?(state.filesVisited, state.bytes)
        return StorageAnalysis(
            root: node,
            sizeByKind: state.sizeByKind,
            largeFiles: state.largeFiles.sorted { $0.size > $1.size },
            duplicateCandidates: state.duplicateCandidates,
            inaccessible: state.inaccessible,
            duration: Date().timeIntervalSince(start)
        )
    }

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .fileSizeKey, .contentModificationDateKey, .contentTypeKey, .linkCountKey, .fileContentIdentifierKey, .nameKey,
    ]

    struct WalkState {
        let options: StorageOptions
        let excluded: [String]
        let progress: (@Sendable (Int, Int64) -> Void)?
        var visitedDirectories: Set<FileIdentity> = []
        var seenHardLinks: Set<FileIdentity> = []
        var sizeByKind: [FileKind: Int64] = [:]
        var largeFiles: [StorageFile] = []
        var duplicateCandidates: [StorageFile] = []
        var inaccessible: [InaccessibleItem] = []
        var filesVisited = 0
        var bytes: Int64 = 0

        mutating func walk(_ directory: URL) throws -> StorageNode? {
            try Task.checkCancellation()
            let canonical = ProtectedPaths.canonicalPath(directory)
            if excluded.contains(where: { ProtectedPaths.path(canonical, isInside: $0) }) { return nil }
            if let identity = FileScanner.identity(of: directory), !visitedDirectories.insert(identity).inserted { return nil }

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: StorageAnalyzer.keys,
                    options: options.includeHidden ? [] : [.skipsHiddenFiles]
                )
            } catch {
                inaccessible.append(InaccessibleItem(url: directory, reason: FileScanner.describe(error)))
                return nil
            }

            var kept: [StorageNode] = []
            var otherSize: Int64 = 0
            var otherCount = 0
            var total: Int64 = 0
            var count = 0

            for child in children {
                guard let values = try? child.resourceValues(forKeys: Set(StorageAnalyzer.keys)), values.isSymbolicLink != true else { continue }
                let node: StorageNode?
                if values.isDirectory == true && values.isPackage != true {
                    node = try walk(child)
                } else {
                    node = file(child, values: values)
                }
                guard let node else { continue }
                total += node.size
                count += node.fileCount
                if node.size >= options.minimumNodeSize {
                    kept.append(node)
                } else {
                    otherSize += node.size
                    otherCount += node.fileCount
                }
            }
            kept.sort { $0.size > $1.size }
            if otherSize > 0 {
                kept.append(StorageNode(
                    url: directory, name: "その他の小さな項目", size: otherSize, fileCount: otherCount,
                    isDirectory: false, isAggregate: true, kind: nil, children: []
                ))
            }
            return StorageNode(
                url: directory, name: directory.lastPathComponent, size: total, fileCount: count,
                isDirectory: true, isAggregate: false, kind: nil, children: kept
            )
        }

        mutating func file(_ url: URL, values: URLResourceValues) -> StorageNode? {
            // inode は、ハードリンクの判定と重複検出の候補にだけ必要（lstat を減らすため）。
            let needsIdentity = (values.linkCount ?? 1) > 1 || Int64(values.fileSize ?? 0) >= options.minimumDuplicateSize
            let identity = needsIdentity ? FileScanner.identity(of: url) : nil
            // ハードリンクは2回目以降を数えない。
            if (values.linkCount ?? 1) > 1, let identity, !seenHardLinks.insert(identity).inserted { return nil }
            let isPackage = values.isPackage == true
            let size = isPackage
                ? FileScanner.allocatedSize(ofDirectory: url)
                : Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            let name = values.name ?? url.lastPathComponent
            let kind = FileKind(name: name, contentType: values.contentType?.identifier, fileExtension: url.pathExtension)

            filesVisited += 1
            bytes += size
            if filesVisited % 1_000 == 0 { progress?(filesVisited, bytes) }
            sizeByKind[kind, default: 0] += size

            let file = StorageFile(
                url: url, size: size, modifiedAt: values.contentModificationDate, kind: kind,
                identity: identity, contentIdentifier: values.fileContentIdentifier
            )
            if size >= options.largeFileThreshold {
                largeFiles.append(file)
                if largeFiles.count > options.maxLargeFiles * 2 {
                    largeFiles.sort { $0.size > $1.size }
                    largeFiles.removeLast(largeFiles.count - options.maxLargeFiles)
                }
            }
            // 重複検出は通常ファイルのみ（パッケージは内容比較が難しいため対象外）。
            if !isPackage, Int64(values.fileSize ?? 0) >= options.minimumDuplicateSize {
                duplicateCandidates.append(StorageFile(
                    url: url, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, kind: kind,
                    identity: identity, contentIdentifier: values.fileContentIdentifier
                ))
            }
            return StorageNode(
                url: url, name: name, size: size, fileCount: 1, isDirectory: isPackage,
                isAggregate: false, kind: kind, children: []
            )
        }
    }
}
