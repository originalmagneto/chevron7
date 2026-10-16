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

    public func record(_ model: E2EFormModel) throws -> ZakoRecordDelivery {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !model.evidenceNumber.isEmpty,
              model.evidenceNumber.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else {
            throw ZakoRecordDeliveryBuilder.Failure.unusableEvidenceNumber
        }
        let xml = ConversionRecordE2ERenderer().render(model)
        try validator.validate(Data(xml.utf8), against: .recordE2E_1_0)
        return ZakoRecordDelivery(recordXML: xml,
                                  recordXDCF: XMLDataContainerBuilder.build(formXML: xml, form: .recordE2E_1_0),
                                  entryName: "\(model.evidenceNumber).record.xml.xdcf",
                                  containerName: ZakoRecordDeliveryBuilder.containerName(evidenceNumber: model.evidenceNumber))
    }
}
