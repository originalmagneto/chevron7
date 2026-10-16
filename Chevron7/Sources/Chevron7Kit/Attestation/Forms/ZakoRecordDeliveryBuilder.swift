// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

public struct ZakoRecordDelivery: Sendable {
    public let recordXML: String
    public let recordXDCF: Data
    public let entryName: String
    public let containerName: String
}

/// Builds the record XDC EZZK receives, validated against the record schema before anything
/// is signed. File names follow the accepted record (`<number>.record.xml.xdcf`).
public struct ZakoRecordDeliveryBuilder: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case unusableEvidenceNumber
        public var errorDescription: String? {
            "Evidenčné číslo obsahuje znaky, ktoré sa nedajú použiť v názve súboru záznamu."
        }
    }

    private let validator: FormSchemaValidator

    public init(validator: FormSchemaValidator = FormSchemaValidator()) {
        self.validator = validator
    }

    /// `form` is the record form of the conversion's form pack: 1.0 until 1. 1. 2027, 1.2 after.
    public func build(model: ConversionFormModel, form: OfficialForm = .record_1_0) throws -> ZakoRecordDelivery {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !model.evidenceNumber.isEmpty,
              model.evidenceNumber.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else {
            throw Failure.unusableEvidenceNumber
        }
        let xml = form.identifier == OfficialForm.record_1_2.identifier
            ? ConversionRecord12Renderer().render(model)
            : ConversionRecordRenderer().render(model)
        try validator.validate(Data(xml.utf8), against: form)
        return ZakoRecordDelivery(recordXML: xml,
                                  recordXDCF: XMLDataContainerBuilder.build(formXML: xml, form: form),
                                  entryName: "\(model.evidenceNumber).record.xml.xdcf",
                                  containerName: Self.containerName(evidenceNumber: model.evidenceNumber))
    }

    /// The signed record's container name (`<number>.record.asice`), also used when the
    /// Register saves the stored record.
    public static func containerName(evidenceNumber: String) -> String {
        "\(evidenceNumber).record.asice"
    }
}
