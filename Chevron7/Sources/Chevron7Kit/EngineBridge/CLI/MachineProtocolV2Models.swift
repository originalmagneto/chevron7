// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

enum MachineV2Operation: String, Codable, Sendable, Equatable {
    case capabilities = "CAPABILITIES"
    case inspect = "INSPECT"
    case preview = "PREVIEW"
    case certificates = "CERTIFICATES"
    case sign = "SIGN"
    case timestamp = "TIMESTAMP"
    case validate = "VALIDATE"
    case evidence = "EVIDENCE"

    var requiresToken: Bool {
        self == .certificates || self == .sign
    }
}

struct MachineV2Request: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let requestID: String
    let operation: MachineV2Operation
    let payload: [String: JSONValue]

    static func capabilities(requestID: String) -> MachineV2Request {
        MachineV2Request(protocolVersion: 2, requestID: requestID, operation: .capabilities, payload: [:])
    }

    static func inspect(requestID: String) -> MachineV2Request {
        MachineV2Request(protocolVersion: 2, requestID: requestID, operation: .inspect, payload: [:])
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID = "requestId"
        case operation
        case payload
    }
}

struct SecureMachineV2Request: Sendable {
    let envelope: MachineV2Request
    let pin: Secret?
    let timestampAuthentication: TimestampAuthenticationSecret?

    init(
        envelope: MachineV2Request,
        pin: Secret? = nil,
        timestampAuthentication: TimestampAuthenticationSecret? = nil
    ) {
        self.envelope = envelope
        self.pin = pin
        self.timestampAuthentication = timestampAuthentication
    }

    func discardSecrets() {
        pin?.discard()
        timestampAuthentication?.discard()
    }
}

enum MachineV2EventType: String, Codable, Sendable, Equatable {
    case requestStarted = "request.started"
    case certificatesAvailable = "certificates.available"
    case inspectionCompleted = "inspection.completed"
    case previewCompleted = "preview.completed"
    case validationCompleted = "validation.completed"
    case evidenceCompleted = "evidence.completed"
    case fileSigningStarted = "file.signingStarted"
    case fileProgress = "file.progress"
    case fileCompleted = "file.completed"
    case fileFailed = "file.failed"
    case requestCompleted = "request.completed"
    case requestFailed = "request.failed"

    var isTerminal: Bool {
        self == .requestCompleted || self == .requestFailed
    }
}

struct MachineV2Event: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let requestID: String
    let type: MachineV2EventType
    let emittedAt: String
    let fileID: String?
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID = "requestId"
        case type
        case emittedAt
        case fileID = "fileId"
        case payload
    }
}

enum MachineV2ProtocolFailure: Error, Sendable, Equatable {
    case malformedJSON
    case malformedPayload
    case unsupportedProtocolVersion
    case unknownEventType
}

enum MachineV2RequestEncoder {
    static func encode(_ request: SecureMachineV2Request) -> Data {
        var pinBytes = request.pin?.consumeBytes() ?? []
        defer { pinBytes.zeroize() }
        var authenticationBytes: [UInt8] = []
        defer { authenticationBytes.zeroize() }

        var payload = request.envelope.payload
        // Neautentizované operácie musia mať skutočne prázdny payload.
        if request.pin != nil {
            payload["pin"] = .string(String(decoding: pinBytes, as: UTF8.self))
        }
        if let authentication = request.timestampAuthentication {
            let encodedAuthentication: [String: JSONValue]
            switch authentication {
            case .basic(let username, let password):
                authenticationBytes = password.consumeBytes() ?? []
                encodedAuthentication = [
                    "type": .string("basic"),
                    "username": .string(username),
                    "password": .string(String(decoding: authenticationBytes, as: UTF8.self))
                ]
            case .bearer(let token):
                authenticationBytes = token.consumeBytes() ?? []
                encodedAuthentication = [
                    "type": .string("bearer"),
                    "token": .string(String(decoding: authenticationBytes, as: UTF8.self))
                ]
            }
            var timestamp = object(in: payload["timestamp"]) ?? [:]
            timestamp["authentication"] = .object(encodedAuthentication)
            payload["timestamp"] = .object(timestamp)
        }
        let envelope = MachineV2Request(
            protocolVersion: request.envelope.protocolVersion,
            requestID: request.envelope.requestID,
            operation: request.envelope.operation,
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(envelope)) ?? Data()
    }

    private static func object(in value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }
}

enum MachineV2ProtocolDecoder {
    static func decode(_ data: Data) throws -> MachineV2Event {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MachineV2ProtocolFailure.malformedJSON
        }
        let allowedKeys: Set<String> = ["protocolVersion", "requestId", "type", "emittedAt", "fileId", "payload"]
        let requiredKeys: Set<String> = ["protocolVersion", "requestId", "type", "emittedAt", "payload"]
        guard Set(object.keys).isSubset(of: allowedKeys),
              requiredKeys.isSubset(of: Set(object.keys)),
              object["protocolVersion"] as? Int == 2,
              let requestID = object["requestId"] as? String,
              !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let typeValue = object["type"] as? String,
              MachineV2EventType(rawValue: typeValue) != nil,
              object["payload"] as? [String: Any] != nil,
              let emittedAt = object["emittedAt"] as? String,
              validTimestamp(emittedAt),
              object["fileId"] == nil || object["fileId"] is NSNull || object["fileId"] is String,
              let event = try? JSONDecoder().decode(MachineV2Event.self, from: data) else {
            throw MachineV2ProtocolFailure.malformedPayload
        }
        return event
    }

    private static func validTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil {
            return true
        }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) != nil
    }
}
