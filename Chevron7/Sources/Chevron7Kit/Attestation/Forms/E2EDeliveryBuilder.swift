// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// The E→E clause and record, each validated against its official schema before anything is
/// signed and wrapped in an XMLDataContainer; file names follow the P→E scheme
/// (`<number>.xml.xdcf`, `<number>.record.xml.xdcf`, `<number>.record.asice`).
public struct E2EDeliveryBuilder: Sendable {
    public struct Clause: Sendable {
        public let xml: String
        public let xdcf: Data
    }

    private let validator: FormSchemaValidator

    public init(validator: FormSchemaValidator = FormSchemaValidator()) {
        self.validator = validator
    }

    public func clause(_ model: E2EFormModel) throws -> Clause {
        let xml = ConversionCertificateE2ERenderer().render(model)
        try validator.validate(Data(xml.utf8), against: .clauseE2E_1_3)
        return Clause(xml: xml, xdcf: XMLDataContainerBuilder.build(formXML: xml, form: .clauseE2E_1_3))
    }

    /// The record in today's form, 1.0.
    public func record(_ model: E2EFormModel) throws -> ZakoRecordDelivery {
        try record(model, form: .recordE2E_1_0)
    }

    /// The record in `form`: `.recordE2E_1_0` as before, `.recordE2E_1_2` for the order from
    /// 1. 1. 2027, which refuses an authorization or a new document format it cannot name.
    public func record(_ model: E2EFormModel, form: OfficialForm) throws -> ZakoRecordDelivery {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !model.evidenceNumber.isEmpty,
              model.evidenceNumber.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else {
            throw ZakoRecordDeliveryBuilder.Failure.unusableEvidenceNumber
        }
        let xml: String
        switch form {
        case .recordE2E_1_0:
            xml = ConversionRecordE2ERenderer().render(model)
        case .recordE2E_1_2:
            if let unmappable = ConversionRecordE2E12Renderer.unmappableAuthorizations(model.original).first {
                throw Failure.unmappableAuthorization(signer: unmappable.signerName)
            }
            if let document = model.original.documents.first(where: {
                ConversionRecordE2E12Renderer.originalDocumentFormat($0) == nil
            }) {
                throw Failure.unmappableOriginalDocumentFormat(name: document.name)
            }
            guard ConversionRecordE2E12Renderer.newDocumentFormat(model.newDocument) != nil else {
                throw Failure.unmappableNewDocumentFormat
            }
            // `ElectronicSignature` is obligatory for every signature and seal type the form names.
            if let unsigned = model.original.authorizations.first(where: { $0.signatureValue.isEmpty }) {
                throw Failure.missingSignatureValue(signer: unsigned.signerName)
            }
            // Every timestamp covering the originals is listed: one the record cannot tie to its
            // documents is refused, never left out.
            if model.original.contentTimestamps.contains(where: { !$0.isResolved }) {
                throw Failure.unresolvedContentTimestamp
            }
            // A content timestamp inside a PDF data object's own PAdES signature has no place the
            // renderer can tie it to yet: refused, never left out.
            if let object = model.original.evidence.pdf?.dataObjects.first(where: {
                !($0.nested?.contentTimestamps.isEmpty ?? true)
            }) {
                throw Failure.nestedContentTimestamp(name: ElectronicOriginal.displayName(object.name))
            }
            xml = try ConversionRecordE2E12Renderer().render(model)
        default:
            throw Failure.notAnE2ERecordForm
        }
        try validator.validate(Data(xml.utf8), against: form)
        return ZakoRecordDelivery(recordXML: xml,
                                  recordXDCF: XMLDataContainerBuilder.build(formXML: xml, form: form),
                                  entryName: "\(model.evidenceNumber).record.xml.xdcf",
                                  containerName: ZakoRecordDeliveryBuilder.containerName(evidenceNumber: model.evidenceNumber))
    }

    public enum Failure: LocalizedError, Equatable {
        /// The signature's qualification maps to no record 1.2 `AuthorizationType`.
        case unmappableAuthorization(signer: String)
        case unmappableOriginalDocumentFormat(name: String)
        case unmappableNewDocumentFormat
        /// A signature or seal whose value the engine did not give.
        case missingSignatureValue(signer: String)
        /// A content timestamp the record cannot tie to the original's documents.
        case unresolvedContentTimestamp
        /// A content timestamp inside the PAdES signature of a container's PDF.
        case nestedContentTimestamp(name: String)
        /// A timestamp the record 1.2 renderer has no name for (an internal inconsistency).
        case unnamedTimestamp
        case notAnE2ERecordForm

        public var errorDescription: String? {
            switch self {
            case .unmappableAuthorization(let signer):
                return "Kvalifikáciu podpisu \(signer) sa nepodarilo určiť. Podľa postupu od 1. 1. 2027 ho nemožno zapísať do záznamu. Skúste overenie znova."
            case .unmappableOriginalDocumentFormat(let name):
                return "Formát dokumentu \(name) nemožno zapísať do záznamu podľa postupu od 1. 1. 2027."
            case .unmappableNewDocumentFormat:
                return "Formát nového dokumentu nemožno zapísať do záznamu podľa postupu od 1. 1. 2027."
            case .missingSignatureValue(let signer):
                return "Hodnotu podpisu \(signer) sa nepodarilo prečítať. Podľa postupu od 1. 1. 2027 ju záznam musí obsahovať. Skúste overenie znova."
            case .unresolvedContentTimestamp:
                return "Časovú pečiatku údajov v kontajneri sa nepodarilo priradiť k jeho súborom. Podľa postupu od 1. 1. 2027 ju nemožno zapísať do záznamu. Skúste overenie znova."
            case .nestedContentTimestamp(let name):
                return "Súbor \(name) obsahuje časovú pečiatku údajov vo vnútri podpisu. Podľa postupu od 1. 1. 2027 ju zatiaľ nevieme zapísať do záznamu."
            case .unnamedTimestamp:
                return "Časovú pečiatku pôvodného dokumentu nemožno pomenovať v zázname podľa postupu od 1. 1. 2027. Pošlite nám prosím túto chybu."
            case .notAnE2ERecordForm:
                return "Tento formulár nie je záznamom o zaručenej konverzii elektronického dokumentu."
            }
        }
    }
}
