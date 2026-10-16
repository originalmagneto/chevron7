// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import Foundation

public enum ElectronicOriginalError: LocalizedError, Equatable {
    case unsigned
    case notPDFOrContainer
    case unsupportedContainer(dataObjects: Int)
    case containerWithoutPDF
    case signedPDFInsideContainer
    case changedAfterLastSignature([String])
    case malformedEvidence

    public var errorDescription: String? {
        switch self {
        case .unsigned:
            return "Dokument nie je podpísaný. Zaručenú konverziu elektronického dokumentu Chevron7 zatiaľ vykoná len pre dokument, ktorý klient autorizoval."
        case .notPDFOrContainer:
            return "Pôvodný dokument musí byť PDF alebo kontajner ASiC-E."
        case .unsupportedContainer(let count):
            return "Kontajner obsahuje \(count) dokumentov. Chevron7 zatiaľ konvertuje len kontajner s jedným PDF."
        case .containerWithoutPDF:
            return "Kontajner neobsahuje PDF. Chevron7 zatiaľ konvertuje len kontajner s jedným PDF."
        case .signedPDFInsideContainer:
            return "PDF v kontajneri má aj vlastné podpisy. Takýto dokument Chevron7 zatiaľ nekonvertuje."
        case .changedAfterLastSignature(let changes):
            let kinds = changes.map(ElectronicOriginal.changeLabel).joined(separator: ", ")
            return "Dokument bol po poslednom podpise zmenený (\(kinds)). Tieto zmeny nikto neautorizoval, preto ho nemožno konvertovať."
        case .malformedEvidence:
            return "Výsledok overenia podpisov je neúplný. Skúste overenie znova."
        }
    }
}

/// The original of a guaranteed conversion of an electronic document (E→E), read from its
/// bytes and the engine's evidence: the original documents (one per signed PAdES revision, or
/// the container's PDF), every authorization with the values the clause and record carry, and
/// whether the PDF stays byte for byte. Independent of the form version.
public struct ElectronicOriginal: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case pdf
        case asicE(entryName: String)
    }

    public struct Document: Sendable, Equatable {
        public var name: String
        public var format: ZakoCodelistItem
        public var formatOther: String?
        public var sha256: Data
    }

    public enum ValidityState: String, Sendable, Equatable {
        case valid = "platná"
        case invalid = "neplatná"
        case undetermined = "nie je možné zistiť"

        public var item: ZakoCodelistItem { ZakoCodelistItem(code: rawValue, skName: rawValue) }
    }

    public struct Timestamp: Sendable, Equatable {
        public var qualified: Bool
        public var state: ValidityState
        public var created: Date
        public var publisherCommonName: String
        public var validationTime: Date

        public var typeItem: ZakoCodelistItem {
            qualified ? E2ECodelists.qualifiedTimestamp : E2ECodelists.nonQualifiedTimestamp
        }
    }

    public struct Authorization: Sendable, Equatable {
        public var signatureID: String
        public var signerName: String
        public var type: ZakoCodelistItem
        public var typeOther: String?
        public var documentNames: [String]
        public var state: ValidityState
        /// DSS's reason when the state is not `platná`.
        public var reason: String?
        public var signingTime: Date?
        public var validationTime: Date
        public var location: String
        public var personID: String
        public var mandant: String?
        public var mandate: String?
        public var timestamp: Timestamp?
        public var qualifiedCertificate: Bool
        public var signatureValue: Data
        public var slimReport: Data
        public var trustedListUnavailable: Bool

        public var otherInfo: String {
            "Kvalifikovaný certifikát: \(qualifiedCertificate ? "áno" : "nie")"
        }
    }

    public enum NewDocumentPlan: Sendable, Equatable {
        /// The PDF is valid PDF/A without embedded files and stays byte for byte.
        case keep(format: ZakoCodelistItem, formatOther: String?)
        /// The PDF becomes a new PDF/A-2b; `reason` is said to the advocate.
        case convert(reason: String)
    }

    public var sourceName: String
    public var kind: Kind
    /// The PDF that becomes the new document: the file itself, or the container's data object.
    public var pdfData: Data
    public var documents: [Document]
    public var authorizations: [Authorization]
    public var plan: NewDocumentPlan
    public var evidence: ConversionEvidence

    public static func make(sourceName: String, sourceData: Data,
                            evidence: ConversionEvidence) throws -> ElectronicOriginal {
        guard let pdf = evidence.pdf else { throw ElectronicOriginalError.notPDFOrContainer }
        let isPDF = sourceData.starts(with: Data("%PDF".utf8))
        let kind: Kind
        let pdfData: Data
        if isPDF {
            kind = .pdf
            pdfData = sourceData
        } else {
            let count = pdf.asicDataObjectCount ?? 0
            guard count == 1 else { throw ElectronicOriginalError.unsupportedContainer(dataObjects: count) }
            guard let entry = pdf.asicDataObjectName,
                  let data = ASiCEContainerVerifier.readEntries(sourceData)?.first(where: { $0.name == entry })?.data else {
                throw ElectronicOriginalError.containerWithoutPDF
            }
            guard !pdf.asicDataObjectSigned else { throw ElectronicOriginalError.signedPDFInsideContainer }
            kind = .asicE(entryName: entry)
            pdfData = data
        }
        guard !evidence.tree.signatures.isEmpty else { throw ElectronicOriginalError.unsigned }
        guard pdf.changesAfterLastSignature.isEmpty else {
            throw ElectronicOriginalError.changedAfterLastSignature(pdf.changesAfterLastSignature)
        }
        let format = documentFormat(pdf)

        var documents: [Document] = []
        var documentBySignature: [String: String] = [:]
        switch kind {
        case .asicE(let entry):
            documents = [Document(name: displayName(entry), format: format.item, formatOther: format.other,
                                  sha256: Data(SHA256.hash(data: pdfData)))]
            for signature in evidence.tree.signatures { documentBySignature[signature.id] = documents[0].name }
        case .pdf:
            var lengths: [Int] = []
            for signature in evidence.tree.signatures {
                guard let length = evidence.signature(id: signature.id)?.signedRevisionLength,
                      length > 0, length <= sourceData.count else {
                    throw ElectronicOriginalError.malformedEvidence
                }
                if !lengths.contains(length) { lengths.append(length) }
            }
            lengths.sort()
            let stem = (displayName(sourceName) as NSString).deletingPathExtension
            for (index, length) in lengths.enumerated() {
                let name = lengths.count == 1 ? displayName(sourceName) : "\(stem)-\(index + 1)"
                documents.append(Document(name: name, format: format.item, formatOther: format.other,
                                          sha256: Data(SHA256.hash(data: sourceData.prefix(length)))))
            }
            for signature in evidence.tree.signatures {
                if let length = evidence.signature(id: signature.id)?.signedRevisionLength,
                   let index = lengths.firstIndex(of: length) {
                    documentBySignature[signature.id] = documents[index].name
                }
            }
        }

        let authorizations = try evidence.tree.signatures.map { signature -> Authorization in
            guard let facts = evidence.signature(id: signature.id),
                  let document = documentBySignature[signature.id] else {
                throw ElectronicOriginalError.malformedEvidence
            }
            let type = authorizationType(qualification: signature.certificateQualification, qcType: facts.qcType)
            return Authorization(
                signatureID: signature.id,
                signerName: signature.signerDisplayName,
                type: type.item, typeOther: type.other,
                documentNames: [document],
                state: state(signature.state),
                reason: signature.state == .valid ? nil : signature.detail,
                signingTime: signature.signingTime,
                validationTime: evidence.validationTime,
                location: facts.productionPlace.flatMap { $0.isEmpty ? nil : String($0.prefix(255)) } ?? "Neuvedené",
                personID: facts.signerSerialNumber ?? facts.signerCommonName ?? signature.signerDisplayName,
                mandant: facts.mandants.isEmpty ? nil : String(facts.mandants.joined(separator: "; ").prefix(255)),
                mandate: facts.mandate.map { String($0.prefix(255)) },
                timestamp: timestamp(facts.timestamps, validationTime: evidence.validationTime),
                qualifiedCertificate: facts.qcCompliance,
                signatureValue: facts.signatureValue,
                slimReport: facts.slimReport,
                trustedListUnavailable: facts.trustedListUnavailable)
        }

        let plan: NewDocumentPlan
        if pdf.pdfaCompliant, let part = pdf.declaredPdfaPart, (1...3).contains(part), !pdf.hasEmbeddedFiles {
            plan = .keep(format: format.item, formatOther: format.other)
        } else if pdf.hasEmbeddedFiles {
            plan = .convert(reason: "PDF obsahuje vložené súbory (prílohy)")
        } else {
            plan = .convert(reason: "PDF nie je platné PDF/A")
        }
        return ElectronicOriginal(sourceName: sourceName, kind: kind, pdfData: pdfData, documents: documents,
                                  authorizations: authorizations, plan: plan, evidence: evidence)
    }

    /// Codelist 53: PDF/A-1 and A-2 have items, A-3 is `Iny` with its name, anything else `PDF`.
    static func documentFormat(_ pdf: ConversionEvidence.PDFFacts) -> (item: ZakoCodelistItem, other: String?) {
        guard pdf.pdfaCompliant, let part = pdf.declaredPdfaPart else { return (E2ECodelists.pdfFormat, nil) }
        switch part {
        case 1: return (E2ECodelists.pdfa1Format, nil)
        case 2: return (E2ECodelists.pdfa2Format, nil)
        case 3: return (E2ECodelists.otherFormat, "PDF/A-3")
        default: return (E2ECodelists.pdfFormat, nil)
        }
    }

    /// DSS `SignatureQualification` to codelist 54; seals and signatures told apart by QcType
    /// where DSS names neither.
    static func authorizationType(qualification: String?, qcType: String?) -> (item: ZakoCodelistItem, other: String?) {
        let value = (qualification ?? "").uppercased()
        let seal = qcType == "eseal"
        switch value {
        case "QESIG": return (E2ECodelists.qualifiedSignature, nil)
        case "QESEAL": return (E2ECodelists.qualifiedSeal, nil)
        case "ADESIG_QC", "ADESIG": return (E2ECodelists.advancedSignature, nil)
        case "ADESEAL_QC", "ADESEAL": return (E2ECodelists.advancedSeal, nil)
        default:
            if value.hasPrefix("NOT_ADES") {
                return (seal ? E2ECodelists.electronicSeal : E2ECodelists.electronicSignature, nil)
            }
            let shown = value.isEmpty ? "neznáma" : value
            return (E2ECodelists.otherAuthorization, "Kvalifikácia podpisu sa nedala určiť (DSS: \(shown))")
        }
    }

    static func state(_ state: DocumentSignatureInfo.State) -> ValidityState {
        switch state {
        case .valid: return .valid
        case .invalid: return .invalid
        default: return .undetermined
        }
    }

    /// The oldest valid timestamp proving the signature existed, as the form asks; without a
    /// valid one the oldest at all, so its state shows.
    static func timestamp(_ timestamps: [ConversionEvidence.Timestamp], validationTime: Date) -> Timestamp? {
        let dated = timestamps.filter { $0.productionTime != nil }
            .sorted { $0.productionTime! < $1.productionTime! }
        guard let chosen = dated.first(where: { $0.indication == "PASSED" }) ?? dated.first,
              let created = chosen.productionTime else { return nil }
        let state: ValidityState
        switch chosen.indication {
        case "PASSED": state = .valid
        case "FAILED": state = .invalid
        default: state = .undetermined
        }
        return Timestamp(qualified: chosen.qualification == "QTSA", state: state, created: created,
                         publisherCommonName: chosen.producerCommonName ?? "Neuvedené",
                         validationTime: validationTime)
    }

    static func displayName(_ name: String) -> String {
        String(((name as NSString).lastPathComponent).prefix(255))
    }

    static func changeLabel(_ change: String) -> String {
        switch change {
        case "ANNOTATION": return "poznámky alebo anotácie"
        case "SIGNATURE_OR_FORM_FILL": return "vyplnený formulár alebo nové pole"
        case "PAGE_DIFFERENCE": return "zmena strán"
        case "VISUAL_DIFFERENCE": return "viditeľná zmena obsahu"
        default: return "iná zmena"
        }
    }
}

/// Whether verification lets an E→E conversion continue (§ 36 ods. 4 písm. a) a b) zákona).
public enum E2EVerificationGate {
    public enum Decision: Sendable, Equatable {
        case blocked(String)
        /// Validity could not be determined; the advocate must confirm before it is recorded so.
        case needsConfirmation([ElectronicOriginal.Authorization])
        case ready
    }

    public static func decide(_ original: ElectronicOriginal) -> Decision {
        if original.authorizations.contains(where: \.trustedListUnavailable) {
            return .blocked("Overenie sa nepodarilo dokončiť, lebo sa nenačítal dôveryhodný zoznam. Skúste overenie znova.")
        }
        if let invalid = original.authorizations.first(where: { $0.state == .invalid }) {
            let reason = invalid.reason.map { " (\($0))" } ?? ""
            return .blocked("Podpis \(invalid.signerName) je neplatný\(reason). Zaručenú konverziu nemožno vykonať.")
        }
        if let invalid = original.authorizations.first(where: { $0.timestamp?.state == .invalid }) {
            return .blocked("Časová pečiatka podpisu \(invalid.signerName) je neplatná. Zaručenú konverziu nemožno vykonať.")
        }
        let undetermined = original.authorizations.filter {
            $0.state == .undetermined || $0.timestamp?.state == .undetermined
        }
        return undetermined.isEmpty ? .ready : .needsConfirmation(undetermined)
    }
}
