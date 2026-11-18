// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Renders the conversion record 1.0 exactly in the shape of the record EZZK accepted on
/// 2026-08-24: plain strings where the record schema has `MandatoryStringType`, the plain
/// evidence number, and person data last.
public struct ConversionRecordRenderer: Sendable {
    public init() {}

    public func render(_ m: ConversionFormModel) -> String {
        var x = "<ConversionRecord xmlns=\"\(OfficialForm.record_1_0.namespace)\"><OriginalDocumentInfo>"
        x += element("OriginalDocumentName", m.originalDocumentName)
        x += element("OriginalDocumentOrder", String(m.originalDocumentOrder))
        x += element("OriginalDocumentType", m.originalDocumentType)
        x += element("OriginalDocumentNumberOfSheets", String(m.numberOfSheets))
        x += element("OriginalDocumentNonEmptyPageCount", String(m.nonEmptyPageCount))
        for size in m.paperSizes {
            x += "<OriginalDocumentPaperSize>"
            x += element("PaperSize", size.other ?? size.item.code)
            x += element("PaperSizeNumberOfSheets", String(size.sheets))
            x += "</OriginalDocumentPaperSize>"
        }
        for entry in m.securityElements {
            x += "<DocumentSecurityElementsDetails>"
            x += element("OriginalDocumentSecurityElementsDescription", entry.descriptionOther ?? entry.description.code)
            x += element("OriginalDocumentSecurityElementsPage", String(entry.originalPage))
            x += element("OriginalDocumentSecurityElementsSheet", String(entry.originalSheet))
            x += element("OriginalDocumentSecurityElementsLocation", entry.location.code)
            x += element("NewDocumentSecurityElementsPage", String(entry.newPage))
            x += "</DocumentSecurityElementsDetails>"
        }
        x += "</OriginalDocumentInfo><NewDocumentInfo>"
        x += element("NewDocumentName", m.newDocumentName)
        x += element("NewDocumentFormat", m.deliversPDFA3 ? ZakoCodelists.pdfa3FormatName : m.newDocumentFormat.skName)
        x += element("ElectronicFingerprintValue", m.fingerprintBase64)
        x += element("ElectronicFingerprintCalculationMethod", m.fingerprintMethod.code)
        x += "</NewDocumentInfo>"
        x += element("ConversionRecordEvidenceNumber", m.evidenceNumber)
        x += element("UsedDevice", m.usedDevice)
        x += element("ConversionExecutionDateTime", m.conversionTimeText)
        x += "<PersonPerformingConversion><PersonData><PhysicalPerson><PersonName>"
        x += element("GivenName", m.person.givenName)
        x += element("FamilyName", m.person.familyName)
        x += "</PersonName>"
        x += element("Position", m.person.position.isEmpty ? "advokát" : m.person.position)
        x += "</PhysicalPerson>"
        x += "<LegalSubject>\(element("Name", m.person.legalSubjectName))</LegalSubject>"
        if let uri = m.person.legalSubjectURI, Self.recordAcceptsIdentifier(uri) {
            x += "<ID><IdentifierType><Codelist><CodelistCode>\(ZakoCodelists.identifierType)</CodelistCode><CodelistItem>"
            x += "<ItemCode>\(AttestationClauseGenerator.escape(ZakoCodelists.icoIdentifierItem.code))</ItemCode>"
            x += "<ItemName Language=\"sk\">\(AttestationClauseGenerator.escape(ZakoCodelists.icoIdentifierItem.skName))</ItemName>"
            x += "</CodelistItem></Codelist></IdentifierType>"
            x += element("IdentifierValue", uri) + "</ID>"
        }
        x += "</PersonData></PersonPerformingConversion></ConversionRecord>"
        return x
    }

    /// Record 1.0 accepts 8 or 12 digits, the clause 8 to 12.
    static func recordAcceptsIdentifier(_ uri: String) -> Bool {
        let digits = uri.split(separator: "/").last.map(String.init) ?? ""
        return digits.count == 8 || digits.count == 12
    }

    private func element(_ name: String, _ value: String) -> String {
        "<\(name)>\(AttestationClauseGenerator.escape(value))</\(name)>"
    }
}
