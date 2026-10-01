// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Decodes the engine's inspection or validation payload (machine protocol v1 INSPECT,
/// v2 VALIDATE) into a `SignatureTree`. Both share one shape; only the states differ.
enum SignatureTreeDecoder {
    static func tree(from payload: [String: JSONValue]) -> SignatureTree {
        SignatureTree(
            signatures: array(payload["signatures"]).compactMap(signature(from:)),
            documents: array(payload["documents"]).compactMap(dataObject(from:)))
    }

    static func signature(from value: JSONValue) -> DocumentSignatureInfo? {
        guard case .object(let object) = value, let id = string(object["id"]) else { return nil }
        let indication = string(object["indication"])
        let state: DocumentSignatureInfo.State
        if indication?.uppercased().contains("INDETERMINATE") == true {
            state = .indeterminate
        } else if bool(object["valid"]) == true {
            state = .valid
        } else {
            state = .invalid
        }
        let timestamps = array(object["timestamps"])
        let intactTimestamp = timestamps.contains { timestamp in
            guard case .object(let fields) = timestamp else { return false }
            return bool(fields["cryptographicIntegrity"]) == true || bool(fields["valid"]) == true
        }
        return DocumentSignatureInfo(
            id: id,
            signerDisplayName: string(object["signerDisplayName"]) ?? "Neznámy podpisovateľ",
            format: string(object["format"]),
            signingTime: string(object["signingTime"]).flatMap { ISO8601DateFormatter().date(from: $0) },
            hasQualifiedTimestamp: bool(object["qualifiedTimestampValid"]) == true,
            hasTimestamp: intactTimestamp,
            state: state,
            detail: string(object["validationReason"]) ?? string(object["subIndication"]),
            coveredDocuments: array(object["documents"]).compactMap(string),
            certificateQualification: string(object["signerCertificateQualification"]))
    }

    private static func dataObject(from value: JSONValue) -> SignedDataObject? {
        guard case .object(let object) = value, let name = string(object["name"]) else { return nil }
        if case .object(let nested)? = object["nested"] {
            let kind = SignedDataObject.Kind(rawValue: string(nested["kind"]) ?? "") ?? .pdf
            return SignedDataObject(name: name, content: .signed(kind, tree(from: nested)))
        }
        if let skipped = string(object["nestedSkipped"]) {
            if let reason = SignedDataObject.SkipReason(rawValue: skipped) {
                return SignedDataObject(name: name, content: .skipped(reason))
            }
            // A future skip reason stays visible as an unverified data object.
            return SignedDataObject(name: name, content: .failed)
        }
        if string(object["nestedError"]) != nil {
            return SignedDataObject(name: name, content: .failed)
        }
        return SignedDataObject(name: name, content: .plain)
    }

    private static func array(_ value: JSONValue?) -> [JSONValue] {
        guard case .array(let values)? = value else { return [] }
        return values
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }
}
