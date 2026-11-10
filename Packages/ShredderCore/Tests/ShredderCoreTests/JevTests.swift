import Foundation
import Testing
@testable import ShredderCore

/// URLSession の通信を差し替える。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            captured.httpBody = data
        }
        Self.requests.append(captured)
        let (status, data) = Self.handler?(captured) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite(.serialized) struct JevTests {
    private func context(_ temp: TemporaryFolder) throws -> ClassificationContext {
        let file = try temp.file("Downloads/invoice-2026-09.pdf")
        try temp.file("Documents/Invoices/invoice-2026-08.pdf")
        let candidates = FolderIntelligence().candidates(in: temp.url)
        let record = FileRecord(
            url: file, name: file.lastPathComponent, fileExtension: "pdf", size: 1234,
            createdAt: nil, modifiedAt: Date(timeIntervalSince1970: 0), contentType: "com.adobe.pdf"
        )
        return ClassificationContext(file: record, organizationRoot: temp.url, candidates: candidates)
    }

    @Test func requestMatchesDocumentedSchemaAndSendsMetadataOnly() async throws {
        let temp = try TemporaryFolder()
        let ctx = try context(temp)
        let (request, folderOptions) = JevClassifier.makeRequest(for: ctx)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]

        #expect(json["model"] as? String == "jev-latest")
        let questions = try #require(json["questions"] as? [String: [String: Any]])
        #expect(questions["destination"]?["type"] as? String == "choice")
        let criteria = try #require(questions["destination"]?["criteria"] as? [String: Any])
        #expect(criteria.keys.contains("keep"))
        #expect(criteria.keys.contains("new"))
        #expect(folderOptions.values.contains { $0.relativePath == "Documents/Invoices" })

        let state = try #require(json["state"] as? [String: Any])
        let file = try #require(state["file"] as? [String: Any])
        #expect(file["name"] as? String == "invoice-2026-09.pdf")
        // フルパスは送らない。
        let encoded = String(decoding: try JSONEncoder().encode(request.state), as: UTF8.self)
        #expect(!encoded.contains(temp.url.path(percentEncoded: false)))
    }

    @Test func clientSendsBearerTokenAndDecodesResponse() async throws {
        let temp = try TemporaryFolder()
        let ctx = try context(temp)
        let (_, folderOptions) = JevClassifier.makeRequest(for: ctx)
        let invoicesID = try #require(folderOptions.first { $0.value.relativePath == "Documents/Invoices" }?.key)

        StubURLProtocol.requests = []
        StubURLProtocol.handler = { _ in
            let body = """
            {"model":"jev-1.13.0","answers":{
              "destination":{"type":"choice","choice":"\(invoicesID)","probabilities":{"\(invoicesID)":0.9,"new":0.06,"keep":0.04},"confidence":0.85},
              "category":{"type":"choice","choice":"Invoices","probabilities":{"Invoices":1.0},"confidence":0.9}},
             "usage":{"input_tokens":250,"output_tokens":25}}
            """
            return (200, Data(body.utf8))
        }
        let classifier = JevClassifier(client: JevClient(apiKey: "test-key", session: StubURLProtocol.session()))
        let result = try #require(try await classifier.classify(ctx))

        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(result.source == .jev)
        #expect(result.suggestedDestination?.lastPathComponent == "Invoices")
        #expect(result.probabilities?["Documents/Invoices"] == 0.9)

        let assessment = ReliabilityEvaluator().assess(result, context: ctx, history: [])
        #expect(assessment.level == .high)
    }

    @Test func clientRetriesOverloadAndMapsErrors() async throws {
        StubURLProtocol.requests = []
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? (529, Data()) : (401, Data())
        }
        let client = JevClient(apiKey: "k", session: StubURLProtocol.session(), initialBackoff: .milliseconds(1))
        await #expect(throws: JevError.unauthorized) {
            try await client.evaluate(JevRequest(state: .string("x"), questions: ["q": .noul("?")]))
        }
        #expect(StubURLProtocol.requests.count == 2)
    }
}
