// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import CryptoKit
import Chevron7Kit
import Chevron7Integration

/// The integration dispatcher authorizes the session and snapshots input files before
/// calling here. Register and EZZK operations only read; they never invoke the status checker.
@MainActor
final class IntegrationReadService {
    private let settingsStore: AppSettingsStore
    private let validationBroker: IntegrationValidationBroker

    init(settingsStore: AppSettingsStore, validationBroker: IntegrationValidationBroker = .shared) {
        self.settingsStore = settingsStore
        self.validationBroker = validationBroker
    }

    func execute(method: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        try Task.checkCancellation()
        switch method {
        case "inspect", "validate":
            return try await inspect(arguments, validate: method == "validate")
        case "register.list":
            try requireReadableRegister()
            return try page(arguments)
        case "register.get":
            return Self.record(try existingRecord(arguments))
        case "ezzk.lookup":
            return try await lookUp(try existingRecord(arguments))
        default:
            throw IntegrationError(code: "INVALID_ARGUMENTS", message: "Neznáma operácia integrácie.")
        }
    }

    private func inspect(_ arguments: [String: JSONValue], validate: Bool) async throws -> JSONValue {
        let provider = settingsStore.signingProvider
        guard !(provider is DemoSigningProvider), !(provider is KeychainXAdESSigningProvider) else {
            throw IntegrationError(code: "ENGINE_UNAVAILABLE", message: "Podpisový engine nie je dostupný. Demo režim neposkytuje overenie podpisov.")
        }
        guard let path = arguments["file"]?.string, (path as NSString).isAbsolutePath else {
            throw IntegrationError(code: "INVALID_ARGUMENTS", message: "Zadajte absolútnu cestu k dokumentu.")
        }
        let url = URL(fileURLWithPath: path)
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw IntegrationError(code: "INVALID_ARGUMENTS", message: "Dokument musí byť bežný súbor.")
        }
        // Inspection provides useful structural evidence even when trusted validation fails.
        let inspected = await provider.inspectSignatureTree(in: url)
        try Task.checkCancellation()
        guard case .tree(let structural) = inspected else {
            throw IntegrationError(code: "INSPECTION_FAILED", message: "Štruktúru podpisov sa nepodarilo prečítať.")
        }
        guard validate else { return Self.treeResult(structural, validated: false) }
        let summary = SignatureTreeSummary(tree: structural)
        guard summary.total > 0 || summary.unverifiedDocuments > 0 else {
            return Self.treeResult(structural, validated: true)
        }
        let result = try await validationBroker.run { await provider.validateSignatureTree(in: url) }
        try Task.checkCancellation()
        switch result {
        case .tree(let tree): return Self.treeResult(tree, validated: true)
        case .failed(let reason):
            return Self.treeResult(structural, validated: false, failure: reason)
        }
    }

    private func requireReadableRegister() throws {
        guard settingsStore.evidenceStore.loadError == nil else {
            throw IntegrationError(code: "REGISTER_UNAVAILABLE", message: "Register konverzií sa nepodarilo načítať.")
        }
    }

    private func existingRecord(_ arguments: [String: JSONValue]) throws -> EvidenceRecord {
        try requireReadableRegister()
        guard let raw = arguments["recordId"]?.string, let id = UUID(uuidString: raw) else {
            throw IntegrationError(code: "INVALID_ARGUMENTS", message: "Zadajte platné ID záznamu registra.")
        }
        guard let record = settingsStore.evidenceStore.record(id: id) else {
            throw IntegrationError(code: "RECORD_NOT_FOUND", message: "Záznam sa v registri nenachádza.")
        }
        return record
    }

    private struct Cursor: Codable {
        let version: Int
        let fingerprint: String
        let offset: Int
    }

    private func page(_ arguments: [String: JSONValue]) throws -> JSONValue {
        let rawLimit = arguments["limit"]?.number ?? 25
        guard rawLimit.isFinite, rawLimit.rounded() == rawLimit, (1...100).contains(rawLimit),
              arguments["limit"] == nil || arguments["limit"]?.number != nil else {
            throw IntegrationError(code: "INVALID_ARGUMENTS", message: "Veľkosť stránky musí byť celé číslo od 1 do 100.")
        }
        let records = settingsStore.evidenceStore.records.sorted {
            if $0.conversionTime != $1.conversionTime { return $0.conversionTime > $1.conversionTime }
            return $0.id.uuidString < $1.id.uuidString
        }
        let fingerprint = SHA256.hash(data: Data(records.map {
            "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)"
        }.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        var offset = 0
        if let raw = arguments["cursor"] {
            guard let text = raw.string, text.utf8.count <= 1024, let data = Data(base64Encoded: text),
                  let cursor = try? JSONDecoder().decode(Cursor.self, from: data), cursor.version == 1,
                  cursor.offset >= 0, cursor.offset <= records.count else {
                throw IntegrationError(code: "INVALID_ARGUMENTS", message: "Neplatný ukazovateľ stránky registra.")
            }
            guard cursor.fingerprint == fingerprint else {
                throw IntegrationError(code: "CURSOR_EXPIRED", message: "Register sa zmenil. Načítajte prvú stránku znova.", retryable: true)
            }
            offset = cursor.offset
        }
        let end = min(offset + Int(rawLimit), records.count)
        let next: JSONValue = end < records.count
            ? .string(try JSONEncoder().encode(Cursor(version: 1, fingerprint: fingerprint, offset: end)).base64EncodedString())
            : .null
        return .object(["records": .array(records[offset..<end].map(Self.record)), "nextCursor": next,
                        "scope": .string("userRegister"), "total": .number(Double(records.count))])
    }

    private func lookUp(_ record: EvidenceRecord) async throws -> JSONValue {
        guard let mode = record.ezzkMode, mode != .demo,
              let number = record.evidenceNumber, !number.isEmpty else {
            throw IntegrationError(code: "EZZK_UNAVAILABLE", message: "Záznam nemá číslo a prostredie skutočnej evidencie EZZK.")
        }
        let controller = settingsStore.ezzkAccountController
        var fields: [String: JSONValue] = ["recordId": .string(record.id.uuidString), "mode": .string(mode.rawValue),
                                          "evidenceNumber": .string(number), "checkedAt": Self.date(Date())]
        var duplicateLookup = false
        do {
            let lookup: EZZKRecordLookup
            do { lookup = try await controller.lookUp(evidenceNumber: number, in: mode) }
            catch EZZKError.serviceRejected(let code, _) where code == 106 {
                duplicateLookup = true
                lookup = try await controller.lookUp(evidenceNumber: number, in: mode, executionTime: record.conversionTime)
            }
            fields["code"] = .number(lookup.isProcessed ? 0 : 1)
            fields["isProcessed"] = .bool(lookup.isProcessed)
            fields["executionTime"] = Self.date(lookup.info?.executionTime)
            fields["receiptTime"] = Self.date(lookup.info?.receiptTime)
            return .object(fields)
        } catch EZZKError.serviceRejected(let code, _) {
            // A server result is data, not an instruction to resend or mutate the row.
            fields["code"] = .number(Double(duplicateLookup && code == 105 ? 106 : code))
            if duplicateLookup { fields["timeFilteredCode"] = .number(Double(code)) }
            fields["isProcessed"] = .null
            return .object(fields)
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw IntegrationError(code: "EZZK_LOOKUP_FAILED", message: "Stav záznamu v EZZK sa nepodarilo overiť.", retryable: true)
        }
    }

    static func record(_ record: EvidenceRecord) -> JSONValue {
        .object(["id": .string(record.id.uuidString), "originalName": .string(record.originalName),
                 "newDocumentName": .string(record.newDocumentName), "evidenceNumber": optional(record.evidenceNumber),
                 "status": .string(statusCode(record.status)), "statusLabel": .string(record.status.rawValue),
                 "direction": .string(record.direction.rawValue), "conversionTime": date(record.conversionTime),
                 "updatedAt": date(record.updatedAt), "mode": optional(record.ezzkMode?.rawValue),
                 "fingerprintSHA256": .string(record.fingerprintSHA256Hex),
                 "ezzkResultCode": record.ezzkResultCode.map { .number(Double($0)) } ?? .null])
    }

    private static func statusCode(_ status: EvidenceRecord.Status) -> String {
        switch status {
        case .draft: "draft"
        case .awaitingNumber: "awaitingNumber"
        case .readyToSign: "readyToSign"
        case .signed: "signed"
        case .queuedForSubmission: "queuedForSubmission"
        case .submitted: "submitted"
        case .submissionFailed: "submissionFailed"
        case .acceptedForProcessing: "acceptedForProcessing"
        case .processed: "processed"
        case .outcomeUnknown: "outcomeUnknown"
        case .rejected: "rejected"
        case .recordUnsigned: "recordUnsigned"
        case .late: "late"
        }
    }

    static func treeResult(_ tree: SignatureTree, validated: Bool, failure: String? = nil) -> JSONValue {
        let summary = SignatureTreeSummary(tree: tree)
        let unsigned = summary.total == 0 && summary.unverifiedDocuments == 0
        let state = failure != nil ? "indeterminate" : unsigned ? "unsigned"
            : validated ? Self.state(summary.overall) : "notValidated"
        return .object(["validationState": .string(state), "validationPerformed": .bool(validated),
                        "validatedAt": validated ? date(Date()) : .null, "validationError": optional(failure),
                        "signatureCount": .number(Double(summary.total)),
                        "unverifiedDocumentCount": .number(Double(summary.unverifiedDocuments)),
                        "tree": treeJSON(tree, validated: validated)])
    }

    private static func treeJSON(_ tree: SignatureTree, validated: Bool) -> JSONValue {
        .object(["signatures": .array(tree.signatures.map { signature($0, validated: validated) }),
                 "documents": .array(tree.documents.map { document in
                     var fields: [String: JSONValue] = ["name": .string(document.name)]
                     switch document.content {
                     case .plain: fields["content"] = .string("plain")
                     case .signed(let kind, let nested):
                         fields["content"] = .string("signed")
                         fields["kind"] = .string(kind.rawValue)
                         fields["nested"] = treeJSON(nested, validated: validated)
                     case .skipped(let reason):
                         fields["content"] = .string("skipped")
                         fields["reason"] = .string(reason.rawValue)
                     case .failed: fields["content"] = .string("failed")
                     }
                     return .object(fields)
                 })])
    }

    private static func signature(_ value: DocumentSignatureInfo, validated: Bool) -> JSONValue {
        .object(["id": .string(value.id), "signerDisplayName": .string(value.signerDisplayName),
                 "format": optional(value.format), "signingTime": date(value.signingTime),
                 "state": .string(validated ? state(value.state) : "notValidated"), "detail": optional(value.detail),
                 "coveredDocuments": .array(value.coveredDocuments.map(JSONValue.string)),
                 "certificateQualification": validated ? optional(value.certificateQualification) : .null,
                 "hasTimestamp": .bool(value.hasTimestamp),
                 "hasQualifiedTimestamp": .bool(validated && value.hasQualifiedTimestamp),
                 "signatureTimestamp": .object(["authority": optional(value.timestampAuthority),
                                                  "time": date(value.timestampTime)]),
                 "dataTimestamp": value.dataTimestamp.map {
                     .object(["authority": optional($0.authority), "time": date($0.time),
                              "isQualified": .bool(validated && $0.isQualified)])
                 } ?? .null])
    }

    private static func state(_ state: DocumentSignatureInfo.State) -> String {
        state == .unknown ? "notValidated" : state.rawValue
    }
    private static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    private static func date(_ value: Date?) -> JSONValue {
        value.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
    }
}
