// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import Foundation

/// `evidence.completed` payloads in the shape the engine's EVIDENCE operation writes, for the
/// E→E tests of both test targets. Values follow `ConversionEvidenceService` (engine).
public enum E2EEvidenceFixtures {
    public struct Timestamp {
        public var id = "T-1"
        public var type = "SIGNATURE_TIMESTAMP"
        public var productionTime = "2026-10-10T08:15:30Z"
        public var producerCommonName = "Sectigo Qualified Time Stamping Signer #2"
        public var indication = "PASSED"
        public var qualification = "QTSA"

        public init() {}
    }

    /// A PDF document timestamp (DSS `DOCUMENT_TIMESTAMP`) as the engine lists it.
    public struct DocumentTimestamp {
        public var id = "T-DOC-1"
        public var productionTime = "2026-10-11T07:00:00Z"
        public var producerCommonName = "BOSA TSA"
        public var indication = "PASSED"
        public var qualification = "QTSA"
        public var coveredRevisionLength: Int? = nil

        public init() {}
    }

    public struct Signature {
        public var id = "S-1"
        public var indication = "TOTAL_PASSED"
        public var subIndication: String? = nil
        public var qualification = "QESIG"
        public var format = "PAdES-BASELINE-T"
        public var signer = "Ján Klient"
        public var signingTime = "2026-10-10T08:15:00Z"
        public var signedRevisionLength: Int? = nil
        public var serialNumber: String? = "PNOSK-1234567890"
        public var mandants: [String] = []
        public var mandate: String? = nil
        public var policies: [[String: String]] = []
        public var qcCompliance = true
        public var qcType: String? = "esign"
        public var productionPlace: String? = nil
        public var trustedListUnavailable = false
        public var trustServiceTypes: [String] = []
        public var signatureValue = Data("signature-value-1".utf8)
        public var documents: [String] = []
        public var timestamps: [Timestamp] = [Timestamp()]
        /// The container's signature file, `META-INF/signatures...xml`; none for PAdES.
        public var signatureFilename: String? = nil

        public init() {}
    }

    public struct PDF {
        public var declaredPdfaPart: Int? = nil
        public var declaredPdfaConformance: String? = nil
        public var pdfaCompliant = false
        public var hasEmbeddedFiles = false
        public var changesAfterLastSignature: [String] = []
        public var asicDataObjectName: String? = nil
        public var asicDataObjectSigned = false
        public var asicDataObjectCount: Int? = nil
        public var duplicateDataObjectName: String? = nil

        public init() {}
    }

    /// A container file as the engine lists it. `size` and `sha256Base64` come from `bytes`.
    public struct DataObject {
        public var name: String
        public var bytes: Data
        public var kind = "pdf"
        public var coveredBy: [String] = []
        public var problem: String? = nil
        public var pages: Int? = nil
        public var embeddedFileNames: [String] = []
        public var widthPx: Int? = nil
        public var heightPx: Int? = nil
        /// Signatures of the PDF's own PAdES revisions; non-empty adds the nested `evidence`, as
        /// do document timestamps alone.
        public var nestedSignatures: [Signature] = []
        public var nestedPDF: PDF? = nil
        /// The PDF's own document timestamps, listed in the nested `evidence`.
        public var nestedDocumentTimestamps: [DocumentTimestamp] = []
        /// The nested evidence's own validation time.
        public var nestedValidationTime = E2EEvidenceFixtures.validationTime
        /// Whether the tree lists the nested signatures under this data object, as the engine does.
        public var treeNested = true
        /// The tree's `nestedSkipped` reason, in place of `nested`, as for a data object over the size limit.
        public var treeSkipped: String? = nil

        public init(name: String, bytes: Data = Data("%PDF-1.7".utf8)) {
            self.name = name
            self.bytes = bytes
        }
    }

    public static let validationTime = "2026-10-16T09:30:00Z"

    public static func payload(signatures: [Signature], pdf: PDF? = PDF(), dataObjects: [DataObject] = [],
                               documentTimestamps: [DocumentTimestamp] = []) -> Data {
        let (tree, evidence) = evidenceBody(signatures: signatures, pdf: pdf, dataObjects: dataObjects,
                                            documentTimestamps: documentTimestamps)
        let payload: [String: Any] = ["signatures": tree, "documents": dataObjects.map(treeDocumentJSON),
                                      "evidence": evidence]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// The tree entries and the `evidence` object, also the shape of a data object's nested `evidence`.
    private static func evidenceBody(signatures: [Signature], pdf: PDF?, dataObjects: [DataObject],
                                     documentTimestamps: [DocumentTimestamp] = [],
                                     validationTime: String = E2EEvidenceFixtures.validationTime) -> ([[String: Any]], [String: Any]) {
        var tree: [[String: Any]] = []
        var facts: [[String: Any]] = []
        for signature in signatures {
            var entry: [String: Any] = [
                "id": signature.id, "format": signature.format, "signerDisplayName": signature.signer,
                "signerCertificateQualification": signature.qualification, "signingTime": signature.signingTime,
                "valid": signature.indication == "TOTAL_PASSED", "indication": signature.indication,
                "documents": signature.documents,
                "timestamps": signature.timestamps.map { [
                    "id": $0.id, "productionTime": $0.productionTime, "producer": $0.producerCommonName,
                    "valid": $0.indication == "PASSED", "qualification": $0.qualification, "type": $0.type,
                    "inSignedData": false
                ] as [String: Any] }
            ]
            if let sub = signature.subIndication { entry["subIndication"] = sub }
            tree.append(entry)
            var fact: [String: Any] = [
                "id": signature.id,
                "signatureValueBase64": signature.signatureValue.base64EncodedString(),
                "signerCommonName": signature.signer,
                "mandants": signature.mandants,
                "policies": signature.policies,
                "qcCompliance": signature.qcCompliance,
                "trustedListUnavailable": signature.trustedListUnavailable,
                "trustServiceTypes": signature.trustServiceTypes,
                "etsiSignatureReportBase64": Data("<ValidationReport id=\"\(signature.id)\"/>".utf8).base64EncodedString(),
                "timestamps": signature.timestamps.map { [
                    "id": $0.id, "type": $0.type, "productionTime": $0.productionTime,
                    "producerCommonName": $0.producerCommonName, "indication": $0.indication,
                    "qualification": $0.qualification
                ] }
            ]
            if let value = signature.signedRevisionLength { fact["signedRevisionLength"] = value }
            if let value = signature.serialNumber { fact["signerSerialNumber"] = value }
            if let value = signature.mandate { fact["mandate"] = value }
            if let value = signature.qcType { fact["qcType"] = value }
            if let value = signature.productionPlace { fact["productionPlace"] = value }
            if let value = signature.signatureFilename { fact["signatureFilename"] = value }
            facts.append(fact)
        }
        var evidence: [String: Any] = [
            "validationTime": validationTime, "dssVersion": "6.4",
            "etsiReportBase64": Data("<ValidationReport/>".utf8).base64EncodedString(),
            "signatures": facts,
            "documentTimestamps": documentTimestamps.map { stamp -> [String: Any] in
                var json: [String: Any] = [
                    "id": stamp.id, "productionTime": stamp.productionTime,
                    "producerCommonName": stamp.producerCommonName, "indication": stamp.indication,
                    "qualification": stamp.qualification
                ]
                if let value = stamp.coveredRevisionLength { json["coveredRevisionLength"] = value }
                return json
            }
        ]
        if let pdf {
            var facts: [String: Any] = [
                "pdfaCompliant": pdf.pdfaCompliant, "pdfaErrors": [String](), "hasEmbeddedFiles": pdf.hasEmbeddedFiles,
                "changesAfterLastSignature": pdf.changesAfterLastSignature,
                "asicDataObjectSigned": pdf.asicDataObjectSigned
            ]
            if let value = pdf.declaredPdfaPart { facts["declaredPdfaPart"] = value }
            if let value = pdf.declaredPdfaConformance { facts["declaredPdfaConformance"] = value }
            if let value = pdf.asicDataObjectName { facts["asicDataObjectName"] = value }
            if let value = pdf.asicDataObjectCount { facts["asicDataObjectCount"] = value }
            if let value = pdf.duplicateDataObjectName { facts["duplicateDataObjectName"] = value }
            if !dataObjects.isEmpty { facts["dataObjects"] = dataObjects.map(dataObjectJSON) }
            evidence["pdf"] = facts
        }
        return (tree, evidence)
    }

    private static func dataObjectJSON(_ object: DataObject) -> [String: Any] {
        var json: [String: Any] = [
            "name": object.name, "size": object.bytes.count,
            "sha256Base64": Data(SHA256.hash(data: object.bytes)).base64EncodedString(),
            "kind": object.kind, "coveredBy": object.coveredBy
        ]
        if let value = object.problem { json["problem"] = value }
        if let value = object.pages { json["pages"] = value }
        if object.kind == "pdf" && object.problem != "NESTED_UNREADABLE" || !object.embeddedFileNames.isEmpty {
            json["embeddedFileNames"] = object.embeddedFileNames
        }
        if let value = object.widthPx { json["widthPx"] = value }
        if let value = object.heightPx { json["heightPx"] = value }
        if object.kind == "pdf" {
            let own = object.nestedPDF ?? PDF()
            for (key, value) in pdfFacts(own) { json[key] = value }
            if !object.nestedSignatures.isEmpty || !object.nestedDocumentTimestamps.isEmpty {
                json["evidence"] = evidenceBody(signatures: object.nestedSignatures, pdf: own, dataObjects: [],
                                                documentTimestamps: object.nestedDocumentTimestamps,
                                                validationTime: object.nestedValidationTime).1
            }
        }
        return json
    }

    /// The tree's entry for a data object: as the engine's inspection lists them, every PDF
    /// carries `nested` with its PAdES signatures, an empty list for an unsigned one.
    private static func treeDocumentJSON(_ object: DataObject) -> [String: Any] {
        var json: [String: Any] = ["name": object.name]
        if let reason = object.treeSkipped {
            json["nestedSkipped"] = reason
        } else if object.treeNested && object.kind == "pdf" {
            let tree = evidenceBody(signatures: object.nestedSignatures, pdf: nil, dataObjects: []).0
            json["nested"] = ["kind": "PDF", "signatures": tree, "documents": [Any]()] as [String: Any]
        }
        return json
    }

    private static func pdfFacts(_ pdf: PDF) -> [String: Any] {
        var facts: [String: Any] = [
            "pdfaCompliant": pdf.pdfaCompliant, "pdfaErrors": [String](), "hasEmbeddedFiles": pdf.hasEmbeddedFiles,
            "changesAfterLastSignature": pdf.changesAfterLastSignature,
            "asicDataObjectSigned": pdf.asicDataObjectSigned
        ]
        if let value = pdf.declaredPdfaPart { facts["declaredPdfaPart"] = value }
        if let value = pdf.declaredPdfaConformance { facts["declaredPdfaConformance"] = value }
        return facts
    }
}
