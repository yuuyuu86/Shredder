import Foundation
import UniformTypeIdentifiers

/// UTType から決まるファイルの大まかな種類。学習データのキーやローカル分類に使う。
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case pdf
    case document
    case spreadsheet
    case presentation
    case text
    case image
    case screenshot
    case video
    case audio
    case archive
    case diskImage
    case installer
    case sourceCode
    case application
    case other

    public init(contentType: String?, fileExtension: String) {
        let type = contentType.flatMap(UTType.init) ?? UTType(filenameExtension: fileExtension)
        let ext = fileExtension.lowercased()
        guard let type else {
            self = .other
            return
        }
        if type.conforms(to: .applicationBundle) {
            self = .application
        } else if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .spreadsheet) || ["xls", "xlsx", "numbers", "csv", "tsv"].contains(ext) {
            self = .spreadsheet
        } else if type.conforms(to: .presentation) || ["ppt", "pptx", "key"].contains(ext) {
            self = .presentation
        } else if ["doc", "docx", "pages", "rtf", "odt"].contains(ext) {
            self = .document
        } else if type.conforms(to: .sourceCode) || type.conforms(to: .script) {
            self = .sourceCode
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            self = .video
        } else if type.conforms(to: .audio) {
            self = .audio
        } else if type.conforms(to: .diskImage) || ext == "dmg" {
            self = .diskImage
        } else if ["pkg", "mpkg"].contains(ext) {
            self = .installer
        } else if type.conforms(to: .archive) || ["zip", "rar", "7z", "tar", "gz", "tgz", "xz", "bz2"].contains(ext) {
            self = .archive
        } else if type.conforms(to: .text) {
            self = .text
        } else {
            self = .other
        }
    }

    /// 新規フォルダを作るときの既定のフォルダ名。
    public var defaultFolderName: String {
        switch self {
        case .pdf: "PDF"
        case .document: "Documents"
        case .spreadsheet: "Spreadsheets"
        case .presentation: "Presentations"
        case .text: "Text"
        case .image: "Images"
        case .screenshot: "Screenshots"
        case .video: "Videos"
        case .audio: "Audio"
        case .archive: "Archives"
        case .diskImage: "Disk Images"
        case .installer: "Installers"
        case .sourceCode: "Code"
        case .application: "Applications"
        case .other: "Other"
        }
    }

    /// 既存フォルダ名との意味的な一致判定に使う別名（日本語を含む）。
    public var folderNameSynonyms: [String] {
        switch self {
        case .pdf: ["pdf", "pdfs", "documents", "docs", "書類", "資料"]
        case .document: ["documents", "docs", "書類", "文書", "資料"]
        case .spreadsheet: ["spreadsheets", "sheets", "excel", "表計算", "スプレッドシート"]
        case .presentation: ["presentations", "slides", "keynote", "スライド", "プレゼン"]
        case .text: ["text", "notes", "メモ", "テキスト"]
        case .image: ["images", "pictures", "photos", "画像", "写真"]
        case .screenshot: ["screenshots", "screen shots", "スクリーンショット", "スクショ"]
        case .video: ["videos", "movies", "動画", "ビデオ", "ムービー"]
        case .audio: ["audio", "music", "sounds", "音楽", "オーディオ", "音声"]
        case .archive: ["archives", "zips", "圧縮", "アーカイブ"]
        case .diskImage: ["disk images", "dmg", "installers", "インストーラ"]
        case .installer: ["installers", "packages", "インストーラ"]
        case .sourceCode: ["code", "src", "source", "scripts", "コード"]
        case .application: ["applications", "apps", "アプリ"]
        case .other: ["other", "misc", "その他"]
        }
    }
}

extension FileKind {
    /// ファイル名も考慮し、スクリーンショットを通常画像と区別する。
    public init(name: String, contentType: String?, fileExtension: String) {
        self.init(contentType: contentType, fileExtension: fileExtension)
        guard self == .image else { return }
        let lower = name.lowercased()
        if lower.hasPrefix("screenshot") || lower.hasPrefix("スクリーンショット") || lower.hasPrefix("screen shot") {
            self = .screenshot
        }
    }
}
