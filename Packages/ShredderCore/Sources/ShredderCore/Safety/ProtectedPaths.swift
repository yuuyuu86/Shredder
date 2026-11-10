import Foundation

/// 自動変更してはいけない場所（仕様 22.3）。
public enum ProtectedPaths {
    /// macOS システム領域。どのモードでも変更しない。
    public static let system: [String] = [
        "/System",
        "/Library",
        "/bin",
        "/sbin",
        "/usr",
        "/opt",
        "/cores",
        "/dev",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        "/private/var/vm",
        "/Applications",
    ]

    /// ユーザーが許可しても絶対に変更しない OS の中核領域。
    public static let neverModifiable: [String] = [
        "/System",
        "/bin",
        "/sbin",
        "/usr",
        "/dev",
        "/cores",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        "/private/var/vm",
    ]

    /// ホーム配下でファイル整理の対象にしない場所。
    public static func userProtected(home: URL = URL.homeDirectory) -> [String] {
        [
            home.appending(path: "Library").path(percentEncoded: false),
            home.appending(path: ".Trash").path(percentEncoded: false),
        ]
    }

    /// Mac全体スキャン時に既定で除外する場所。
    public static func defaultScanExclusions(home: URL = URL.homeDirectory) -> [String] {
        [
            "/System",
            "/private",
            "/dev",
            "/cores",
            "/Volumes",
            "/usr",
            "/bin",
            "/sbin",
            home.appending(path: ".Trash").path(percentEncoded: false),
        ]
    }

    /// パッケージとして扱い、内部を個別に操作しない拡張子。
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary",
        "tvlibrary", "fcpbundle", "logicx", "xcodeproj", "xcworkspace", "playground", "rtfd",
    ]

    /// `path` が `ancestor` 自身またはその配下かどうか。
    public static func path(_ path: String, isInside ancestor: String) -> Bool {
        let normalizedAncestor = ancestor.hasSuffix("/") ? String(ancestor.dropLast()) : ancestor
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        if normalizedAncestor.isEmpty { return true }
        return normalizedPath == normalizedAncestor || normalizedPath.hasPrefix(normalizedAncestor + "/")
    }

    /// シンボリックリンク（/var → /private/var など）を解決した正規パス。
    public static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
