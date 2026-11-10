import Foundation
import Security

/// インストール済みアプリ（仕様 9.5）。
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { url.path(percentEncoded: false) }

    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String?
    public let teamID: String?
    /// エンタイトルメントで宣言された App Group（Group Containers の共有判定に使う）。
    public let appGroups: [String]
    public let isAppStore: Bool
    /// ユーザー権限でゴミ箱へ移動できるか。false なら管理者権限が必要。
    public let isDeletable: Bool
    public let lastUsed: Date?

    public init(
        url: URL,
        name: String,
        bundleID: String,
        version: String? = nil,
        teamID: String? = nil,
        appGroups: [String] = [],
        isAppStore: Bool = false,
        isDeletable: Bool = true,
        lastUsed: Date? = nil
    ) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.teamID = teamID
        self.appGroups = appGroups
        self.isAppStore = isAppStore
        self.isDeletable = isDeletable
        self.lastUsed = lastUsed
    }

    /// OS に付属する Apple 純正アプリ。削除対象にしない。
    /// App Store から入れた Apple 製アプリ（Pages など）や Xcode 系は通常のアプリとして扱う。
    public var isAppleApp: Bool {
        bundleID.hasPrefix("com.apple.") && !isAppStore && !bundleID.hasPrefix("com.apple.dt.")
    }
}

/// /Applications と ~/Applications からアプリを探す。
public struct AppDiscovery: Sendable {
    public var searchRoots: [URL]
    public var excludedBundleIDs: Set<String>
    /// 署名情報の読み取り。テストでは差し替える。
    public var signingReader: @Sendable (URL) -> (teamID: String?, groups: [String])

    public init(
        searchRoots: [URL] = [URL(filePath: "/Applications"), URL.homeDirectory.appending(path: "Applications")],
        excludedBundleIDs: Set<String> = Set([Bundle.main.bundleIdentifier].compactMap { $0 }),
        signingReader: @escaping @Sendable (URL) -> (teamID: String?, groups: [String]) = CodeSigningInfo.read
    ) {
        self.searchRoots = searchRoots
        self.excludedBundleIDs = excludedBundleIDs
        self.signingReader = signingReader
    }

    /// サブフォルダ（/Applications/Utilities など）は2階層まで探す。
    @concurrent
    public func discover() async -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seen: Set<String> = []
        for root in searchRoots {
            for url in Self.appBundles(in: root, depth: 2) {
                guard let app = app(at: url),
                      !excludedBundleIDs.contains(app.bundleID),
                      !app.isAppleApp,
                      seen.insert(app.id).inserted
                else { continue }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func app(at url: URL) -> InstalledApp? {
        let infoURL = url.appending(path: "Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = info["CFBundleIdentifier"] as? String
        else { return nil }

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let signing = signingReader(url)
        let receipt = url.appending(path: "Contents/_MASReceipt/receipt").path(percentEncoded: false)
        return InstalledApp(
            url: url,
            name: name,
            bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            teamID: signing.teamID,
            appGroups: signing.groups,
            isAppStore: FileManager.default.fileExists(atPath: receipt),
            isDeletable: FileManager.default.isDeletableFile(atPath: url.path(percentEncoded: false)),
            lastUsed: Self.lastUsedDate(url)
        )
    }

    static func appBundles(in root: URL, depth: Int) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // シンボリックリンク（/Applications/Safari.app など）はシステムのものなので辿らない。
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { continue }
            if child.pathExtension == "app" {
                result.append(child)
            } else if depth > 1 {
                result += appBundles(in: child, depth: depth - 1)
            }
        }
        return result
    }

    /// Spotlight の最終使用日時（取得できる場合のみ）。
    static func lastUsedDate(_ url: URL) -> Date? {
        NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
    }
}

/// コード署名からチームIDと App Group を読む。
public enum CodeSigningInfo {
    public static func read(_ url: URL) -> (teamID: String?, groups: [String]) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, []) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return (nil, []) }
        let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return (teamID, groups)
    }
}
