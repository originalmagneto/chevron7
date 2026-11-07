import Foundation

/// The deliberately small JSON vocabulary shared by the app, CLI and MCP adapter.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public subscript(_ key: String) -> JSONValue? { object?[key] }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
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

public struct IntegrationError: Error, LocalizedError, Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public var errorDescription: String? { message }

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public var exitCode: Int32 {
        switch code {
        case "INVALID_ARGUMENTS", "INVALID_REQUEST", "UNSUPPORTED_METHOD", "UNSUPPORTED_FORMAT", "IDEMPOTENCY_CONFLICT", "SCOPE_REQUIRED", "ACCESS_DENIED", "PAYLOAD_TOO_LARGE": 2
        case "APP_UNAVAILABLE", "BRIDGE_UNAVAILABLE", "ENGINE_UNAVAILABLE", "INCOMPATIBLE_VERSION", "UNAVAILABLE": 3
        case "BUSY", "CAPACITY_EXCEEDED": 4
        case "CANCELLED", "USER_CANCELLED": 5
        case "TIMEOUT": 6
        case "FILE_ACCESS", "UNSAFE_PATH", "OUTPUT_EXISTS", "OUTPUT_DELIVERY_FAILED", "FILE_TOO_LARGE": 7
        case "OUTCOME_UNKNOWN", "JOB_UNKNOWN", "JOB_EXPIRED": 9
        case "VALIDATION_NOT_VALID": 10
        default: 8
        }
    }

    public var json: JSONValue {
        .object(["code": .string(code), "message": .string(message), "retryable": .bool(retryable)])
    }
}

public enum IntegrationLimits {
    public static let apiVersion = 1
    public static let maximumRequestBytes = 32 * 1024 * 1024
    // Leaves room for base64 and the JSON envelope within the 32 MiB wire limit.
    public static let maximumInputBytes = 23 * 1024 * 1024
    public static let maximumOutputBytes = 64 * 1024 * 1024
    public static let maximumRetainedBytes = 256 * 1024 * 1024
    public static let maximumJobs = 64
    public static let jobLifetime: TimeInterval = 30 * 60
    public static let methods: Set<String> = ["status", "inspect", "validate", "sign", "jobs.get", "jobs.cancel", "jobs.save", "register.list", "register.get", "ezzk.lookup", "session.close"]
}

public struct IntegrationRequest: Codable, Sendable, Equatable {
    public let apiVersion: Int
    public let requestId: String
    public let session: String
    public let method: String
    public let arguments: [String: JSONValue]

    public init(apiVersion: Int = 1, requestId: String = UUID().uuidString,
                session: String, method: String, arguments: [String: JSONValue] = [:]) {
        self.apiVersion = apiVersion
        self.requestId = requestId
        self.session = session
        self.method = method
        self.arguments = arguments
    }

    /// Decode at the trust boundary, before an unknown parameter can be ignored.
    public static func decode(_ data: Data) throws -> IntegrationRequest {
        guard data.count <= IntegrationLimits.maximumRequestBytes else {
            throw IntegrationError(code: "PAYLOAD_TOO_LARGE", message: "Integration request exceeds 32 MiB.")
        }
        do {
            let object = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let fields = object.object,
                  Set(fields.keys).isSubset(of: ["apiVersion", "requestId", "session", "method", "arguments"]) else {
                throw IntegrationError(code: "INVALID_REQUEST", message: "Unknown request fields or invalid envelope.")
            }
            let request = try JSONDecoder().decode(IntegrationRequest.self, from: data)
            try request.validate()
            return request
        } catch let error as IntegrationError { throw error }
        catch { throw IntegrationError(code: "INVALID_REQUEST", message: "Malformed integration request.") }
    }

    public func validate() throws {
        guard apiVersion == IntegrationLimits.apiVersion else {
            throw IntegrationError(code: "INCOMPATIBLE_VERSION", message: "This app supports integration API version 1.")
        }
        guard !requestId.isEmpty, requestId.utf8.count <= 256, !session.isEmpty, session.utf8.count <= 256 else {
            throw IntegrationError(code: "INVALID_REQUEST", message: "Missing or oversized request/session identifier.")
        }
        guard IntegrationLimits.methods.contains(method) else {
            throw IntegrationError(code: "UNSUPPORTED_METHOD", message: "Unsupported integration method: \(method).")
        }
    }
}

public struct IntegrationResponse: Codable, Sendable, Equatable {
    public let apiVersion: Int
    public let requestId: String
    public let ok: Bool
    public let result: JSONValue?
    public let error: IntegrationError?

    public init(apiVersion: Int = 1, requestId: String, ok: Bool, result: JSONValue? = nil, error: IntegrationError? = nil) {
        self.apiVersion = apiVersion
        self.requestId = requestId
        self.ok = ok
        self.result = result
        self.error = error
    }
    public init(requestId: String, result: JSONValue) { self.init(requestId: requestId, ok: true, result: result) }
    public init(requestId: String, error: IntegrationError) { self.init(requestId: requestId, ok: false, error: error) }
}

/// Exported only to the separately validated integration helper, never Safari.
@objc public protocol IntegrationBridgeProtocol {
    func execute(request: Data, reply: @escaping (Data) -> Void)
}
