// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Every value the conversion clause and the conversion record carry, derived once from the
/// ZaKo state so the two documents cannot disagree.
public struct ConversionFormModel: Sendable, Equatable {
    public struct PaperSize: Sendable, Equatable {
        public var item: ZakoCodelistItem
        public var other: String?
        public var sheets: Int
    }

    public struct SecurityElementEntry: Sendable, Equatable {
        public var description: ZakoCodelistItem
        public var descriptionOther: String?
        public var originalPage: Int
        public var originalSheet: Int
        public var location: ZakoCodelistItem
        public var newPage: Int
    }

    public struct Person: Sendable, Equatable {
        public var givenName: String
        public var familyName: String
        public var position: String
        public var legalSubjectName: String
        public var legalSubjectURI: String?
    }

    public var originalDocumentName: String
    public var originalDocumentOrder: Int
    public var originalDocumentType: String
    public var numberOfSheets: Int
    public var nonEmptyPageCount: Int
    public var paperSizes: [PaperSize]
    public var securityElements: [SecurityElementEntry]
    public var newDocumentName: String
    /// Record 1.2 `NewDocumentType`: the converted document is the same kind of document.
    public var newDocumentType: String
    public var newDocumentFormat: ZakoCodelistItem
    /// SHA-256 of the delivered PDF/A in lower-case hex (record 1.2) and base64 (clause 1.3, record 1.0).
    public var fingerprintHex: String
    public var fingerprintBase64: String
    public var fingerprintMethod: ZakoCodelistItem
    public var evidenceNumber: String
    public var usedDevice: String
    public var conversionTime: Date
    public var person: Person

    public var conversionTimeText: String { Self.bratislavaDateTime(conversionTime) }
    public var evidenceNumberURI: String { ZakoCodelists.conversionRecordURI(evidenceNumber: evidenceNumber) }

    public static func make(attestation d: AttestationData,
                            securityElements: [SecurityElement],
                            newDocumentSHA256Hex: String,
                            originalNonEmptyPageIndices: [Int]?,
                            usedDevice: String) throws -> ConversionFormModel {
        guard newDocumentSHA256Hex.count == 64, newDocumentSHA256Hex.allSatisfy(\.isHexDigit) else {
            throw AttestationGenerationError.invalidFingerprint
        }
        let evidenceNumber = (d.evidenceNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidenceNumber.isEmpty else { throw AttestationGenerationError.missingEvidenceNumber }

        var paperSizes = d.paperSizeBreakdown.map { group -> PaperSize in
            let size = ZakoCodelists.clausePaperSize(for: group.sizeClass)
            return PaperSize(item: size.item, other: size.other, sheets: group.sheets)
        }
        if paperSizes.isEmpty {
            paperSizes = [PaperSize(item: ZakoCodelists.clausePaperSize(for: .a4Portrait).item,
                                    other: nil, sheets: max(d.numberOfSheets, 1))]
        }

        let entries = try securityElements.map { element -> SecurityElementEntry in
            let pages = try AttestationClauseGenerator.securityElementPages(
                element, originalNonEmptyPageIndices: originalNonEmptyPageIndices)
            let location: ZakoCodelistItem
            if element.observation == .physicalOriginal {
                guard let item = ZakoCodelists.locationItem(
                    code: element.originalLocation.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw AttestationGenerationError.invalidOriginalLocation
                }
                location = item
            } else {
                location = element.locationCodelist11Item
            }
            let description = element.kind.codelist15Item
            let other = ZakoCodelists.descriptionCodesNeedingOtherText.contains(description.code)
                ? String(element.descriptionForRecord.prefix(255)) : nil
            return SecurityElementEntry(description: description, descriptionOther: other,
                                        originalPage: pages.original,
                                        originalSheet: element.sheetNumber(sheetMethod: d.sheetCountingMethod),
                                        location: location, newPage: pages.new)
        }

        let names = nameParts(d.performingPerson.fullName)
        guard !names.given.isEmpty, !names.family.isEmpty else {
            throw AttestationGenerationError.incompletePersonName
        }
        let office = d.performingPerson.officeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeLabel = d.originalDocumentTypeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentType = typeLabel.isEmpty ? d.originalDocumentName : typeLabel
        return ConversionFormModel(
            originalDocumentName: d.originalDocumentName,
            originalDocumentOrder: d.originalDocumentOrder,
            originalDocumentType: documentType,
            numberOfSheets: d.numberOfSheets,
            nonEmptyPageCount: d.nonEmptyPageCount,
            paperSizes: paperSizes,
            securityElements: entries,
            newDocumentName: d.newDocumentName,
            newDocumentType: documentType,
            newDocumentFormat: ZakoCodelists.pdfa2FormatItem,
            fingerprintHex: newDocumentSHA256Hex.lowercased(),
            fingerprintBase64: AttestationClauseGenerator.fingerprintBase64(hex: newDocumentSHA256Hex),
            fingerprintMethod: ZakoCodelists.sha256Item,
            evidenceNumber: evidenceNumber,
            usedDevice: usedDevice,
            conversionTime: d.conversionExecutionDateTime,
            person: Person(givenName: names.given, familyName: names.family,
                           position: d.performingPerson.position.trimmingCharacters(in: .whitespacesAndNewlines),
                           legalSubjectName: office.isEmpty ? d.performingPerson.fullName : office,
                           legalSubjectURI: ZakoCodelists.legalSubjectURI(ico: d.performingPerson.ico)))
    }

    /// ISO 8601 with the Europe/Bratislava offset of that instant, as both forms require.
    public static func bratislavaDateTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        return formatter.string(from: date)
    }

    /// Given and family name without post-nominal suffixes (everything from the first comma on,
    /// e.g. ", PhD.") or academic titles (remaining tokens ending with a dot).
    static func nameParts(_ fullName: String) -> (given: String, family: String) {
        let withoutSuffix = fullName.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        let tokens = withoutSuffix.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasSuffix(".") }
        return (tokens.dropLast().joined(separator: " "), tokens.last ?? "")
    }
}
