import Foundation
@testable import ShredderCore

/// テストごとに作られる一時フォルダ。
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "ShredderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("trash"))
    }

    @discardableResult
    func file(_ relativePath: String, contents: String = "x", age: TimeInterval = 3600) throws -> URL {
        let fileURL = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL)
        let date = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: fileURL.path(percentEncoded: false))
        return fileURL
    }

    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        let folderURL = url.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    /// 実際のゴミ箱を汚さないよう、一時フォルダ外の別フォルダへ移す。
    var fakeTrash: FileOperationEngine.Trasher {
        let trash = url.appendingPathExtension("trash")
        return { item in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appending(path: "\(UUID().uuidString)-\(item.lastPathComponent)")
            try FileManager.default.moveItem(at: item, to: destination)
            return destination
        }
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: relativePath).path(percentEncoded: false))
    }
}

extension FileRecord {
    static func stub(_ path: String, size: Int64 = 100, contentType: String? = nil) -> FileRecord {
        let url = URL(filePath: path)
        return FileRecord(
            url: url,
            name: url.lastPathComponent,
            fileExtension: url.pathExtension,
            size: size,
            createdAt: nil,
            modifiedAt: Date().addingTimeInterval(-3600),
            contentType: contentType
        )
    }
}
