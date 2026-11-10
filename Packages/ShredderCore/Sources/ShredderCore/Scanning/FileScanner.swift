import Foundation

public struct ScanOptions: Sendable {
    public var includeHidden: Bool
    /// パッケージ（.app など）の内部まで探索するか。既定ではパッケージを1項目として扱う。
    public var descendIntoPackages: Bool
    /// これらのパス配下は探索しない。
    public var excludedPaths: [String]
    public var maxDepth: Int?
    /// 差分スキャン用。前回とサイズ・更新日時が同じファイルは `unchangedPaths` に記録する。
    public var previousStates: [String: (size: Int64, modifiedAt: Date?)]

    public init(
        includeHidden: Bool = false,
        descendIntoPackages: Bool = false,
        excludedPaths: [String] = ProtectedPaths.defaultScanExclusions(),
        maxDepth: Int? = nil,
        previousStates: [String: (size: Int64, modifiedAt: Date?)] = [:]
    ) {
        self.includeHidden = includeHidden
        self.descendIntoPackages = descendIntoPackages
        self.excludedPaths = excludedPaths
        self.maxDepth = maxDepth
        self.previousStates = previousStates
    }
}

public struct ScanProgress: Sendable {
    public let filesVisited: Int
    public let directoriesVisited: Int
    public let bytesVisited: Int64
    public let currentPath: String
}

public struct InaccessibleItem: Sendable, Hashable {
    public let url: URL
    public let reason: String
}

public struct ScanResult: Sendable {
    public let roots: [URL]
    public let files: [FileRecord]
    public let inaccessible: [InaccessibleItem]
    /// 前回スキャンから変化がないファイルのパス。
    public let unchangedPaths: Set<String>
    public let skippedSymlinks: Int
    public let duration: TimeInterval

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// フォルダを再帰的に探索してファイル情報を集める（仕様 4）。
public struct FileScanner: Sendable {
    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey,
        .tagNamesKey, .linkCountKey, .isReadableKey,
    ]

    private static let progressInterval = 250

    public init() {}

    /// キャンセルされると `CancellationError` を投げる。
    @concurrent
    public func scan(
        roots: [URL],
        options: ScanOptions = ScanOptions(),
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        let start = Date()
        var files: [FileRecord] = []
        var inaccessible: [InaccessibleItem] = []
        var unchanged: Set<String> = []
        var visitedDirectories: Set<FileIdentity> = []
        var skippedSymlinks = 0
        var directoriesVisited = 0
        var bytes: Int64 = 0

        let excluded = options.excludedPaths.map { ProtectedPaths.canonicalPath(URL(filePath: $0)) }
        var stack: [(url: URL, depth: Int)] = roots.map { ($0.standardizedFileURL, 0) }

        while let (directory, depth) = stack.popLast() {
            try Task.checkCancellation()

            let canonical = ProtectedPaths.canonicalPath(directory)
            if excluded.contains(where: { ProtectedPaths.path(canonical, isInside: $0) }) { continue }
            // シンボリックリンク循環やファームリンクの重複を防ぐ。
            if let identity = Self.identity(of: directory) {
                guard visitedDirectories.insert(identity).inserted else { continue }
            }
            directoriesVisited += 1

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Self.resourceKeys,
                    options: options.includeHidden ? [] : [.skipsHiddenFiles]
                )
            } catch {
                inaccessible.append(InaccessibleItem(url: directory, reason: Self.describe(error)))
                continue
            }

            for child in children {
                guard let values = try? child.resourceValues(forKeys: Set(Self.resourceKeys)) else {
                    inaccessible.append(InaccessibleItem(url: child, reason: "属性を取得できません"))
                    continue
                }
                if values.isSymbolicLink == true {
                    // リンク先は辿らない。
                    skippedSymlinks += 1
                    continue
                }
                let isDirectory = values.isDirectory == true
                let isPackage = values.isPackage == true

                if isDirectory && !(isPackage && !options.descendIntoPackages) {
                    if options.maxDepth.map({ depth + 1 <= $0 }) ?? true {
                        stack.append((child, depth + 1))
                    }
                    continue
                }

                let size = isPackage ? Self.allocatedSize(ofDirectory: child) : Int64(values.fileSize ?? 0)
                let record = FileRecord(
                    url: child,
                    name: values.name ?? child.lastPathComponent,
                    fileExtension: child.pathExtension,
                    size: size,
                    createdAt: values.creationDate,
                    modifiedAt: values.contentModificationDate,
                    contentType: values.contentType?.identifier,
                    isPackage: isPackage,
                    fileIdentity: Self.identity(of: child),
                    linkCount: values.linkCount,
                    tags: values.tagNames ?? []
                )
                let path = child.path(percentEncoded: false)
                if let previous = options.previousStates[path], previous.size == record.size, previous.modifiedAt == record.modifiedAt {
                    unchanged.insert(path)
                }
                if values.isReadable == false {
                    inaccessible.append(InaccessibleItem(url: child, reason: "読み取り権限がありません"))
                }
                files.append(record)
                bytes += size

                if files.count % Self.progressInterval == 0 {
                    try Task.checkCancellation()
                    progress?(ScanProgress(
                        filesVisited: files.count,
                        directoriesVisited: directoriesVisited,
                        bytesVisited: bytes,
                        currentPath: path
                    ))
                }
            }
        }

        progress?(ScanProgress(filesVisited: files.count, directoriesVisited: directoriesVisited, bytesVisited: bytes, currentPath: ""))
        return ScanResult(
            roots: roots,
            files: files,
            inaccessible: inaccessible,
            unchangedPaths: unchanged,
            skippedSymlinks: skippedSymlinks,
            duration: Date().timeIntervalSince(start)
        )
    }

    // MARK: - Helpers

    /// 1つのファイルの情報を取得する（監視で検知したファイル用）。
    public static func record(for url: URL) -> FileRecord? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)), values.isSymbolicLink != true else { return nil }
        let isPackage = values.isPackage == true
        if values.isDirectory == true && !isPackage { return nil }
        return FileRecord(
            url: url,
            name: values.name ?? url.lastPathComponent,
            fileExtension: url.pathExtension,
            size: isPackage ? allocatedSize(ofDirectory: url) : Int64(values.fileSize ?? 0),
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate,
            contentType: values.contentType?.identifier,
            isPackage: isPackage,
            fileIdentity: identity(of: url),
            linkCount: values.linkCount,
            tags: values.tagNames ?? []
        )
    }

    static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// パッケージなどディレクトリの実使用量。ハードリンクは1回だけ数える。
    public static func allocatedSize(ofDirectory url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .linkCountKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        var seen: Set<FileIdentity> = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if (values.linkCount ?? 1) > 1, let identity = identity(of: file), !seen.insert(identity).inserted { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
            return "アクセス権限がありません（フルディスクアクセスが必要な場合があります）"
        }
        return nsError.localizedDescription
    }
}
