// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// What the engine's `EVIDENCE` operation reports about an original for a guaranteed
/// conversion of an electronic document (E→E): the validated signature tree, the ETSI
/// TS 119 102-2 report, per signature the facts the clause and record carry, and the PDF facts
/// that decide whether the PDF may stay byte for byte.
public struct ConversionEvidence: Sendable, Equatable {
    public struct Policy: Sendable, Equatable, Codable {
        public var oid: String
        public var explicitText: String?
    }

    public struct Timestamp: Sendable, Equatable {
        public var id: String
        /// DSS `TimestampType` name, e.g. `SIGNATURE_TIMESTAMP` or `DOCUMENT_TIMESTAMP`.
        public var type: String?
        public var productionTime: Date?
        /// Common name of the timestamp unit's certificate, as the clause asks.
        public var producerCommonName: String?
        /// DSS indication: `PASSED`, `INDETERMINATE` or `FAILED`.
        public var indication: String?
        /// DSS timestamp qualification, `QTSA` for a qualified one.
        public var qualification: String?
    }

    public struct Signature: Sendable, Equatable {
        public var id: String
        public var signatureValue: Data
        /// End of the PAdES signature's `/ByteRange`: the signed revision is that prefix.
        public var signedRevisionLength: Int?
        public var signerCommonName: String?
        /// Subject `serialNumber` (2.5.4.5), e.g. `PNOSK-...`.
        public var signerSerialNumber: String?
        public var mandants: [String]
        public var policies: [Policy]
        /// Last arc of the Slovak mandate policy plus its explicit text, e.g. `1042 OPRÁVNENIE 1042`.
        public var mandate: String?
        public var qcCompliance: Bool
        /// `esign` or `eseal` from the certificate's QcType.
        public var qcType: String?
        public var productionPlace: String?
        /// INDETERMINATE only because the trusted list of the anchor's country did not load.
        public var trustedListUnavailable: Bool
        public var trustServiceTypes: [String]
        /// A schema-valid ETSI report with only this signature, validation objects as identifiers.
        public var slimReport: Data
        /// Timestamps that prove the signature existed (produced after its creation).
        public var timestamps: [Timestamp]
    }

    public struct PDFFacts: Sendable, Equatable {
        public var declaredPdfaPart: Int?
        public var declaredPdfaConformance: String?
        /// veraPDF (DSS `PDFAStructureValidator`) against the declared profile.
        public var pdfaCompliant: Bool
        public var pdfaErrors: [String]
        public var hasEmbeddedFiles: Bool
        /// DSS change kinds after the last PAdES signature other than extension data.
        public var changesAfterLastSignature: [String]
        public var asicDataObjectName: String?
        public var asicDataObjectSigned: Bool
        public var asicDataObjectCount: Int?
    }

    public var tree: SignatureTree
    public var validationTime: Date
    public var dssVersion: String
    public var etsiReport: Data
    public var signatures: [Signature]
    public var pdf: PDFFacts?

    public init(tree: SignatureTree, validationTime: Date, dssVersion: String, etsiReport: Data,
                signatures: [Signature], pdf: PDFFacts?) {
        self.tree = tree
        self.validationTime = validationTime
        self.dssVersion = dssVersion
        self.etsiReport = etsiReport
        self.signatures = signatures
        self.pdf = pdf
    }

    public func signature(id: String) -> Signature? {
        signatures.first { $0.id == id }
    }
}

extension ConversionEvidence {
    /// Decodes an `evidence.completed` payload: the tree keys at the top, the rest under `evidence`.
    static func decode(payload: [String: JSONValue]) throws -> ConversionEvidence {
        guard let evidence = payload["evidence"] else { throw ProtocolFailure.malformedPayload }
        let raw = try JSONDecoder().decode(Raw.self, from: JSONEncoder().encode(evidence))
        return try raw.evidence(tree: SignatureTreeDecoder.tree(from: payload))
    }

    /// Decodes the JSON of an `evidence.completed` payload, for fixtures and the app's tests.
    public static func decode(payloadJSON: Data) throws -> ConversionEvidence {
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: payloadJSON)
        return try decode(payload: payload)
    }

    private struct Raw: Decodable {
        struct RawSignature: Decodable {
            var id: String
            var signatureValueBase64: String?
            var signedRevisionLength: Int?
            var signerCommonName: String?
            var signerSerialNumber: String?
            var mandants: [String]?
            var policies: [Policy]?
            var mandate: String?
            var qcCompliance: Bool?
            var qcType: String?
            var productionPlace: String?
            var trustedListUnavailable: Bool?
            var trustServiceTypes: [String]?
            var etsiSignatureReportBase64: String?
            var timestamps: [RawTimestamp]?
        }

        struct RawTimestamp: Decodable {
            var id: String
            var type: String?
            var productionTime: String?
            var producerCommonName: String?
            var indication: String?
            var qualification: String?
        }

        struct RawPDF: Decodable {
            var declaredPdfaPart: Int?
            var declaredPdfaConformance: String?
            var pdfaCompliant: Bool?
            var pdfaErrors: [String]?
            var hasEmbeddedFiles: Bool?
            var changesAfterLastSignature: [String]?
            var asicDataObjectName: String?
            var asicDataObjectSigned: Bool?
            var asicDataObjectCount: Int?
        }

        var validationTime: String
        var dssVersion: String
        var etsiReportBase64: String
        var signatures: [RawSignature]
        var pdf: RawPDF?

        func evidence(tree: SignatureTree) throws -> ConversionEvidence {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            guard let time = formatter.date(from: validationTime) ?? plain.date(from: validationTime),
                  let report = Data(base64Encoded: etsiReportBase64) else {
                throw ProtocolFailure.malformedPayload
            }
            let date = { (text: String?) -> Date? in
                text.flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }
            }
            let signatures = try self.signatures.map { raw -> Signature in
                guard let value = raw.signatureValueBase64.flatMap({ Data(base64Encoded: $0) }),
                      let slim = raw.etsiSignatureReportBase64.flatMap({ Data(base64Encoded: $0) }) else {
                    throw ProtocolFailure.malformedPayload
                }
                return Signature(id: raw.id, signatureValue: value, signedRevisionLength: raw.signedRevisionLength,
                                 signerCommonName: raw.signerCommonName, signerSerialNumber: raw.signerSerialNumber,
                                 mandants: raw.mandants ?? [], policies: raw.policies ?? [], mandate: raw.mandate,
                                 qcCompliance: raw.qcCompliance ?? false, qcType: raw.qcType,
                                 productionPlace: raw.productionPlace,
                                 trustedListUnavailable: raw.trustedListUnavailable ?? false,
                                 trustServiceTypes: raw.trustServiceTypes ?? [], slimReport: slim,
                                 timestamps: (raw.timestamps ?? []).map {
                                     Timestamp(id: $0.id, type: $0.type, productionTime: date($0.productionTime),
                                               producerCommonName: $0.producerCommonName, indication: $0.indication,
                                               qualification: $0.qualification)
                                 })
            }
            let pdf = self.pdf.map {
                PDFFacts(declaredPdfaPart: $0.declaredPdfaPart, declaredPdfaConformance: $0.declaredPdfaConformance,
                         pdfaCompliant: $0.pdfaCompliant ?? false, pdfaErrors: $0.pdfaErrors ?? [],
                         hasEmbeddedFiles: $0.hasEmbeddedFiles ?? false,
                         changesAfterLastSignature: $0.changesAfterLastSignature ?? [],
                         asicDataObjectName: $0.asicDataObjectName, asicDataObjectSigned: $0.asicDataObjectSigned ?? false,
                         asicDataObjectCount: $0.asicDataObjectCount)
            }
            return ConversionEvidence(tree: tree, validationTime: time, dssVersion: dssVersion, etsiReport: report,
                                      signatures: signatures, pdf: pdf)
        }
    }
}
