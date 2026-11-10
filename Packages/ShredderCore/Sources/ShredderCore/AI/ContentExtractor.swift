import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// AI 解析用にファイルの内容を必要最小限だけ取り出す（仕様 3.4 入力処理, 24.2）。
public struct ContentExtractor: Sendable {
    static let maxTextBytes = 32 * 1024
    static let maxPDFPages = 3
    static let maxImageDimension = 1_600

    public init() {}

    public func excerpt(of url: URL, maxCharacters: Int) async -> String? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }

        let text: String?
        if type.conforms(to: .pdf) {
            text = pdfText(url)
        } else if type.conforms(to: .image) {
            text = await imageText(url)
        } else if ["doc", "docx", "rtf", "rtfd", "odt", "webarchive"].contains(url.pathExtension.lowercased()) {
            text = richText(url)
        } else if type.conforms(to: .text) {
            text = plainText(url)
        } else {
            // Excel / PowerPoint などはメタデータのみで分類する。
            text = nil
        }
        guard let text else { return nil }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(maxCharacters))
    }

    func plainText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxTextBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func pdfText(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var parts: [String] = []
        for index in 0..<min(document.pageCount, Self.maxPDFPages) {
            if let string = document.page(at: index)?.string { parts.append(string) }
        }
        return parts.joined(separator: "\n")
    }

    func richText(_ url: URL) -> String? {
        // NSAttributedString は .docx / .doc / .rtf / .odt を読み込める。
        try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string
    }

    func imageText(_ url: URL) async -> String? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maxImageDimension,
            ] as CFDictionary)
        else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .fast
        guard let observations = try? await request.perform(on: image) else { return nil }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
