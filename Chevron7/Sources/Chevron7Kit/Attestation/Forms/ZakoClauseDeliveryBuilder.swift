// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

public struct ZakoClauseDelivery: Sendable {
    public let model: ConversionFormModel
    public let clauseXML: String
    public let clauseXDCF: Data
}

/// Turns the delivered PDF/A bytes and the ZaKo state into the validated clause XDC that is
/// signed beside the PDF. The fingerprint is taken over exactly the bytes the client receives.
public struct ZakoClauseDeliveryBuilder: Sendable {
    private let validator: FormSchemaValidator

    public init(validator: FormSchemaValidator = FormSchemaValidator()) {
        self.validator = validator
    }

    public func build(finalPDF: Data, attestation: AttestationData, securityElements: [SecurityElement],
                      originalNonEmptyPageIndices: [Int]?, usedDevice: String,
                      deliveredAsSinglePDF: Bool = false) throws -> ZakoClauseDelivery {
        let model = try ConversionFormModel.make(
            attestation: attestation,
            securityElements: securityElements,
            newDocumentSHA256Hex: AttestationClauseGenerator.sha256Hex(of: finalPDF),
            originalNonEmptyPageIndices: originalNonEmptyPageIndices,
            usedDevice: usedDevice,
            deliveredAsSinglePDF: deliveredAsSinglePDF)
        let xml = ConversionCertificateRenderer().render(model)
        try validator.validate(Data(xml.utf8), against: .clause_1_3)
        return ZakoClauseDelivery(model: model, clauseXML: xml,
                                  clauseXDCF: XMLDataContainerBuilder.build(formXML: xml, form: .clause_1_3))
    }
}
