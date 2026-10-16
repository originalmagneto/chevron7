// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

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

        public init() {}
    }

    public static let validationTime = "2026-10-16T09:30:00Z"

    public static func payload(signatures: [Signature], pdf: PDF? = PDF()) -> Data {
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
            facts.append(fact)
        }
        var evidence: [String: Any] = [
            "validationTime": validationTime, "dssVersion": "6.4",
            "etsiReportBase64": Data("<ValidationReport/>".utf8).base64EncodedString(),
            "signatures": facts
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
            evidence["pdf"] = facts
        }
        let payload: [String: Any] = ["signatures": tree, "documents": [Any](), "evidence": evidence]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
