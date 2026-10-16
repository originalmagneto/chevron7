// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

public struct ZakoCodelistItem: Codable, Hashable, Sendable {
    public var code: String
    public var skName: String

    public init(code: String, skName: String) {
        self.code = code
        self.skName = skName
    }
}

public enum ZakoCodelists {
    public static let paperSize = 12
    public static let securityElementDescription = 15
    public static let securityElementLocation = 11
    public static let fingerprintMethod = 14
    public static let newDocumentFormat = 53
    public static let identifierType = 4001

    public static let sha256Item = ZakoCodelistItem(code: "SHA-256", skName: "SHA-256")
    public static let pdfa2FormatItem = ZakoCodelistItem(code: "PDFA2", skName: "PDF/A-2")
    public static let icoIdentifierItem = ZakoCodelistItem(
        code: "7",
        skName: "IČO (Identifikačné číslo organizácie)")

    public static func paperSizeItem(for classification: PaperClassification) -> ZakoCodelistItem? {
        switch classification {
        case .a4Portrait, .a4Landscape:
            return ZakoCodelistItem(code: "A4", skName: "Formát papiera A4")
        case .a3Portrait, .a3Landscape:
            return ZakoCodelistItem(code: "A3", skName: "Formát papiera A3")
        case .letterPortrait, .letterLandscape:
            return ZakoCodelistItem(code: "Letter", skName: "Formát papiera Letter")
        case .unknown:
            return nil
        }
    }

    public static func identifierURI(ico: String) -> String {
        let cleaned = ico.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        return "ico://sk/\(cleaned)"
    }

    public static func conversionRecordURI(evidenceNumber: String) -> String {
        let trimmed = evidenceNumber.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return "https://data.gov.sk/id/egov/conversion-record/\(trimmed)"
    }

    /// Codelist 11 (security element location) in the order of the official form.
    public static let locationItems: [ZakoCodelistItem] = [
        ZakoCodelistItem(code: "Down", skName: "Dole"),
        ZakoCodelistItem(code: "Up", skName: "Hore"),
        ZakoCodelistItem(code: "Down edge", skName: "Dolný okraj"),
        ZakoCodelistItem(code: "Up edge", skName: "Horný okraj"),
        ZakoCodelistItem(code: "Left edge", skName: "Ľavý okraj"),
        ZakoCodelistItem(code: "Right edge", skName: "Pravý okraj"),
        ZakoCodelistItem(code: "Mid", skName: "Uprostred"),
        ZakoCodelistItem(code: "Left", skName: "Vľavo"),
        ZakoCodelistItem(code: "Left down", skName: "Vľavo dole"),
        ZakoCodelistItem(code: "Left up", skName: "Vľavo hore"),
        ZakoCodelistItem(code: "Right", skName: "Vpravo"),
        ZakoCodelistItem(code: "Right down", skName: "Vpravo dole"),
        ZakoCodelistItem(code: "Right up", skName: "Vpravo hore"),
    ]

    public static func locationItem(code: String) -> ZakoCodelistItem? {
        locationItems.first { $0.code == code }
    }

    /// Codelist 12 item for sizes outside A1 to C7; `PaperSizeOther` names the size.
    public static let otherPaperSizeItem = ZakoCodelistItem(code: "Iny", skName: "Iný")

    public static func clausePaperSize(for classification: PaperClassification) -> (item: ZakoCodelistItem, other: String?) {
        switch classification {
        case .letterPortrait, .letterLandscape: return (otherPaperSizeItem, "Letter")
        case .unknown: return (otherPaperSizeItem, "neurčený")
        default: return (paperSizeItem(for: classification)!, nil)
        }
    }

    /// Codelist 15 items whose meaning is carried by `OriginalDocumentSecurityElementsDescriptionOther`.
    public static let descriptionCodesNeedingOtherText: Set<String> = [
        "iný manuálny vstup", "trvale spojenie dokumentu - iné"
    ]

    // MARK: Record 1.2 (from 1. 1. 2027)
    //
    // Record 1.2 requires an `https://` CodelistCode. The two codelist URIs below are the ones
    // the form's own schema documentation names; MetaIS lists the same codelists under
    // `https://data.gov.sk/set/codelist/...` and gives no URI for CL004001, so the identifier
    // type uses that form. Items were read from MetaIS on 2026-10-16. If test EZZK refuses one
    // of them, this is the only place to change.

    /// CL009009, "Formát novovzniknutého elektronického dokumentu zaručenou konverziou".
    public static let record12NewDocumentFormatCode = "https://metais.vicepremier.gov.sk/set/codelist/CL009009"
    /// CL009009 item 2 (1 PDF/A-1, 2 PDF/A-2, 3 PDF/A-3, 4 PNG).
    public static let record12PDFA2Item = ZakoCodelistItem(code: "2", skName: "PDF/A-2")
    /// CL009005, "Hašovacia funkcia".
    public static let record12FingerprintMethodCode = "https://metais.vicepremier.gov.sk/set/codelist/CL009005"
    public static let record12SHA256Item = ZakoCodelistItem(code: "2.16.840.1.101.3.4.2.1", skName: "sha-256")
    /// CL004001, identifier type; item 7 is IČO.
    public static let record12IdentifierTypeCode = "https://data.gov.sk/set/codelist/CL004001"

    /// The record 1.2 security element description: the clause codelist 15 code, which is a 1.2
    /// enum value word for word except the permanent binding, spelled differently in 1.2.
    public static func record12SecurityElementDescription(_ item: ZakoCodelistItem) -> String {
        item.code == "trvale spojenie dokumentu - iné" ? "trvalé pevné spojenie - iné" : item.code
    }

    /// The record 1.2 location enum is the codelist 11 Slovak name in lower case.
    public static func record12Location(_ item: ZakoCodelistItem) -> String {
        item.skName.lowercased(with: Locale(identifier: "sk_SK"))
    }

    /// Record 1.2 paper sizes are A1 to C7 or `Iný` (with `PaperSizeOther`).
    public static let record12PaperSizes: Set<String> = [
        "A1", "A2", "A3", "A4", "A5", "A6", "B3", "B4", "B5", "B6", "B7", "C3", "C4", "C5", "C6", "C7",
    ]

    /// Person identifier the clause schema accepts (`https://data.gov.sk/id/legal-subject/\d{8,12}`).
    public static func legalSubjectURI(ico: String) -> String? {
        let cleaned = ico.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...12).contains(cleaned.count), cleaned.allSatisfy(\.isASCII), cleaned.allSatisfy(\.isNumber) else {
            return nil
        }
        return "https://data.gov.sk/id/legal-subject/\(cleaned)"
    }
}
