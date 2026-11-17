// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Renders the conversion clause (osvedčovacia doložka) 1.3 in the element order of its
/// official schema. Codelist values carry code and Slovak name; the evidence number is a URI.
public struct ConversionCertificateRenderer: Sendable {
    public init() {}

    public func render(_ m: ConversionFormModel) -> String {
        var x = "<ConversionCertificateOfPaperToElectronicDocument xmlns=\"\(OfficialForm.clause_1_3.namespace)\">"
        x += "<OriginalDocumentInfo>"
        x += element("OriginalDocumentName", m.originalDocumentName)
        x += element("OriginalDocumentNumberOfSheets", String(m.numberOfSheets))
        x += element("OriginalDocumentNonEmptyPageCount", String(m.nonEmptyPageCount))
        for size in m.paperSizes {
            x += "<OriginalDocumentPaperSize>"
            x += "<PaperSize>\(codelist(ZakoCodelists.paperSize, size.item))</PaperSize>"
            if let other = size.other { x += element("PaperSizeOther", other) }
            x += element("PaperSizeNumberOfSheets", String(size.sheets))
            x += "</OriginalDocumentPaperSize>"
        }
        for entry in m.securityElements {
            x += "<DocumentSecurityElementsDetails>"
            x += "<OriginalDocumentSecurityElementsDescription>\(codelist(ZakoCodelists.securityElementDescription, entry.description))</OriginalDocumentSecurityElementsDescription>"
            if let other = entry.descriptionOther { x += element("OriginalDocumentSecurityElementsDescriptionOther", other) }
            x += element("OriginalDocumentSecurityElementsPage", String(entry.originalPage))
            x += element("OriginalDocumentSecurityElementsSheet", String(entry.originalSheet))
            x += "<OriginalDocumentSecurityElementsLocation>\(codelist(ZakoCodelists.securityElementLocation, entry.location))</OriginalDocumentSecurityElementsLocation>"
            x += element("NewDocumentSecurityElementsPage", String(entry.newPage))
            x += "</DocumentSecurityElementsDetails>"
        }
        x += "</OriginalDocumentInfo>"
        x += "<NewDocumentInfo>"
        x += element("NewDocumentName", m.newDocumentName)
        x += "<NewDocumentFormat>\(codelist(ZakoCodelists.newDocumentFormat, m.newDocumentFormat))</NewDocumentFormat>"
        if m.deliversPDFA3 { x += element("NewDocumentFormatOther", ZakoCodelists.pdfa3FormatName) }
        x += element("ElectronicFingerprintValue", m.fingerprintBase64)
        x += "<ElectronicFingerprintCalculationMethod>\(codelist(ZakoCodelists.fingerprintMethod, m.fingerprintMethod))</ElectronicFingerprintCalculationMethod>"
        x += "</NewDocumentInfo>"
        x += element("ConversionRecordEvidenceNumber", m.evidenceNumberURI)
        x += element("ConversionExecutionDateTime", m.conversionTimeText)
        x += "<PersonPerformingConversion><PersonData><PhysicalPerson><PersonName>"
        if !m.person.givenName.isEmpty { x += element("GivenName", m.person.givenName) }
        if !m.person.familyName.isEmpty { x += element("FamilyName", m.person.familyName) }
        x += "</PersonName>"
        if !m.person.position.isEmpty { x += element("Position", m.person.position) }
        x += "</PhysicalPerson>"
        x += "<LegalSubject>\(element("Name", m.person.legalSubjectName))</LegalSubject>"
        if let uri = m.person.legalSubjectURI {
            x += "<ID><IdentifierType>\(codelist(ZakoCodelists.identifierType, ZakoCodelists.icoIdentifierItem))</IdentifierType>"
            x += element("IdentifierValue", uri) + "</ID>"
        }
        x += "</PersonData></PersonPerformingConversion>"
        x += "</ConversionCertificateOfPaperToElectronicDocument>"
        return x
    }

    private func element(_ name: String, _ value: String) -> String {
        "<\(name)>\(AttestationClauseGenerator.escape(value))</\(name)>"
    }

    private func codelist(_ code: Int, _ item: ZakoCodelistItem) -> String {
        "<Codelist><CodelistCode>\(code)</CodelistCode><CodelistItem><ItemCode>\(AttestationClauseGenerator.escape(item.code))</ItemCode><ItemName Language=\"sk\">\(AttestationClauseGenerator.escape(item.skName))</ItemName></CodelistItem></Codelist>"
    }
}
