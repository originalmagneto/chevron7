// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

public enum FormPackVerificationState: String, Codable, Sendable {
    case unverified
    case verified
}

public enum FormPackAcceptanceState: String, Codable, Sendable {
    case unknown
    case accepted
    case rejected
}

public enum FormPackRenderer: String, Codable, Sendable {
    case legacySwift
    case xslt
}

public struct FormPackArtifactReference: Codable, Hashable, Sendable {
    public let resourceName: String?
    public let sha256Hex: String?

    public init(resourceName: String? = nil, sha256Hex: String? = nil) {
        self.resourceName = resourceName
        self.sha256Hex = sha256Hex
    }

    public var isPresent: Bool {
        resourceName != nil || sha256Hex != nil
    }
}

public enum FormPackSelectionPolicy: String, Codable, Sendable {
    case allowUnverifiedPilot
    case requireVerified
}

public enum FormPackError: LocalizedError, Equatable, Sendable {
    case noMatchingPack(direction: ConversionDirection, date: Date)
    case multipleMatchingPacks(direction: ConversionDirection, date: Date)
    case unverifiedPack(packID: String)
    case rejectedPack(packID: String)
    case unsupportedDirection(ConversionDirection)
    case unsupportedRenderer(FormPackRenderer)

    public var errorDescription: String? {
        switch self {
        case .noMatchingPack(let direction, let date):
            return "Pre smer \(direction.rawValue) neexistuje aktívny form pack k času \(date)."
        case .multipleMatchingPacks(let direction, let date):
            return "Pre smer \(direction.rawValue) existuje viac aktívnych form packov k času \(date)."
        case .unverifiedPack(let packID):
            return "Form pack \(packID) nemá overené autoritatívne artefakty."
        case .rejectedPack(let packID):
            return "Form pack \(packID) bol označený ako neprijatý."
        case .unsupportedDirection(let direction):
            return "Generátor doložky zatiaľ nepodporuje smer \(direction.rawValue)."
        case .unsupportedRenderer(let renderer):
            return "Generátor doložky zatiaľ nepodporuje renderer \(renderer.rawValue)."
        }
    }
}

/// Immutable provenance manifest for one version of the official conversion
/// record and its associated attestation clause.
public struct ConversionFormPack: Codable, Hashable, Identifiable, Sendable {
    public let manifestVersion: Int
    public let id: String
    public let direction: ConversionDirection
    public let recordVersion: String
    public let clauseVersion: String
    public let namespace: String
    public let eFormIdentifier: String
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let verificationState: FormPackVerificationState
    public let acceptanceState: FormPackAcceptanceState
    public let renderer: FormPackRenderer
    public let recordSchema: FormPackArtifactReference
    public let clauseSchema: FormPackArtifactReference
    public let stylesheet: FormPackArtifactReference
    public let codelists: FormPackArtifactReference
    public let outputProfile: ConversionOutputProfile
    public let newDocumentFormatItem: ZakoCodelistItem
    public let fingerprintMethodItem: ZakoCodelistItem

    public init(
        manifestVersion: Int = 1,
        id: String,
        direction: ConversionDirection,
        recordVersion: String,
        clauseVersion: String,
        namespace: String,
        eFormIdentifier: String,
        effectiveFrom: Date,
        effectiveUntil: Date? = nil,
        verificationState: FormPackVerificationState,
        acceptanceState: FormPackAcceptanceState,
        renderer: FormPackRenderer,
        recordSchema: FormPackArtifactReference = .init(),
        clauseSchema: FormPackArtifactReference = .init(),
        stylesheet: FormPackArtifactReference = .init(),
        codelists: FormPackArtifactReference = .init(),
        outputProfile: ConversionOutputProfile = .pilotPDFA2b,
        newDocumentFormatItem: ZakoCodelistItem,
        fingerprintMethodItem: ZakoCodelistItem
    ) {
        self.manifestVersion = manifestVersion
        self.id = id
        self.direction = direction
        self.recordVersion = recordVersion
        self.clauseVersion = clauseVersion
        self.namespace = namespace
        self.eFormIdentifier = eFormIdentifier
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.verificationState = verificationState
        self.acceptanceState = acceptanceState
        self.renderer = renderer
        self.recordSchema = recordSchema
        self.clauseSchema = clauseSchema
        self.stylesheet = stylesheet
        self.codelists = codelists
        self.outputProfile = outputProfile
        self.newDocumentFormatItem = newDocumentFormatItem
        self.fingerprintMethodItem = fingerprintMethodItem
    }

    public var isActiveForSelection: Bool {
        isActive(at: Date())
    }

    public func isActive(at date: Date) -> Bool {
        date >= effectiveFrom && (effectiveUntil == nil || date < effectiveUntil!)
    }

    public var isProductionEligible: Bool {
        verificationState == .verified && acceptanceState == .accepted
    }
}

public struct FormPackStamp: Codable, Hashable, Sendable {
    public let packID: String
    public let recordVersion: String
    public let clauseVersion: String
    public let namespace: String
    public let verificationState: FormPackVerificationState
    public let acceptanceState: FormPackAcceptanceState
    public let outputProfileID: String
    public let outputFormatCode: String

    public init(pack: ConversionFormPack) {
        self.packID = pack.id
        self.recordVersion = pack.recordVersion
        self.clauseVersion = pack.clauseVersion
        self.namespace = pack.namespace
        self.verificationState = pack.verificationState
        self.acceptanceState = pack.acceptanceState
        self.outputProfileID = pack.outputProfile.id
        self.outputFormatCode = pack.newDocumentFormatItem.code
    }
}

public struct FormPackRepository: Sendable {
    public let packs: [ConversionFormPack]

    public init(packs: [ConversionFormPack] = [FormPackRepository.currentLegacyUnverified,
                                               FormPackRepository.record12Unverified]) {
        self.packs = packs
    }

    public func pack(
        for direction: ConversionDirection,
        at date: Date = Date(),
        policy: FormPackSelectionPolicy = .allowUnverifiedPilot
    ) throws -> ConversionFormPack {
        let matches = packs.filter { $0.direction == direction && $0.isActive(at: date) }
        guard !matches.isEmpty else {
            throw FormPackError.noMatchingPack(direction: direction, date: date)
        }
        guard matches.count == 1, let selected = matches.first else {
            throw FormPackError.multipleMatchingPacks(direction: direction, date: date)
        }
        try validate(selected, policy: policy)
        return selected
    }

    public func pack(id: String) -> ConversionFormPack? {
        packs.first { $0.id == id }
    }

    public func validate(
        _ pack: ConversionFormPack,
        policy: FormPackSelectionPolicy
    ) throws {
        guard pack.acceptanceState != .rejected else {
            throw FormPackError.rejectedPack(packID: pack.id)
        }
        guard policy == .allowUnverifiedPilot || pack.isProductionEligible else {
            throw FormPackError.unverifiedPack(packID: pack.id)
        }
    }

    /// Current built-in behavior retained as a pilot-only pack until official
    /// XSD, XSLT, codelists, and EZZK acceptance artifacts are supplied.
    public static let currentLegacyUnverified = ConversionFormPack(
        id: "autogram-p2e-legacy-swift-1.0",
        direction: .paperToElectronic,
        recordVersion: "1.0",
        clauseVersion: "legacy-swift",
        namespace: AttestationXMLConstants.namespaceP2E,
        eFormIdentifier: AttestationXMLConstants.eFormIdentifier,
        effectiveFrom: Date(timeIntervalSince1970: 0),
        effectiveUntil: ZakoRegime.recordFirstFrom,
        verificationState: .unverified,
        acceptanceState: .unknown,
        renderer: .legacySwift,
        outputProfile: .pilotPDFA2b,
        newDocumentFormatItem: ZakoCodelists.pdfa2FormatItem,
        fingerprintMethodItem: ZakoCodelists.sha256Item)

    /// From 1. 1. 2027: record 1.2 (`_2021.sk`), sent before the clause (`ZakoRegime.recordFirst`).
    /// The clause stays 1.3, the only P→E clause form in force (no 2027 clause is published).
    public static let record12Unverified = ConversionFormPack(
        id: "chevron7-p2e-record-1.2",
        direction: .paperToElectronic,
        recordVersion: OfficialForm.record_1_2.version,
        clauseVersion: OfficialForm.clause_1_3.version,
        namespace: OfficialForm.record_1_2.namespace,
        eFormIdentifier: OfficialForm.record_1_2.identifier,
        effectiveFrom: ZakoRegime.recordFirstFrom,
        verificationState: .unverified,
        acceptanceState: .unknown,
        renderer: .legacySwift,
        outputProfile: .pilotPDFA2b,
        newDocumentFormatItem: ZakoCodelists.pdfa2FormatItem,
        fingerprintMethodItem: ZakoCodelists.sha256Item)

    /// The record form a pack's records are written in.
    public static func recordForm(of pack: ConversionFormPack) -> OfficialForm {
        pack.recordVersion == OfficialForm.record_1_2.version ? .record_1_2 : .record_1_0
    }
}
