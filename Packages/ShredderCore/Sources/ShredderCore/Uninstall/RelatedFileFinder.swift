import Foundation

/// 関連ファイルの種類（仕様 9.2）。
public enum RelatedItemKind: String, Sendable, Hashable, CaseIterable {
    case appBundle
    case caches
    case preferences
    case applicationSupport
    case logs
    case savedState
    case container
    case groupContainer
    case webData
    case launchAgent
    case launchDaemon
    case privilegedHelper
}

/// 関連ファイルと判断した根拠（仕様 9.3）。AI の推測は使わない。
public enum MatchReason: String, Sendable, Hashable {
    case appBundle
    /// 名前が Bundle ID と完全一致。
    case bundleID
    /// Bundle ID で始まる（ヘルパーや ByHost 設定など）。
    case bundleIDPrefix
    /// 名前がアプリ名と一致。
    case appName
    /// アプリのエンタイトルメントにある App Group。
    case appGroup
    /// launchd 設定がアプリ内の実行ファイルを指している。
    case launchItemProgram
}

public enum ItemSafety: Sendable, Hashable {
    /// このアプリ専用と判断できる。
    case safe
    /// 他のアプリと共有している（既定で除外）。
    case shared(String)
    /// 管理者権限が必要（Shredder は実行しない）。
    case requiresAdmin
}

public struct RelatedItem: Identifiable, Sendable, Hashable {
    public var id: String { url.path(percentEncoded: false) }
    public let url: URL
    public let kind: RelatedItemKind
    public let match: MatchReason
    public let safety: ItemSafety
    public let size: Int64
    public let modifiedAt: Date?

    /// 既定で削除対象に含めるか。
    public var selectedByDefault: Bool { safety == .safe }
    public var isSelectable: Bool { safety != .requiresAdmin }
}

/// ~/Library と /Library のどこを探すか。テストでは一時フォルダを渡す。
public struct LibraryLocations: Sendable {
    public let userLibrary: URL
    public let systemLibrary: URL

    public init(
        userLibrary: URL = URL.homeDirectory.appending(path: "Library", directoryHint: .isDirectory),
        systemLibrary: URL = URL(filePath: "/Library", directoryHint: .isDirectory)
    ) {
        self.userLibrary = userLibrary
        self.systemLibrary = systemLibrary
    }

    /// ユーザーライブラリ内の検索場所。
    var userFolders: [(String, RelatedItemKind)] {
        [
            ("Caches", .caches),
            ("Preferences", .preferences),
            ("Preferences/ByHost", .preferences),
            ("Application Support", .applicationSupport),
            ("Logs", .logs),
            ("Saved Application State", .savedState),
            ("Containers", .container),
            ("HTTPStorages", .webData),
            ("WebKit", .webData),
            ("Cookies", .webData),
            ("Application Scripts", .container),
        ]
    }

    /// システムライブラリ内の検索場所（すべて管理者権限が必要）。
    var systemFolders: [(String, RelatedItemKind)] {
        [
            ("Application Support", .applicationSupport),
            ("Caches", .caches),
            ("Preferences", .preferences),
            ("Logs", .logs),
            ("PrivilegedHelperTools", .privilegedHelper),
        ]
    }
}

/// アプリに関連するファイルを決定的なルールで探す（仕様 9.3）。
public struct RelatedFileFinder: Sendable {
    /// アプリ名での一致を使わない一般的すぎる名前。
    static let genericNames: Set<String> = [
        "app", "apps", "cache", "caches", "data", "default", "files", "helper", "logs", "settings",
        "support", "update", "updater", "google", "microsoft", "adobe", "apple", "mozilla", "jetbrains",
    ]
    static let strippedSuffixes = [".plist", ".savedState", ".binarycookies", ".log"]

    public let locations: LibraryLocations
    /// 削除対象以外のインストール済みアプリ（共有判定に使う）。
    public let otherApps: [InstalledApp]

    public init(locations: LibraryLocations = LibraryLocations(), otherApps: [InstalledApp]) {
        self.locations = locations
        self.otherApps = otherApps
    }

    public func find(for app: InstalledApp) -> [RelatedItem] {
        var items: [RelatedItem] = [
            Self.item(app.url, kind: .appBundle, match: .appBundle, safety: app.isDeletable ? .safe : .requiresAdmin),
        ]
        let allowNameMatch = nameMatchAllowed(for: app)

        for (folder, kind) in locations.userFolders {
            for entry in entries(in: locations.userLibrary.appending(path: folder, directoryHint: .isDirectory)) {
                guard let match = match(entry.lastPathComponent, app: app, allowName: allowNameMatch && kind != .preferences) else { continue }
                items.append(Self.item(entry, kind: kind, match: match, safety: safety(for: entry, app: app, systemWide: false)))
            }
        }
        for (folder, kind) in locations.systemFolders {
            for entry in entries(in: locations.systemLibrary.appending(path: folder, directoryHint: .isDirectory)) {
                // システム領域では名前一致を使わない（誤検出時の影響が大きいため）。
                guard let match = match(entry.lastPathComponent, app: app, allowName: false) else { continue }
                items.append(Self.item(entry, kind: kind, match: match, safety: safety(for: entry, app: app, systemWide: true)))
            }
        }

        // Group Containers はエンタイトルメントに書かれたものだけを対象にし、共有状況を確認する。
        let groupRoot = locations.userLibrary.appending(path: "Group Containers", directoryHint: .isDirectory)
        for group in app.appGroups {
            let url = groupRoot.appending(path: group, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            let sharers = otherApps.filter { $0.appGroups.contains(group) }.map(\.name)
            let safety: ItemSafety = sharers.isEmpty ? .safe : .shared("\(sharers.joined(separator: "、")) と共有しています")
            items.append(Self.item(url, kind: .groupContainer, match: .appGroup, safety: safety))
        }

        // Launch Agents / Daemons は所有関係を確認する。
        items += launchItems(
            in: locations.userLibrary.appending(path: "LaunchAgents", directoryHint: .isDirectory),
            kind: .launchAgent, app: app, systemWide: false
        )
        items += launchItems(
            in: locations.systemLibrary.appending(path: "LaunchAgents", directoryHint: .isDirectory),
            kind: .launchAgent, app: app, systemWide: true
        )
        items += launchItems(
            in: locations.systemLibrary.appending(path: "LaunchDaemons", directoryHint: .isDirectory),
            kind: .launchDaemon, app: app, systemWide: true
        )

        // 同じ項目を複数の場所から拾った場合は1つにする。
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Matching

    func match(_ entryName: String, app: InstalledApp, allowName: Bool) -> MatchReason? {
        let base = Self.baseName(entryName).lowercased()
        let bundleID = app.bundleID.lowercased()
        if base == bundleID { return .bundleID }
        if base.hasPrefix(bundleID + ".") { return .bundleIDPrefix }
        if allowName && base == app.name.lowercased() { return .appName }
        return nil
    }

    func nameMatchAllowed(for app: InstalledApp) -> Bool {
        let name = app.name.lowercased()
        guard name.count >= 4, !Self.genericNames.contains(name) else { return false }
        // 同じ名前の別アプリがあれば名前では判断しない。
        return !otherApps.contains { $0.name.lowercased() == name }
    }

    func safety(for url: URL, app: InstalledApp, systemWide: Bool) -> ItemSafety {
        let base = Self.baseName(url.lastPathComponent).lowercased()
        // より具体的な Bundle ID を持つ別アプリ（com.foo.app.pro など）の項目は共有扱い。
        if let owner = otherApps.first(where: { other in
            let id = other.bundleID.lowercased()
            return id.count > app.bundleID.count && (base == id || base.hasPrefix(id + "."))
        }) {
            return .shared("\(owner.name) の項目です")
        }
        if systemWide || !FileManager.default.isDeletableFile(atPath: url.path(percentEncoded: false)) {
            return .requiresAdmin
        }
        return .safe
    }

    func launchItems(in folder: URL, kind: RelatedItemKind, app: InstalledApp, systemWide: Bool) -> [RelatedItem] {
        let appPath = ProtectedPaths.canonicalPath(app.url)
        var result: [RelatedItem] = []
        for plist in entries(in: folder) where plist.pathExtension == "plist" {
            var reason = match(plist.lastPathComponent, app: app, allowName: false)
            let program = Self.launchProgram(plist)
            if reason == nil, let program, ProtectedPaths.path(ProtectedPaths.canonicalPath(URL(filePath: program)), isInside: appPath) {
                reason = .launchItemProgram
            }
            guard let reason else { continue }
            var safety = safety(for: plist, app: app, systemWide: systemWide)
            if let program, let owner = otherApps.first(where: {
                ProtectedPaths.path(ProtectedPaths.canonicalPath(URL(filePath: program)), isInside: ProtectedPaths.canonicalPath($0.url))
            }) {
                safety = .shared("\(owner.name) が使用しています")
            }
            result.append(Self.item(plist, kind: kind, match: reason, safety: safety))
        }
        return result
    }

    static func launchProgram(_ plist: URL) -> String? {
        guard
            let data = try? Data(contentsOf: plist),
            let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dictionary["Program"] as? String ?? (dictionary["ProgramArguments"] as? [String])?.first
    }

    // MARK: - Helpers

    func entries(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func baseName(_ name: String) -> String {
        for suffix in strippedSuffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    static func item(_ url: URL, kind: RelatedItemKind, match: MatchReason, safety: ItemSafety) -> RelatedItem {
        RelatedItem(url: url, kind: kind, match: match, safety: safety, size: size(of: url), modifiedAt: modificationDate(of: url))
    }

    public static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if values?.isDirectory == true {
            return FileScanner.allocatedSize(ofDirectory: url)
        }
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
