import Foundation

public enum SafetyViolation: Error, Equatable, Sendable, CustomStringConvertible {
    case sourceMissing(String)
    case outsideAllowedRoots(String)
    case protectedLocation(String)
    case destinationExists(String)
    case destinationInsideSource(String)
    case sameLocation(String)
    case insidePackage(String)
    case incompleteFile(String)
    case invalidName(String)
    case notWritable(String)

    public var description: String {
        switch self {
        case .sourceMissing(let path): "ファイルが見つかりません: \(path)"
        case .outsideAllowedRoots(let path): "許可されていない場所です: \(path)"
        case .protectedLocation(let path): "保護された場所のため変更できません: \(path)"
        case .destinationExists(let path): "移動先に同名の項目があります: \(path)"
        case .destinationInsideSource(let path): "フォルダを自分自身の中へは移動できません: \(path)"
        case .sameLocation(let path): "移動元と移動先が同じです: \(path)"
        case .insidePackage(let path): "アプリやパッケージの内部は変更できません: \(path)"
        case .incompleteFile(let path): "書き込み中またはダウンロード中の可能性があります: \(path)"
        case .invalidName(let name): "使用できない名前です: \(name)"
        case .notWritable(let path): "書き込み権限がありません: \(path)"
        }
    }
}

/// すべてのファイル操作の前に通す安全性検証（仕様 2.2, 6.3, 22, 27.3）。
public struct SafetyValidator: Sendable {
    /// ユーザーが許可したフォルダ。この外は変更しない。
    public var allowedRoots: [URL]
    public var protectedPaths: [String]
    /// 更新からこの秒数が経っていないファイルは書き込み中とみなす。
    public var minimumFileAge: TimeInterval

    static let temporaryExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "tmp", "temp", "opdownload", "filepart", "!ut", "aria2",
    ]

    public init(
        allowedRoots: [URL],
        protectedPaths: [String] = ProtectedPaths.system + ProtectedPaths.userProtected(),
        minimumFileAge: TimeInterval = 10
    ) {
        self.allowedRoots = allowedRoots
        self.protectedPaths = protectedPaths
        self.minimumFileAge = minimumFileAge
    }

    // MARK: - Checks

    public func validateMove(from source: URL, to destination: URL, now: Date = Date()) throws(SafetyViolation) {
        let sourcePath = ProtectedPaths.canonicalPath(source)
        let destinationPath = canonicalDestination(destination)

        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw .sourceMissing(sourcePath)
        }
        try checkModifiable(sourcePath)
        try checkModifiable(destinationPath)
        try checkNotIncomplete(source, now: now)

        if sourcePath == destinationPath { throw .sameLocation(sourcePath) }
        if ProtectedPaths.path(destinationPath, isInside: sourcePath) {
            throw .destinationInsideSource(destinationPath)
        }
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            throw .destinationExists(destinationPath)
        }
        try checkName(destination.lastPathComponent)
        try checkWritable(destination.deletingLastPathComponent())
    }

    public func validateCreateFolder(at url: URL) throws(SafetyViolation) {
        let path = canonicalDestination(url)
        try checkModifiable(path)
        try checkName(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            throw .destinationExists(path)
        }
    }

    public func validateRename(_ url: URL, to newName: String) throws(SafetyViolation) {
        try checkName(newName)
        try validateMove(from: url, to: url.deletingLastPathComponent().appending(path: newName))
    }

    /// ゴミ箱へ移動できるかを検証する。アプリ削除では `/Applications` などを
    /// 個別に許可するため、`allowedRoots` に含めた場所はシステム保護より優先する。
    public func validateTrash(_ url: URL) throws(SafetyViolation) {
        let path = ProtectedPaths.canonicalPath(url)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw .sourceMissing(path)
        }
        try checkModifiable(path)
    }

    /// 自動整理の対象にしてよいファイルかどうか（エラーにはしない）。
    public func isSafeToOrganize(_ file: FileRecord, now: Date = Date()) -> Bool {
        do {
            try checkModifiable(ProtectedPaths.canonicalPath(file.url))
            try checkNotIncomplete(file.url, now: now)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    /// 移動先はまだ存在しないので、親フォルダを正規化して組み立てる。
    private func canonicalDestination(_ url: URL) -> String {
        let parent = ProtectedPaths.canonicalPath(url.deletingLastPathComponent())
        return URL(filePath: parent, directoryHint: .isDirectory)
            .appending(path: url.lastPathComponent)
            .path(percentEncoded: false)
    }

    private func checkModifiable(_ path: String) throws(SafetyViolation) {
        let roots = allowedRoots.map(ProtectedPaths.canonicalPath)
        guard let root = roots.filter({ ProtectedPaths.path(path, isInside: $0) }).max(by: { $0.count < $1.count }) else {
            throw .outsideAllowedRoots(path)
        }
        for protected in ProtectedPaths.neverModifiable where ProtectedPaths.path(path, isInside: protected) {
            throw .protectedLocation(path)
        }
        // 許可フォルダ自体が保護領域の内側にある場合（アプリ削除で ~/Library/Caches を許可した等）は、
        // ユーザーの明示的な許可を優先してその保護領域を適用しない。
        for protected in protectedPaths.map({ ProtectedPaths.canonicalPath(URL(filePath: $0)) })
        where ProtectedPaths.path(path, isInside: protected) && !ProtectedPaths.path(root, isInside: protected) {
            throw .protectedLocation(path)
        }
        try checkNotInsidePackage(path, root: root)
    }

    private func checkNotInsidePackage(_ path: String, root: String) throws(SafetyViolation) {
        // root からの相対パスの途中（最後の要素を除く）にパッケージがあれば不可。
        let relative = path.dropFirst(root.count).split(separator: "/").dropLast()
        var current = URL(filePath: root, directoryHint: .isDirectory)
        for component in relative {
            current = current.appending(path: String(component), directoryHint: .isDirectory)
            if ProtectedPaths.packageExtensions.contains(current.pathExtension.lowercased()) {
                throw .insidePackage(path)
            }
            if let isPackage = try? current.resourceValues(forKeys: [.isPackageKey]).isPackage, isPackage {
                throw .insidePackage(path)
            }
        }
    }

    private func checkNotIncomplete(_ url: URL, now: Date) throws(SafetyViolation) {
        let path = url.path(percentEncoded: false)
        if Self.temporaryExtensions.contains(url.pathExtension.lowercased()) {
            throw .incompleteFile(path)
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        if let modified = values?.contentModificationDate, now.timeIntervalSince(modified) < minimumFileAge {
            throw .incompleteFile(path)
        }
    }

    private func checkName(_ name: String) throws(SafetyViolation) {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains(":") || name.utf8.count > 255 {
            throw .invalidName(name)
        }
    }

    private func checkWritable(_ folder: URL) throws(SafetyViolation) {
        let path = folder.path(percentEncoded: false)
        // 移動先フォルダがまだ無い場合（新規作成予定）は親で判定する。
        if FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.isWritableFile(atPath: path) else { throw .notWritable(path) }
        }
    }
}
