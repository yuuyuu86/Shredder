import Foundation

// TypeSafe Jev System One API の型定義。
// 出典: https://docs.typesafe.ai/api （POST /v1/systemone）
// ドキュメントに記載された項目のみをモデル化している。

/// 任意の JSON 値（`state` に構造化データを渡すため）。
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum JevQuestionType: String, Codable, Sendable {
    case noul
    case choice
    case score
}

public struct JevQuestion: Encodable, Sendable, Hashable {
    public enum Criteria: Sendable, Hashable {
        /// choice: 選択肢 → 説明（最大255件）。
        case options([String: String?])
        /// score: 段階の説明（2〜10件）。
        case levels([String])
        /// noul: true/false それぞれの説明。
        case noul(whenTrue: String, whenFalse: String)
    }

    public let type: JevQuestionType
    public let instructions: String
    public let criteria: Criteria?

    public static func choice(_ instructions: String, options: [String: String?]) -> JevQuestion {
        JevQuestion(type: .choice, instructions: instructions, criteria: .options(options))
    }

    public static func score(_ instructions: String, levels: [String]) -> JevQuestion {
        JevQuestion(type: .score, instructions: instructions, criteria: .levels(levels))
    }

    public static func noul(_ instructions: String, whenTrue: String? = nil, whenFalse: String? = nil) -> JevQuestion {
        let criteria = whenTrue.flatMap { t in whenFalse.map { Criteria.noul(whenTrue: t, whenFalse: $0) } }
        return JevQuestion(type: .noul, instructions: instructions, criteria: criteria)
    }

    private enum CodingKeys: String, CodingKey { case type, instructions, criteria }
    private enum NoulKeys: String, CodingKey { case whenTrue = "true", whenFalse = "false" }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(instructions, forKey: .instructions)
        switch criteria {
        case .options(let options):
            try container.encode(options, forKey: .criteria)
        case .levels(let levels):
            try container.encode(levels, forKey: .criteria)
        case .noul(let whenTrue, let whenFalse):
            var nested = container.nestedContainer(keyedBy: NoulKeys.self, forKey: .criteria)
            try nested.encode(whenTrue, forKey: .whenTrue)
            try nested.encode(whenFalse, forKey: .whenFalse)
        case nil:
            break
        }
    }
}

public struct JevRequest: Encodable, Sendable {
    public let state: JSONValue
    public let model: String
    public let questions: [String: JevQuestion]

    public init(state: JSONValue, model: String = "jev-latest", questions: [String: JevQuestion]) {
        self.state = state
        self.model = model
        self.questions = questions
    }
}

public struct JevAnswer: Decodable, Sendable, Hashable {
    public let type: JevQuestionType
    public let noul: Double?
    public let choice: String?
    public let score: Double?
    public let probabilities: [String: Double]?
    public let confidence: Double?
}

public struct JevUsage: Decodable, Sendable, Hashable {
    public let inputTokens: Int
    public let outputTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public struct JevResponse: Decodable, Sendable {
    public let model: String
    public let answers: [String: JevAnswer]
    public let usage: JevUsage?
}

public enum JevError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConfigured
    case unauthorized
    case validation(String)
    case rateLimited
    case overloaded
    case http(Int, String)
    case transport(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .notConfigured: "Jev の API キーが設定されていません"
        case .unauthorized: "Jev の API キーが無効です (401)"
        case .validation(let detail): "Jev へのリクエストが不正です (422): \(detail)"
        case .rateLimited: "Jev のレート制限に達しました (429)"
        case .overloaded: "Jev が混雑しています (529)"
        case .http(let status, let body): "Jev がエラーを返しました (\(status)): \(body)"
        case .transport(let message): "Jev に接続できません: \(message)"
        case .decoding(let message): "Jev の応答を解釈できません: \(message)"
        }
    }
}

/// Jev の HTTP クライアント。429/529 は指数バックオフで再試行する。
public struct JevClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!

    public let apiKey: String
    public let baseURL: URL
    public let session: URLSession
    public let maxRetries: Int
    public let initialBackoff: Duration

    public init(
        apiKey: String,
        baseURL: URL = JevClient.defaultBaseURL,
        session: URLSession = .shared,
        maxRetries: Int = 3,
        initialBackoff: Duration = .milliseconds(500)
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.maxRetries = maxRetries
        self.initialBackoff = initialBackoff
    }

    public func evaluate(_ body: JevRequest) async throws(JevError) -> JevResponse {
        var request = URLRequest(url: baseURL.appending(path: "v1/systemone"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw .validation("encode: \(error)")
        }

        var attempt = 0
        var backoff = initialBackoff
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw .transport(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                do {
                    return try JSONDecoder().decode(JevResponse.self, from: data)
                } catch {
                    throw .decoding(String(describing: error))
                }
            case 401:
                throw .unauthorized
            case 422:
                throw .validation(String(decoding: data.prefix(500), as: UTF8.self))
            case 429, 529:
                guard attempt < maxRetries else { throw status == 429 ? .rateLimited : .overloaded }
                attempt += 1
                try? await Task.sleep(for: backoff)
                backoff *= 2
            default:
                throw .http(status, String(decoding: data.prefix(500), as: UTF8.self))
            }
        }
    }
}
