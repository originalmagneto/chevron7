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
            xml = ConversionRecordE2E12Renderer().render(model)
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
        case notAnE2ERecordForm

        public var errorDescription: String? {
            switch self {
            case .unmappableAuthorization(let signer):
                return "Kvalifikáciu podpisu \(signer) sa nepodarilo určiť. Podľa postupu od 1. 1. 2027 ho nemožno zapísať do záznamu. Skúste overenie znova."
            case .unmappableOriginalDocumentFormat(let name):
                return "Formát dokumentu \(name) nemožno zapísať do záznamu podľa postupu od 1. 1. 2027."
            case .unmappableNewDocumentFormat:
                return "Formát nového dokumentu nemožno zapísať do záznamu podľa postupu od 1. 1. 2027."
            case .notAnE2ERecordForm:
                return "Tento formulár nie je záznamom o zaručenej konverzii elektronického dokumentu."
            }
        }
    }
}
