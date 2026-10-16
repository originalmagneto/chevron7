// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Renders the conversion record 1.2 (`50349287.ConversionRecordOfPaperToElectronicDocument_2021.sk`),
/// the record form from 1. 1. 2027, in the element order of its official schema. It carries the
/// same values as record 1.0 where the forms agree; where 1.2 differs it uses its enums (paper
/// size, security element description and location), `https://` codelist codes, a hex
/// fingerprint, the evidence number as a URI and no `Position`.
public struct ConversionRecord12Renderer: Sendable {
    public init() {}

    public func render(_ m: ConversionFormModel) -> String {
        var x = "<ConversionRecord xmlns=\"\(OfficialForm.record_1_2.namespace)\"><OriginalDocumentInfo>"
        x += element("OriginalDocumentName", m.originalDocumentName)
        x += element("OriginalDocumentOrder", String(m.originalDocumentOrder))
        x += element("OriginalDocumentType", m.originalDocumentType)
        x += element("OriginalDocumentNumberOfSheets", String(m.numberOfSheets))
        x += element("OriginalDocumentNonEmptyPageCount", String(m.nonEmptyPageCount))
        for size in m.paperSizes {
            x += "<OriginalDocumentPaperSize>"
            if size.other == nil, ZakoCodelists.record12PaperSizes.contains(size.item.code) {
                x += element("PaperSize", size.item.code)
            } else {
                x += element("PaperSize", "Iný")
                x += element("PaperSizeOther", size.other ?? size.item.code)
            }
            x += element("PaperSizeNumberOfSheets", String(size.sheets))
            x += "</OriginalDocumentPaperSize>"
        }
        for entry in m.securityElements {
            x += "<DocumentSecurityElementsDetails>"
            x += element("OriginalDocumentSecurityElementsDescription",
                         ZakoCodelists.record12SecurityElementDescription(entry.description))
            if let other = entry.descriptionOther { x += element("OriginalDocumentSecurityElementsDescriptionOther", other) }
            x += element("OriginalDocumentSecurityElementsPage", String(entry.originalPage))
            x += element("OriginalDocumentSecurityElementsSheet", String(entry.originalSheet))
            x += element("OriginalDocumentSecurityElementsLocation", ZakoCodelists.record12Location(entry.location))
            x += "</DocumentSecurityElementsDetails>"
        }
        x += "</OriginalDocumentInfo><NewDocumentInfo>"
        x += element("NewDocumentName", m.newDocumentName)
        x += element("NewDocumentType", m.newDocumentType)
        x += element("ContentType", "application/pdf")
        x += "<NewDocumentFormat>\(codelist(ZakoCodelists.record12NewDocumentFormatCode, ZakoCodelists.record12PDFA2Item))</NewDocumentFormat>"
        x += element("ElectronicFingerprintValue", m.fingerprintHex)
        x += "<ElectronicFingerprintCalculationMethod>\(codelist(ZakoCodelists.record12FingerprintMethodCode, ZakoCodelists.record12SHA256Item))</ElectronicFingerprintCalculationMethod>"
        x += "</NewDocumentInfo>"
        x += element("ConversionRecordEvidenceNumber", m.evidenceNumberURI)
        x += element("UsedDevice", m.usedDevice)
        x += element("ConversionExecutionDateTime", m.conversionTimeText)
        x += "<PersonPerformingConversion><PersonData><PhysicalPerson><PersonName>"
        x += element("GivenName", m.person.givenName)
        x += element("FamilyName", m.person.familyName)
        x += "</PersonName></PhysicalPerson>"
        x += "<LegalSubject>\(element("Name", String(m.person.legalSubjectName.prefix(255))))</LegalSubject>"
        if let uri = m.person.legalSubjectURI, ConversionRecordRenderer.recordAcceptsIdentifier(uri) {
            x += "<ID><IdentifierType>\(codelist(ZakoCodelists.record12IdentifierTypeCode, ZakoCodelists.icoIdentifierItem))</IdentifierType>"
            x += element("IdentifierValue", uri) + "</ID>"
        }
        x += "</PersonData></PersonPerformingConversion></ConversionRecord>"
        return x
    }

    private func element(_ name: String, _ value: String) -> String {
        "<\(name)>\(AttestationClauseGenerator.escape(value))</\(name)>"
    }

    private func codelist(_ code: String, _ item: ZakoCodelistItem) -> String {
        "<Codelist><CodelistCode>\(AttestationClauseGenerator.escape(code))</CodelistCode><CodelistItem><ItemCode>\(AttestationClauseGenerator.escape(item.code))</ItemCode><ItemName Language=\"sk\">\(AttestationClauseGenerator.escape(item.skName))</ItemName></CodelistItem></Codelist>"
    }
}
