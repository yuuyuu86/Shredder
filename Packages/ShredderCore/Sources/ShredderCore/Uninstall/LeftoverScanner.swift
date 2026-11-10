import AppKit
import Foundation

/// 削除済みアプリが残したと思われるデータのまとまり（仕様 11）。
public struct LeftoverGroup: Identifiable, Sendable, Hashable {
    public var id: String { bundleID }
    public let bundleID: String
    public let items: [RelatedItem]
    /// 同じ開発元（Bundle ID の上位2要素）のアプリがインストールされている場合、その名前。
    /// 共通のヘルパーやサービスのデータで、まだ使われている可能性が高い。
    public let relatedInstalledApp: String?

    public init(bundleID: String, items: [RelatedItem], relatedInstalledApp: String? = nil) {
        self.bundleID = bundleID
        self.items = items
        self.relatedInstalledApp = relatedInstalledApp
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var lastModified: Date? { items.compactMap(\.modifiedAt).max() }

    /// 最近更新されている場合は、別の場所にあるアプリやツールがまだ使っている可能性がある。
    public var recentlyUsed: Bool {
        guard let lastModified else { return false }
        return Date().timeIntervalSince(lastModified) < 30 * 24 * 60 * 60
    }
}

/// ~/Library を調べ、どのインストール済みアプリにも属さない Bundle ID 名の項目を探す。
///
/// アプリ本体がないだけでは不要と確定しない（仕様 11）。結果は候補として表示し、
/// 既定ではどれも選択しない。
public struct LeftoverScanner: Sendable {
    public typealias KnownCheck = @Sendable (String) async -> Bool

    /// LaunchServices が場所を知っているアプリ（外部ディスクやダウンロードフォルダにあるもの等）。
    public static let launchServicesCheck: KnownCheck = { bundleID in
        await MainActor.run { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    }

    /// 他アプリのデータを読む権限確認が出やすい Containers 類は対象外にする。
    static let folders: [(String, RelatedItemKind)] = [
        ("Caches", .caches),
        ("Preferences", .preferences),
        ("Application Support", .applicationSupport),
        ("Logs", .logs),
        ("Saved Application State", .savedState),
        ("HTTPStorages", .webData),
        ("WebKit", .webData),
    ]

    /// OS や開発ツールが使う項目。アプリの残骸ではない。
    static let ignoredPrefixes = ["com.apple.", "group.", "systemgroup.", "org.cups.", "com.google.keystone", "org.swift."]

    let locations: LibraryLocations
    let installedBundleIDs: [String]
    let installedByVendor: [String: String]
    let isKnownToSystem: KnownCheck

    public init(
        locations: LibraryLocations = LibraryLocations(),
        installedApps: [InstalledApp],
        isKnownToSystem: @escaping KnownCheck = LeftoverScanner.launchServicesCheck
    ) {
        self.locations = locations
        installedBundleIDs = installedApps.map { $0.bundleID.lowercased() }
        var byVendor: [String: String] = [:]
        for app in installedApps {
            if let vendor = Self.vendor(of: app.bundleID.lowercased()), byVendor[vendor] == nil { byVendor[vendor] = app.name }
        }
        installedByVendor = byVendor
        self.isKnownToSystem = isKnownToSystem
    }

    @concurrent
    public func scan() async -> [LeftoverGroup] {
        var grouped: [String: [RelatedItem]] = [:]
        for (folder, kind) in Self.folders {
            let directory = locations.userLibrary.appending(path: folder, directoryHint: .isDirectory)
            let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                guard let bundleID = Self.bundleID(fromEntryName: entry.lastPathComponent) else { continue }
                let lower = bundleID.lowercased()
                if Self.ignoredPrefixes.contains(where: lower.hasPrefix) { continue }
                if belongsToInstalledApp(lower) { continue }
                let safety: ItemSafety = FileManager.default.isDeletableFile(atPath: entry.path(percentEncoded: false)) ? .safe : .requiresAdmin
                grouped[lower, default: []].append(RelatedFileFinder.item(entry, kind: kind, match: .bundleID, safety: safety))
            }
        }

        var groups: [LeftoverGroup] = []
        for (bundleID, items) in grouped {
            if await isKnownToSystem(bundleID) { continue }
            groups.append(LeftoverGroup(
                bundleID: bundleID,
                items: items.sorted { $0.size > $1.size },
                relatedInstalledApp: Self.vendor(of: bundleID).flatMap { installedByVendor[$0] }
            ))
        }
        // 開発元のアプリが残っているものは後ろへ。
        return groups.sorted {
            ($0.relatedInstalledApp == nil ? 0 : 1, -$0.totalSize) < ($1.relatedInstalledApp == nil ? 0 : 1, -$1.totalSize)
        }
    }

    /// インストール済みアプリの Bundle ID と同じ・その配下（ヘルパー）・その上位（ベンダー共通）なら除外する。
    func belongsToInstalledApp(_ bundleID: String) -> Bool {
        installedBundleIDs.contains { installed in
            bundleID == installed || bundleID.hasPrefix(installed + ".") || installed.hasPrefix(bundleID + ".")
        }
    }

    static func vendor(of bundleID: String) -> String? {
        let components = bundleID.split(separator: ".")
        guard components.count >= 3 else { return nil }
        return components.prefix(2).joined(separator: ".")
    }

    /// 「com.example.App」「com.example.App.plist」「com.example.App.<UUID>.plist」などから Bundle ID を取り出す。
    static func bundleID(fromEntryName name: String) -> String? {
        var base = RelatedFileFinder.baseName(name)
        // ByHost の「<id>.<UUID>」形式。
        if let dot = base.lastIndex(of: "."), UUID(uuidString: String(base[base.index(after: dot)...])) != nil {
            base = String(base[..<dot])
        }
        let components = base.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, components.allSatisfy({ !$0.isEmpty }) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard base.unicodeScalars.allSatisfy({ allowed.contains($0) || $0 == "." }) else { return nil }
        // 先頭はドメインの TLD らしいもの（com, org, io など）に限る。
        guard let first = components.first, first.count >= 2, first.count <= 6, first.allSatisfy(\.isLetter) else { return nil }
        return base
    }
}
