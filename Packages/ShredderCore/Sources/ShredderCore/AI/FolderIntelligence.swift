import Foundation

/// 整理ルート内の既存フォルダ構造を把握する（仕様 5.1「既存フォルダの活用を優先」）。
public struct FolderIntelligence: Sendable {
    public var maxDepth: Int
    public var maxCandidates: Int

    public init(maxDepth: Int = 2, maxCandidates: Int = 200) {
        self.maxDepth = maxDepth
        self.maxCandidates = maxCandidates
    }

    /// 整理先の候補になるフォルダを集める。隠しフォルダとパッケージは除外する。
    public func candidates(in root: URL, extraFolders: [URL] = []) -> [FolderCandidate] {
        var result: [FolderCandidate] = []
        var queue: [(URL, Int)] = [(root, 0)]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentTypeKey, .nameKey]

        while !queue.isEmpty, result.count < maxCandidates {
            let (folder, depth) = queue.removeFirst()
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            ) else { continue }

            var fileNames: [String] = []
            var kinds: [FileKind: Int] = [:]
            var subfolders: [URL] = []
            for child in children {
                guard let values = try? child.resourceValues(forKeys: keys) else { continue }
                if values.isDirectory == true && values.isPackage != true {
                    subfolders.append(child)
                } else {
                    let name = values.name ?? child.lastPathComponent
                    fileNames.append(name)
                    kinds[FileKind(name: name, contentType: values.contentType?.identifier, fileExtension: child.pathExtension), default: 0] += 1
                }
            }

            if depth > 0 {
                result.append(FolderCandidate(
                    url: folder,
                    relativePath: JevClassifier.relativeName(folder, root: root),
                    fileCount: fileNames.count,
                    sampleNames: Array(fileNames.sorted().prefix(8)),
                    dominantKinds: kinds.sorted { $0.value > $1.value }.prefix(3).map(\.key)
                ))
            }
            if depth < maxDepth {
                queue.append(contentsOf: subfolders.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { ($0, depth + 1) })
            }
        }

        for folder in extraFolders where !result.contains(where: { $0.url.standardizedFileURL == folder.standardizedFileURL }) {
            result.append(FolderCandidate(url: folder, relativePath: folder.lastPathComponent, fileCount: 0, sampleNames: [], dominantKinds: []))
        }
        return result
    }

    /// フォルダ名がファイルの種類と意味的に一致するか。
    public static func nameMatches(_ folder: URL, kind: FileKind) -> Bool {
        let name = folder.lastPathComponent.lowercased()
        return kind.folderNameSynonyms.contains { name == $0 || name.contains($0) }
    }
}
