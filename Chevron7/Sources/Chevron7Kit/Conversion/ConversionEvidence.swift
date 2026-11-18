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

    /// A PDF document timestamp (DSS `DOCUMENT_TIMESTAMP`): it covers the revision that ends
    /// at `coveredRevisionLength`, the end of its `/ByteRange`.
    public struct DocumentTimestamp: Sendable, Equatable {
        public var id: String
        public var productionTime: Date?
        /// Common name of the timestamp unit's certificate.
        public var producerCommonName: String?
        /// DSS indication: `PASSED`, `INDETERMINATE` or `FAILED`.
        public var indication: String?
        /// DSS timestamp qualification, `QTSA` for a qualified one.
        public var qualification: String?
        public var coveredRevisionLength: Int?
    }

    /// A content timestamp in a signature's signed data: XAdES (DSS `ALL_DATA_OBJECTS_TIMESTAMP`
    /// or `INDIVIDUAL_DATA_OBJECTS_TIMESTAMP`) or the CAdES and PAdES signed attribute
    /// `id-aa-ets-contentTimestamp` (DSS `CONTENT_TIMESTAMP`).
    public struct ContentTimestamp: Sendable, Equatable {
        public var id: String
        /// The signature that carries it.
        public var signatureID: String
        /// DSS `TimestampType` name.
        public var type: String?
        public var productionTime: Date?
        /// Common name of the timestamp unit's certificate.
        public var producerCommonName: String?
        /// DSS indication: `PASSED`, `INDETERMINATE` or `FAILED`.
        public var indication: String?
        /// DSS timestamp qualification, `QTSA` for a qualified one.
        public var qualification: String?
        /// The data objects it covers, by DSS's timestamp scope names (the entry names).
        public var coveredDataObjects: [String]
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
        /// The container's signature file, e.g. `META-INF/signatures001.xml`; nil for PAdES.
        public var signatureFilename: String? = nil
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
        /// Every data object of a container in zip entry order; empty for a PDF source or an old payload.
        public var dataObjects: [DataObject] = []
        /// A data object name the container holds more than once, as the engine read it.
        public var duplicateDataObjectName: String? = nil
    }

    /// One file of a container: what its bytes are, who signed it, and for a PDF or an image what it holds.
    public struct DataObject: Sendable, Equatable {
        public enum Kind: String, Sendable { case pdf, png, jpeg, other }

        public var name: String
        public var size: Int
        public var sha256: Data
        public var kind: Kind
        /// Ids of the container signatures whose scope names this file.
        public var coveredBy: [String]
        /// `TOO_LARGE`, `UNREADABLE` or `NESTED_UNREADABLE` (a PDF whose own signatures could not be read).
        public var problem: String?
        public var pdf: PDFFacts?
        public var pages: Int?
        public var embeddedFileNames: [String]
        public var widthPx: Int?
        public var heightPx: Int?
        /// The PDF's own PAdES signatures, validated on their own (JSON key `evidence`).
        public var nested: NestedEvidence?
    }

    public struct NestedEvidence: Sendable, Equatable {
        public var validationTime: Date
        public var etsiReport: Data
        public var signatures: [Signature]
        public var pdf: PDFFacts
        /// The PDF's own document timestamps; empty for an old payload.
        public var documentTimestamps: [DocumentTimestamp] = []
        /// Content timestamps inside the PDF's own PAdES signatures (DSS `CONTENT_TIMESTAMP`);
        /// empty for an old payload.
        public var contentTimestamps: [ContentTimestamp] = []
    }

    public var tree: SignatureTree
    public var validationTime: Date
    public var dssVersion: String
    public var etsiReport: Data
    public var signatures: [Signature]
    public var pdf: PDFFacts?
    /// Document timestamps of a PDF original; empty for a container or an old payload.
    public var documentTimestamps: [DocumentTimestamp]
    /// Content timestamps in the signatures' signed data: XAdES and CAdES ones of a container's
    /// signatures, a PAdES one of a PDF original's signatures; empty for an old payload.
    public var contentTimestamps: [ContentTimestamp]

    public init(tree: SignatureTree, validationTime: Date, dssVersion: String, etsiReport: Data,
                signatures: [Signature], pdf: PDFFacts?, documentTimestamps: [DocumentTimestamp] = [],
                contentTimestamps: [ContentTimestamp] = []) {
        self.tree = tree
        self.validationTime = validationTime
        self.dssVersion = dssVersion
        self.etsiReport = etsiReport
        self.signatures = signatures
        self.pdf = pdf
        self.documentTimestamps = documentTimestamps
        self.contentTimestamps = contentTimestamps
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
            var signatureFilename: String?
        }

        struct RawDocumentTimestamp: Decodable {
            var id: String
            var productionTime: String?
            var producerCommonName: String?
            var indication: String?
            var qualification: String?
            var coveredRevisionLength: Int?
        }

        struct RawContentTimestamp: Decodable {
            var id: String
            /// Optional so a missing value degrades only this timestamp (record 1.2 refuses it).
            var signatureId: String?
            var type: String?
            var productionTime: String?
            var producerCommonName: String?
            var indication: String?
            var qualification: String?
            var coveredDataObjects: [String]?
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
            var dataObjects: [RawDataObject]?
            var duplicateDataObjectName: String?
        }

        struct RawNested: Decodable {
            var validationTime: String
            var etsiReportBase64: String
            var signatures: [RawSignature]
            var pdf: RawPDF?
            var documentTimestamps: [RawDocumentTimestamp]?
            var contentTimestamps: [RawContentTimestamp]?
        }

        /// A data object's JSON carries the PDF facts flat beside its own keys.
        struct RawDataObject: Decodable {
            var name: String
            var size: Int?
            var sha256Base64: String?
            var kind: String?
            var coveredBy: [String]?
            var problem: String?
            var pages: Int?
            var embeddedFileNames: [String]?
            var widthPx: Int?
            var heightPx: Int?
            var evidence: RawNested?
            /// The nested `evidence` is present but its JSON does not decode (a missing or
            /// wrongly typed key): only this data object degrades, never the whole evidence.
            var evidenceUnreadable = false
            var pdf: RawPDF?

            private enum CodingKeys: String, CodingKey {
                case name, size, sha256Base64, kind, coveredBy, problem, pages, embeddedFileNames
                case widthPx, heightPx, evidence
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                size = try container.decodeIfPresent(Int.self, forKey: .size)
                sha256Base64 = try container.decodeIfPresent(String.self, forKey: .sha256Base64)
                kind = try container.decodeIfPresent(String.self, forKey: .kind)
                coveredBy = try container.decodeIfPresent([String].self, forKey: .coveredBy)
                problem = try container.decodeIfPresent(String.self, forKey: .problem)
                pages = try container.decodeIfPresent(Int.self, forKey: .pages)
                embeddedFileNames = try container.decodeIfPresent([String].self, forKey: .embeddedFileNames)
                widthPx = try container.decodeIfPresent(Int.self, forKey: .widthPx)
                heightPx = try container.decodeIfPresent(Int.self, forKey: .heightPx)
                if container.contains(.evidence) {
                    evidence = try? container.decode(RawNested.self, forKey: .evidence)
                    evidenceUnreadable = evidence == nil
                }
                pdf = (kind == "pdf") ? try RawPDF(from: decoder) : nil
            }
        }

        var validationTime: String
        var dssVersion: String
        var etsiReportBase64: String
        var signatures: [RawSignature]
        var pdf: RawPDF?
        var documentTimestamps: [RawDocumentTimestamp]?
        var contentTimestamps: [RawContentTimestamp]?

        private static func parseDate(_ text: String?) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            return text.flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }
        }

        private static func signature(_ raw: RawSignature) throws -> Signature {
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
                                 Timestamp(id: $0.id, type: $0.type, productionTime: parseDate($0.productionTime),
                                           producerCommonName: $0.producerCommonName, indication: $0.indication,
                                           qualification: $0.qualification)
                             },
                             signatureFilename: raw.signatureFilename)
        }

        private static func documentTimestamps(_ raw: [RawDocumentTimestamp]?) -> [DocumentTimestamp] {
            (raw ?? []).map {
                DocumentTimestamp(id: $0.id, productionTime: parseDate($0.productionTime),
                                  producerCommonName: $0.producerCommonName, indication: $0.indication,
                                  qualification: $0.qualification, coveredRevisionLength: $0.coveredRevisionLength)
            }
        }

        private static func contentTimestamps(_ raw: [RawContentTimestamp]?) -> [ContentTimestamp] {
            (raw ?? []).map {
                ContentTimestamp(id: $0.id, signatureID: $0.signatureId ?? "", type: $0.type,
                                 productionTime: parseDate($0.productionTime),
                                 producerCommonName: $0.producerCommonName, indication: $0.indication,
                                 qualification: $0.qualification, coveredDataObjects: $0.coveredDataObjects ?? [])
            }
        }

        private static func facts(_ raw: RawPDF) throws -> PDFFacts {
            PDFFacts(declaredPdfaPart: raw.declaredPdfaPart, declaredPdfaConformance: raw.declaredPdfaConformance,
                     pdfaCompliant: raw.pdfaCompliant ?? false, pdfaErrors: raw.pdfaErrors ?? [],
                     hasEmbeddedFiles: raw.hasEmbeddedFiles ?? false,
                     changesAfterLastSignature: raw.changesAfterLastSignature ?? [],
                     asicDataObjectName: raw.asicDataObjectName, asicDataObjectSigned: raw.asicDataObjectSigned ?? false,
                     asicDataObjectCount: raw.asicDataObjectCount,
                     dataObjects: try (raw.dataObjects ?? []).map(dataObject),
                     duplicateDataObjectName: raw.duplicateDataObjectName)
        }

        private static func dataObject(_ raw: RawDataObject) throws -> DataObject {
            guard let hash = raw.sha256Base64.flatMap({ Data(base64Encoded: $0) }), let size = raw.size else {
                throw ProtocolFailure.malformedPayload
            }
            var nested: NestedEvidence?
            var problem = raw.problem
            if raw.evidenceUnreadable {
                problem = problem ?? "NESTED_UNREADABLE"
            }
            if let item = raw.evidence {
                // One unreadable nested validation degrades this data object only, as in the engine.
                if let time = parseDate(item.validationTime), let report = Data(base64Encoded: item.etsiReportBase64),
                   let pdf = item.pdf, let signatures = try? item.signatures.map(signature),
                   let pdfFacts = try? facts(pdf) {
                    nested = NestedEvidence(validationTime: time, etsiReport: report, signatures: signatures,
                                            pdf: pdfFacts, documentTimestamps: documentTimestamps(item.documentTimestamps),
                                            contentTimestamps: contentTimestamps(item.contentTimestamps))
                } else {
                    problem = problem ?? "NESTED_UNREADABLE"
                }
            }
            return DataObject(name: raw.name, size: size, sha256: hash, kind: raw.kind.flatMap(DataObject.Kind.init) ?? .other,
                              coveredBy: raw.coveredBy ?? [], problem: problem, pdf: try raw.pdf.map(facts),
                              pages: raw.pages, embeddedFileNames: raw.embeddedFileNames ?? [],
                              widthPx: raw.widthPx, heightPx: raw.heightPx, nested: nested)
        }

        func evidence(tree: SignatureTree) throws -> ConversionEvidence {
            guard let time = Self.parseDate(validationTime), let report = Data(base64Encoded: etsiReportBase64) else {
                throw ProtocolFailure.malformedPayload
            }
            return ConversionEvidence(tree: tree, validationTime: time, dssVersion: dssVersion, etsiReport: report,
                                      signatures: try signatures.map(Self.signature),
                                      pdf: try pdf.map(Self.facts),
                                      documentTimestamps: Self.documentTimestamps(documentTimestamps),
                                      contentTimestamps: Self.contentTimestamps(contentTimestamps))
        }
    }
}
