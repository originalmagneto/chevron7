// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import Foundation

public enum ElectronicOriginalError: LocalizedError, Equatable {
    case unsigned
    case notPDFOrContainer
    case containerWithoutPDF
    case changedAfterLastSignature([String])
    case malformedEvidence
    case unsupportedDataObject(name: String)
    case unreadableDataObject(name: String)
    case uncoveredDataObject(name: String)
    case nestedSignaturesUnreadable(name: String)
    case tooManyDocuments(Int)
    case tooManyAuthorizations(Int)

    public var errorDescription: String? {
        switch self {
        case .unsigned:
            return "Dokument nie je podpísaný. Zaručenú konverziu elektronického dokumentu Chevron7 zatiaľ vykoná len pre dokument, ktorý klient autorizoval."
        case .notPDFOrContainer:
            return "Pôvodný dokument musí byť PDF alebo kontajner ASiC-E."
        case .containerWithoutPDF:
            return "Kontajner neobsahuje PDF. Chevron7 zatiaľ konvertuje len kontajner s jedným PDF."
        case .changedAfterLastSignature(let changes):
            let kinds = changes.map(ElectronicOriginal.changeLabel).joined(separator: ", ")
            return "Dokument bol po poslednom podpise zmenený (\(kinds)). Tieto zmeny nikto neautorizoval, preto ho nemožno konvertovať."
        case .malformedEvidence:
            return "Výsledok overenia podpisov je neúplný. Skúste overenie znova."
        case .unsupportedDataObject(let name):
            return "Súbor \(name) nie je PDF ani obrázok PNG alebo JPEG. Chevron7 ho do nového dokumentu nevie zahrnúť."
        case .unreadableDataObject(let name):
            return "Súbor \(name) sa nepodarilo prečítať."
        case .uncoveredDataObject(let name):
            return "Súbor \(name) nepokrýva žiadny podpis kontajnera. Neautorizovaný súbor nemožno zaručene konvertovať."
        case .nestedSignaturesUnreadable(let name):
            return "Podpisy v súbore \(name) sa nepodarilo overiť. Skúste overenie znova."
        case .tooManyDocuments(let count):
            return "Kontajner obsahuje \(count) dokumentov. Formulár doložky ich pripúšťa najviac 999."
        case .tooManyAuthorizations(let count):
            return "Dokument má \(count) autorizácií. Formulár doložky ich pripúšťa najviac 99."
        }
    }
}

/// The original of a guaranteed conversion of an electronic document (E→E), read from its
/// bytes and the engine's evidence: the original documents (one per signed PAdES revision, the
/// container's only PDF, or every file of a container with several), every authorization with
/// the values the clause and record carry, and whether the PDF stays byte for byte. Every
/// fingerprint is exactly the bytes some signature signed. Independent of the form version.
public struct ElectronicOriginal: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case pdf
        /// A container whose only data object is an unsigned PDF.
        case asicE(entryName: String)
        /// Any other container: its PDFs (signed or not), PNG and JPEG images, in `files`.
        case asicEMultiple
    }

    public struct Document: Sendable, Equatable {
        public var name: String
        public var format: ZakoCodelistItem
        public var formatOther: String?
        public var sha256: Data
        /// The container entry this document was read from; nil for a PDF or a one-PDF container.
        public var fileEntryName: String? = nil
    }

    /// One data object of an `.asicEMultiple` container, in the order the new document joins them.
    public struct File: Sendable, Equatable {
        public var entryName: String
        /// The entry's file name, or its full path when another entry has the same file name.
        public var displayName: String
        public var kind: ConversionEvidence.DataObject.Kind
        public var data: Data
        /// The documents read from this file: its signed revisions, then the whole file when it differs.
        public var documentNames: [String]
        /// Files embedded in the PDF, which the new document does not carry over.
        public var embeddedFileNames: [String]
        /// DSS change kinds after the PDF's last own signature, authorized by the container signatures.
        public var changedAfterSignature: [String]
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
        /// The container entry of a nested PAdES signature; nil for a container or a top-level signature.
        public var fileEntryName: String? = nil

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

    /// The clause form's limits: `OriginalDocumentInfo` and the authorizations.
    public static let maximumDocuments = 999
    public static let maximumAuthorizations = 99

    public var sourceName: String
    public var kind: Kind
    /// The PDF that becomes the new document: the file itself, or the container's data object;
    /// for `.asicEMultiple` the first PDF file, empty when the container holds none.
    public var pdfData: Data
    public var documents: [Document]
    public var authorizations: [Authorization]
    public var plan: NewDocumentPlan
    public var evidence: ConversionEvidence
    /// The files of an `.asicEMultiple` container; empty otherwise.
    public var files: [File] = []

    public static func make(sourceName: String, sourceData: Data,
                            evidence: ConversionEvidence) throws -> ElectronicOriginal {
        guard let pdf = evidence.pdf else { throw ElectronicOriginalError.notPDFOrContainer }
        if sourceData.starts(with: Data("%PDF".utf8)) {
            return try makeSingle(sourceName: sourceName, kind: .pdf, pdfData: sourceData, evidence: evidence)
        }
        let objects = pdf.dataObjects
        if objects.isEmpty {
            // A payload without `dataObjects` describes only a container with one unsigned PDF.
            guard pdf.asicDataObjectCount == 1, !pdf.asicDataObjectSigned else {
                throw ElectronicOriginalError.malformedEvidence
            }
            guard let entry = pdf.asicDataObjectName,
                  let data = ASiCEContainerVerifier.readEntries(sourceData)?.first(where: { $0.name == entry })?.data else {
                throw ElectronicOriginalError.containerWithoutPDF
            }
            return try makeSingle(sourceName: sourceName, kind: .asicE(entryName: entry), pdfData: data,
                                  evidence: evidence)
        }
        if objects.count == 1, let only = objects.first, !pdf.asicDataObjectSigned,
           isUnsignedPDF(only, tree: evidence.tree) {
            guard !Set(only.coveredBy).isDisjoint(with: evidence.tree.signatures.map(\.id)) || evidence.tree.signatures.isEmpty else {
                throw ElectronicOriginalError.uncoveredDataObject(name: displayName(only.name))
            }
            let data = try bytes(of: only, in: try entries(sourceData))
            return try makeSingle(sourceName: sourceName, kind: .asicE(entryName: only.name), pdfData: data,
                                  evidence: evidence)
        }
        return try makeMultiple(sourceName: sourceName, sourceData: sourceData, facts: pdf, evidence: evidence)
    }

    /// A signed PDF, or a container with one unsigned PDF: today's path, unchanged.
    private static func makeSingle(sourceName: String, kind: Kind, pdfData: Data,
                                   evidence: ConversionEvidence) throws -> ElectronicOriginal {
        guard let pdf = evidence.pdf else { throw ElectronicOriginalError.notPDFOrContainer }
        let sourceData = pdfData
        guard !evidence.tree.signatures.isEmpty else { throw ElectronicOriginalError.unsigned }
        guard evidence.tree.signatures.count <= maximumAuthorizations else {
            throw ElectronicOriginalError.tooManyAuthorizations(evidence.tree.signatures.count)
        }
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
        case .pdf, .asicEMultiple:
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
            return authorization(signature, facts: facts, documentNames: [document],
                                 validationTime: evidence.validationTime, fileEntryName: nil)
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

    /// A container with several files, or with one that is not an unsigned PDF (§ 7.2 of the
    /// multi-file design): every file is refused or accepted by name before any document is built.
    private static func makeMultiple(sourceName: String, sourceData: Data, facts: ConversionEvidence.PDFFacts,
                                     evidence: ConversionEvidence) throws -> ElectronicOriginal {
        let objects = facts.dataObjects
        let containerSignatures = evidence.tree.signatures
        guard !containerSignatures.isEmpty else { throw ElectronicOriginalError.unsigned }
        let containerIDs = Set(containerSignatures.map(\.id))
        let names = displayNames(objects.map(\.name))

        // Refusals, by file, in container order.
        var nestedPairs: [[(signature: DocumentSignatureInfo, facts: ConversionEvidence.Signature)]] = []
        for (index, object) in objects.enumerated() {
            let name = names[index]
            switch object.problem {
            case nil: break
            case "NESTED_UNREADABLE": throw ElectronicOriginalError.nestedSignaturesUnreadable(name: name)
            default: throw ElectronicOriginalError.unreadableDataObject(name: name)
            }
            guard object.kind != .other else { throw ElectronicOriginalError.unsupportedDataObject(name: name) }
            guard !containerIDs.isDisjoint(with: object.coveredBy) else {
                throw ElectronicOriginalError.uncoveredDataObject(name: name)
            }
            nestedPairs.append(try nestedSignatures(of: object, name: name, tree: evidence.tree,
                                                    onlySignedPDF: objects.count == 1 && facts.asicDataObjectSigned))
        }
        let authorizationCount = containerSignatures.count + nestedPairs.reduce(0) { $0 + $1.count }
        guard authorizationCount <= maximumAuthorizations else {
            throw ElectronicOriginalError.tooManyAuthorizations(authorizationCount)
        }

        // Signed revision lengths per file; the whole file is one more document when it is longer.
        var lengthsByFile: [[Int]] = []
        for (index, object) in objects.enumerated() {
            var lengths: [Int] = []
            for pair in nestedPairs[index] {
                guard let length = pair.facts.signedRevisionLength, length > 0, length <= object.size else {
                    throw ElectronicOriginalError.malformedEvidence
                }
                if !lengths.contains(length) { lengths.append(length) }
            }
            lengths.sort()
            if lengths.last != object.size { lengths.append(object.size) }
            lengthsByFile.append(lengths)
        }
        let documentCount = lengthsByFile.reduce(0) { $0 + $1.count }
        guard documentCount <= maximumDocuments else { throw ElectronicOriginalError.tooManyDocuments(documentCount) }

        let entries = try entries(sourceData)
        var files: [File] = []
        var documents: [Document] = []
        var nestedAuthorizations: [Authorization] = []
        for (index, object) in objects.enumerated() {
            let data = try bytes(of: object, in: entries)
            let name = names[index]
            let lengths = lengthsByFile[index]
            let format: (item: ZakoCodelistItem, other: String?)
            switch object.kind {
            case .png: format = (E2ECodelists.pngFormat, nil)
            case .jpeg: format = (E2ECodelists.otherFormat, E2ECodelists.jpegFormatOther)
            default: format = (object.pdf ?? object.nested?.pdf).map(documentFormat) ?? (E2ECodelists.pdfFormat, nil)
            }
            let stem = (name as NSString).deletingPathExtension
            let fileDocuments = lengths.enumerated().map { position, length in
                Document(name: lengths.count == 1 ? name : "\(stem)-\(position + 1)", format: format.item,
                         formatOther: format.other, sha256: Data(SHA256.hash(data: data.prefix(length))),
                         fileEntryName: object.name)
            }
            documents += fileDocuments
            for pair in nestedPairs[index] {
                guard let nested = object.nested, let length = pair.facts.signedRevisionLength,
                      let position = lengths.firstIndex(of: length) else {
                    throw ElectronicOriginalError.malformedEvidence
                }
                nestedAuthorizations.append(authorization(pair.signature, facts: pair.facts,
                                                          documentNames: [fileDocuments[position].name],
                                                          validationTime: nested.validationTime,
                                                          fileEntryName: object.name))
            }
            files.append(File(entryName: object.name, displayName: name, kind: object.kind, data: data,
                              documentNames: fileDocuments.map(\.name), embeddedFileNames: object.embeddedFileNames,
                              changedAfterSignature: object.nested?.pdf.changesAfterLastSignature
                                  ?? object.pdf?.changesAfterLastSignature ?? []))
        }

        // A container signature authorizes the whole file, so it names only the whole file's document.
        let containerAuthorizations = try containerSignatures.map { signature -> Authorization in
            let covered = files.indices.filter { objects[$0].coveredBy.contains(signature.id) }
                .compactMap { files[$0].documentNames.last }
            guard let facts = evidence.signature(id: signature.id), !covered.isEmpty else {
                throw ElectronicOriginalError.malformedEvidence
            }
            return authorization(signature, facts: facts, documentNames: covered,
                                 validationTime: evidence.validationTime, fileEntryName: nil)
        }

        let reason = files.count == 1
            ? "Súbor kontajnera sa prevedie na nový dokument vo formáte PDF/A"
            : "Súbory kontajnera sa spoja do jedného nového dokumentu vo formáte PDF/A"
        var original = ElectronicOriginal(
            sourceName: sourceName, kind: .asicEMultiple,
            pdfData: files.first { $0.kind == .pdf }?.data ?? Data(), documents: documents,
            authorizations: containerAuthorizations + nestedAuthorizations, plan: .convert(reason: reason),
            evidence: evidence)
        original.files = files
        return original
    }

    /// The same original with its files, and their documents, in the order the advocate chose.
    /// Authorizations keep their order. `entryNames` must name every file once.
    public func reordered(entryNames: [String]) -> ElectronicOriginal {
        precondition(entryNames.count == files.count && Set(entryNames) == Set(files.map(\.entryName)),
                     "reordered(entryNames:) needs every file of the original once")
        var copy = self
        copy.files = entryNames.compactMap { name in files.first { $0.entryName == name } }
        copy.documents = entryNames.flatMap { name in documents.filter { $0.fileEntryName == name } }
        return copy
    }

    /// The only data object stays on today's path when it is a PDF without signatures of its own.
    /// The engine's tree lists every PDF data object as `.signed` with its nested tree, empty when
    /// the PDF has no signatures.
    private static func isUnsignedPDF(_ object: ConversionEvidence.DataObject, tree: SignatureTree) -> Bool {
        guard object.kind == .pdf, object.problem == nil, object.nested == nil else { return false }
        switch tree.documents.first(where: { $0.name == object.name })?.content {
        case nil, .plain?: return true
        case .signed(_, let nested)?: return nested.signatures.isEmpty && nested.documents.isEmpty
        case .skipped?, .failed?: return false
        }
    }

    /// A PDF's own PAdES signatures, each paired with its tree entry (state, signer, time,
    /// qualification) by id. Fails closed: signatures the tree shows without evidence, or
    /// evidence without the tree's verdict, refuse the conversion.
    private static func nestedSignatures(of object: ConversionEvidence.DataObject, name: String, tree: SignatureTree,
                                         onlySignedPDF: Bool) throws
        -> [(signature: DocumentSignatureInfo, facts: ConversionEvidence.Signature)] {
        guard object.kind == .pdf else { return [] }
        let refused = ElectronicOriginalError.nestedSignaturesUnreadable(name: name)
        let treeSignatures: [DocumentSignatureInfo]
        switch tree.documents.first(where: { $0.name == object.name })?.content {
        case nil, .plain?: treeSignatures = []
        case .signed(_, let nested)?: treeSignatures = nested.signatures
        case .skipped?, .failed?: throw refused
        }
        let facts = object.nested?.signatures ?? []
        if facts.isEmpty {
            guard treeSignatures.isEmpty, !onlySignedPDF else { throw refused }
            return []
        }
        guard treeSignatures.count == facts.count else { throw refused }
        return try treeSignatures.map { signature in
            guard let fact = facts.first(where: { $0.id == signature.id }) else { throw refused }
            return (signature, fact)
        }
    }

    /// Entry names reduced to their file name; entries sharing one keep their full path.
    static func displayNames(_ entries: [String]) -> [String] {
        let short = entries.map { ($0 as NSString).lastPathComponent }
        return entries.indices.map { index in
            let shared = short.filter { $0 == short[index] }.count > 1
            return String((shared ? entries[index] : short[index]).prefix(255))
        }
    }

    private static func entries(_ container: Data) throws -> [String: Data] {
        guard let entries = ASiCEContainerVerifier.readEntries(container) else {
            throw ElectronicOriginalError.malformedEvidence
        }
        return Dictionary(entries.map { ($0.name, $0.data) }, uniquingKeysWith: { first, _ in first })
    }

    /// The data object's bytes, which must be the very bytes the engine examined.
    private static func bytes(of object: ConversionEvidence.DataObject, in entries: [String: Data]) throws -> Data {
        guard let data = entries[object.name] else {
            throw ElectronicOriginalError.unreadableDataObject(name: displayName(object.name))
        }
        guard data.count == object.size, Data(SHA256.hash(data: data)) == object.sha256 else {
            throw ElectronicOriginalError.malformedEvidence
        }
        return data
    }

    static func authorization(_ signature: DocumentSignatureInfo, facts: ConversionEvidence.Signature,
                              documentNames: [String], validationTime: Date,
                              fileEntryName: String?) -> Authorization {
        let type = authorizationType(qualification: signature.certificateQualification, qcType: facts.qcType)
        return Authorization(
            signatureID: signature.id,
            signerName: signature.signerDisplayName,
            type: type.item, typeOther: type.other,
            documentNames: documentNames,
            state: state(signature.state),
            reason: signature.state == .valid ? nil : signature.detail,
            signingTime: signature.signingTime,
            validationTime: validationTime,
            location: facts.productionPlace.flatMap { $0.isEmpty ? nil : String($0.prefix(255)) } ?? "Neuvedené",
            personID: facts.signerSerialNumber ?? facts.signerCommonName ?? signature.signerDisplayName,
            mandant: facts.mandants.isEmpty ? nil : String(facts.mandants.joined(separator: "; ").prefix(255)),
            mandate: facts.mandate.map { String($0.prefix(255)) },
            timestamp: timestamp(facts.timestamps, validationTime: validationTime),
            qualifiedCertificate: facts.qcCompliance,
            signatureValue: facts.signatureValue,
            slimReport: facts.slimReport,
            trustedListUnavailable: facts.trustedListUnavailable,
            fileEntryName: fileEntryName)
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

    public static func changeLabel(_ change: String) -> String {
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
