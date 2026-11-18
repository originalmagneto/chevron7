// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

public struct AdvocateProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var fullName: String
    public var position: String
    public var registrationNumber: String
    public var ico: String
    public var officeName: String
    public var officeAddress: String
    public var isLegalEntity: Bool

    public init(id: UUID = UUID(), fullName: String = "", position: String = "advokát",
                registrationNumber: String = "", ico: String = "",
                officeName: String = "", officeAddress: String = "",
                isLegalEntity: Bool = false) {
        self.id = id
        self.fullName = fullName
        self.position = position
        self.registrationNumber = registrationNumber
        self.ico = ico
        self.officeName = officeName
        self.officeAddress = officeAddress
        self.isLegalEntity = isLegalEntity
    }

    public static let empty = AdvocateProfile()

    /// Item 6 of the clause preview: the person, their function once (a name typed as
    /// "Mgr. X, advokát" already carries it) and, when set, the office the clause names
    /// as the legal subject, which is what EZZK compares with the account.
    public var clausePreviewLine: String {
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownName = name.isEmpty ? "JUDr. Meno Priezvisko" : name
        let function = position.trimmingCharacters(in: .whitespacesAndNewlines)
        let sak = registrationNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [shownName]
        if !function.isEmpty,
           !shownName.lowercased().hasSuffix(", " + function.lowercased()) {
            parts.append(function)
        }
        parts.append("ev. č. SAK: " + (sak.isEmpty ? "XXXX" : sak))
        var line = parts.joined(separator: ", ")
        let office = officeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !office.isEmpty, office.lowercased() != name.lowercased() {
            line += " (" + office + ")"
        }
        return line
    }
}

public struct AttestationData: Codable, Hashable, Sendable {
    public var originalDocumentOrder: Int
    public var originalDocumentName: String
    public var originalDocumentTypeCode: String
    public var originalDocumentTypeLabel: String
    /// E→E container with several files: the "Druh dokumentu" of each file by its entry name;
    /// a file without an entry takes `originalDocumentTypeLabel`.
    public var originalDocumentTypeLabels: [String: String]
    public var noSecurityElementsConfirmed: Bool
    public var originConfirmed: Bool
    public var numberOfSheets: Int
    public var sheetCountingMethod: SheetCountingMethod
    public var nonEmptyPageCount: Int
    public var paperSizeBreakdown: [PaperSizeGroup]

    public var newDocumentName: String
    public var newDocumentFormatLabel: String

    public var conversionExecutionDateTime: Date
    public var evidenceNumber: String?
    /// EZZK server time when the evidence number was obtained. Nil for a number typed by hand.
    public var evidenceNumberAllocatedAt: Date?
    /// EZZK mode the evidence number was obtained in. Nil for a number typed by hand.
    public var evidenceNumberMode: AppSettings.EZZKMode?

    public var performingPerson: AdvocateProfile
    public var usedDeviceDescription: String

    public struct PaperSizeGroup: Codable, Hashable, Sendable {
        public var sizeClass: PaperClassification
        public var sheets: Int
        public init(sizeClass: PaperClassification, sheets: Int) {
            self.sizeClass = sizeClass
            self.sheets = sheets
        }
    }

    private enum CodingKeys: String, CodingKey {
        case originalDocumentOrder, originalDocumentName, originalDocumentTypeCode,
             originalDocumentTypeLabel, originalDocumentTypeLabels, originConfirmed, noSecurityElementsConfirmed, numberOfSheets,
             sheetCountingMethod, nonEmptyPageCount, paperSizeBreakdown,
             newDocumentName, newDocumentFormatLabel, conversionExecutionDateTime,
             evidenceNumber, evidenceNumberAllocatedAt, evidenceNumberMode, performingPerson,
             usedDeviceDescription
    }

    public init(originalDocumentOrder: Int = 1,
                originalDocumentName: String = "",
                originalDocumentTypeCode: String = "",
                originalDocumentTypeLabel: String = "",
                originalDocumentTypeLabels: [String: String] = [:],
                originConfirmed: Bool = false,
                noSecurityElementsConfirmed: Bool = false,
                numberOfSheets: Int = 0,
                sheetCountingMethod: SheetCountingMethod = .duplexEstimate,
                nonEmptyPageCount: Int = 0,
                paperSizeBreakdown: [PaperSizeGroup] = [],
                newDocumentName: String = "",
                newDocumentFormatLabel: String = "PDF",
                conversionExecutionDateTime: Date = Date(),
                evidenceNumber: String? = nil,
                evidenceNumberAllocatedAt: Date? = nil,
                evidenceNumberMode: AppSettings.EZZKMode? = nil,
                performingPerson: AdvocateProfile = .empty,
                usedDeviceDescription: String = "") {
        self.originalDocumentOrder = originalDocumentOrder
        self.originalDocumentName = originalDocumentName
        self.originalDocumentTypeCode = originalDocumentTypeCode
        self.originalDocumentTypeLabel = originalDocumentTypeLabel
        self.originalDocumentTypeLabels = originalDocumentTypeLabels
        self.noSecurityElementsConfirmed = noSecurityElementsConfirmed
        self.originConfirmed = originConfirmed
        self.numberOfSheets = numberOfSheets
        self.sheetCountingMethod = sheetCountingMethod
        self.nonEmptyPageCount = nonEmptyPageCount
        self.paperSizeBreakdown = paperSizeBreakdown
        self.newDocumentName = newDocumentName
        self.newDocumentFormatLabel = newDocumentFormatLabel
        self.conversionExecutionDateTime = conversionExecutionDateTime
        self.evidenceNumber = evidenceNumber
        self.evidenceNumberAllocatedAt = evidenceNumberAllocatedAt
        self.evidenceNumberMode = evidenceNumberMode
        self.performingPerson = performingPerson
        self.usedDeviceDescription = usedDeviceDescription
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originalDocumentOrder = try container.decode(Int.self, forKey: .originalDocumentOrder)
        originalDocumentName = try container.decode(String.self, forKey: .originalDocumentName)
        originalDocumentTypeCode = try container.decode(String.self, forKey: .originalDocumentTypeCode)
        originalDocumentTypeLabel = try container.decode(String.self, forKey: .originalDocumentTypeLabel)
        originalDocumentTypeLabels = try container.decodeIfPresent([String: String].self, forKey: .originalDocumentTypeLabels) ?? [:]
        noSecurityElementsConfirmed = try container.decodeIfPresent(Bool.self, forKey: .noSecurityElementsConfirmed) ?? false
        originConfirmed = try container.decodeIfPresent(Bool.self, forKey: .originConfirmed) ?? false
        numberOfSheets = try container.decode(Int.self, forKey: .numberOfSheets)
        sheetCountingMethod = try container.decode(SheetCountingMethod.self, forKey: .sheetCountingMethod)
        nonEmptyPageCount = try container.decode(Int.self, forKey: .nonEmptyPageCount)
        paperSizeBreakdown = try container.decode([PaperSizeGroup].self, forKey: .paperSizeBreakdown)
        newDocumentName = try container.decode(String.self, forKey: .newDocumentName)
        newDocumentFormatLabel = try container.decode(String.self, forKey: .newDocumentFormatLabel)
        conversionExecutionDateTime = try container.decode(Date.self, forKey: .conversionExecutionDateTime)
        evidenceNumber = try container.decodeIfPresent(String.self, forKey: .evidenceNumber)
        evidenceNumberAllocatedAt = try container.decodeIfPresent(Date.self, forKey: .evidenceNumberAllocatedAt)
        evidenceNumberMode = try container.decodeIfPresent(AppSettings.EZZKMode.self, forKey: .evidenceNumberMode)
        performingPerson = try container.decode(AdvocateProfile.self, forKey: .performingPerson)
        usedDeviceDescription = try container.decode(String.self, forKey: .usedDeviceDescription)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalDocumentOrder, forKey: .originalDocumentOrder)
        try container.encode(originalDocumentName, forKey: .originalDocumentName)
        try container.encode(originalDocumentTypeCode, forKey: .originalDocumentTypeCode)
        try container.encode(originalDocumentTypeLabel, forKey: .originalDocumentTypeLabel)
        try container.encode(originalDocumentTypeLabels, forKey: .originalDocumentTypeLabels)
        try container.encode(noSecurityElementsConfirmed, forKey: .noSecurityElementsConfirmed)
        try container.encode(originConfirmed, forKey: .originConfirmed)
        try container.encode(numberOfSheets, forKey: .numberOfSheets)
        try container.encode(sheetCountingMethod, forKey: .sheetCountingMethod)
        try container.encode(nonEmptyPageCount, forKey: .nonEmptyPageCount)
        try container.encode(paperSizeBreakdown, forKey: .paperSizeBreakdown)
        try container.encode(newDocumentName, forKey: .newDocumentName)
        try container.encode(newDocumentFormatLabel, forKey: .newDocumentFormatLabel)
        try container.encode(conversionExecutionDateTime, forKey: .conversionExecutionDateTime)
        try container.encodeIfPresent(evidenceNumber, forKey: .evidenceNumber)
        try container.encodeIfPresent(evidenceNumberAllocatedAt, forKey: .evidenceNumberAllocatedAt)
        try container.encodeIfPresent(evidenceNumberMode, forKey: .evidenceNumberMode)
        try container.encode(performingPerson, forKey: .performingPerson)
        try container.encode(usedDeviceDescription, forKey: .usedDeviceDescription)
    }
}

public enum AttestationValidationError: LocalizedError, Equatable, Sendable {
    case originNotConfirmed
    case missingOriginalName
    case missingNewDocumentName
    case missingPerformingPerson
    case missingRegistrationNumber
    case invalidSheetCount
    case noSecurityElementsConfirmed
    case securityElementDescriptionRequired
    case physicalElementLocationRequired
    case physicalElementOutputPageRequired
    case securityElementsNeedReview(count: Int)
    case unreviewedNonEmptyPages(pages: [Int])
    case missingEvidenceNumber
    case inputSignatureVerificationRequired(state: InputSignatureInspectionResult.State)
    case timestampBeforeConversionTime(conversionTime: Date, stampTime: Date)

    public var errorDescription: String? {
        switch self {
        case .originNotConfirmed:
            return "Potvrďte, že vstupný dokument je originál alebo úradne osvedčená kópia."
        case .missingOriginalName:
            return "Chýba názov pôvodného listinného dokumentu."
        case .missingNewDocumentName:
            return "Chýba názov novovzniknutého elektronického dokumentu."
        case .missingPerformingPerson:
            return "Chýbajú údaje osoby vykonávajúcej konverziu."
        case .missingRegistrationNumber:
            return "Chýba evidenčné číslo advokáta (SAK)."
        case .invalidSheetCount:
            return "Počet listov musí byť aspoň 1."
        case .securityElementDescriptionRequired:
            return "Doplňte vecný opis iného bezpečnostného prvku alebo spojenia."
        case .physicalElementLocationRequired:
            return "Vyberte umiestnenie prvku skontrolovaného na origináli zo zoznamu."
        case .physicalElementOutputPageRequired:
            return "Určite stranu zachytenia prvku v novom dokumente. Ak v PDF chýba, doplňte jeho sken."
        case .noSecurityElementsConfirmed:
            return "Potvrďte bezpečnostné prvky pôvodného dokumentu."
        case .securityElementsNeedReview(let count):
            return "Skontrolujte a potvrďte alebo odmietnite všetky navrhnuté bezpečnostné prvky (zostáva \(count))."
        case .unreviewedNonEmptyPages(let pages):
            let labels = pages.map { "str. \($0 + 1)" }.joined(separator: ", ")
            return "Skontrolujte každú neprázdnu stranu dokumentu: \(labels)."
        case .missingEvidenceNumber:
            return "Získajte evidenčné číslo záznamu z evidencie záznamov (EZZK)."
        case .inputSignatureVerificationRequired(let state):
            return "Autorizácia vyžaduje platné overenie vstupných podpisov (stav: \(state.rawValue))."
        case .timestampBeforeConversionTime(let c, let t):
            return "Časová pečiatka (\(t)) predchádza času konverzie (\(c)). Zápis by bol v EZZK zamietnutý."
        }
    }
}

public enum AttestationValidator {
    public static func validate(_ data: AttestationData,
                                securityElements: [SecurityElement],
                                qualifiedTimestampTime: Date?) -> [AttestationValidationError] {
        var errors: [AttestationValidationError] = []
        if !data.originConfirmed {
            errors.append(.originNotConfirmed)
        }
        if data.originalDocumentName.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(.missingOriginalName)
        }
        if data.newDocumentName.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(.missingNewDocumentName)
        }
        if data.performingPerson.fullName.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(.missingPerformingPerson)
        }
        if data.performingPerson.registrationNumber.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(.missingRegistrationNumber)
        }
        if data.numberOfSheets < 1 {
            errors.append(.invalidSheetCount)
        }
        if securityElements.isEmpty && !data.noSecurityElementsConfirmed {
            errors.append(.noSecurityElementsConfirmed)
        }
        for element in securityElements {
            if element.kind.requiresHumanDescription, element.verbalDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.securityElementDescriptionRequired) }
            if element.observation == .physicalOriginal {
                if ZakoCodelists.locationItem(code: element.originalLocation.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                    errors.append(.physicalElementLocationRequired)
                }
                if element.newDocumentPageIndex == nil || element.newDocumentPageIndex! < 0 { errors.append(.physicalElementOutputPageRequired) }
            }
        }
        if (data.evidenceNumber ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(.missingEvidenceNumber)
        }
        if let stamp = qualifiedTimestampTime, stamp < data.conversionExecutionDateTime.addingTimeInterval(-60) {
            errors.append(.timestampBeforeConversionTime(
                conversionTime: data.conversionExecutionDateTime, stampTime: stamp))
        }
        return errors
    }
}


