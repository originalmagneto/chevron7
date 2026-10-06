// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import os

public struct ConversionRecordEnvelope: Codable, Sendable, Identifiable {
    public var id: UUID
    public var evidenceNumber: String
    public var direction: ConversionDirection
    public var originalName: String
    public var newDocumentName: String
    public var attestationXML: String
    public var fingerprintSHA256Hex: String
    public var conversionTime: Date
    public var signedAt: Date?
    public var submittedToCEZZKAt: Date?
    public var formPack: FormPackStamp?
    public var securityReview: SecurityReviewStamp?
    /// The signed record container (ASiC-E) `ReceiveConversionRecord` sends as the attachment.
    /// Not part of any persisted record: it is produced right before submission.
    public var signedRecordContainer: Data?

    public init(id: UUID = UUID(), evidenceNumber: String, direction: ConversionDirection,
                originalName: String, newDocumentName: String,
                attestationXML: String, fingerprintSHA256Hex: String,
                conversionTime: Date) {
        self.id = id
        self.evidenceNumber = evidenceNumber
        self.direction = direction
        self.originalName = originalName
        self.newDocumentName = newDocumentName
        self.attestationXML = attestationXML
        self.fingerprintSHA256Hex = fingerprintSHA256Hex
        self.conversionTime = conversionTime
        self.signedAt = nil
        self.submittedToCEZZKAt = nil
        self.formPack = nil
        self.securityReview = nil
        self.signedRecordContainer = nil
    }

    public init(id: UUID = UUID(), evidenceNumber: String, direction: ConversionDirection,
                originalName: String, newDocumentName: String,
                attestationXML: String, fingerprintSHA256Hex: String,
                conversionTime: Date, formPack: FormPackStamp?,
                securityReview: SecurityReviewStamp? = nil) {
        self.init(id: id, evidenceNumber: evidenceNumber, direction: direction,
                  originalName: originalName, newDocumentName: newDocumentName,
                  attestationXML: attestationXML,
                  fingerprintSHA256Hex: fingerprintSHA256Hex,
                  conversionTime: conversionTime)
        self.formPack = formPack
        self.securityReview = securityReview
    }
}

public enum EZZKError: LocalizedError, Equatable, Sendable {
    case notConfigured
    /// EZZK still rejects the token after one fresh login (also used by the dormant OAuth client).
    case authenticationFailed
    case invalidResponse
    case serverRejected(String)
    case networkFailure(String)
    case credentialsRejected(code: String)
    case accountLocked
    case serviceRejected(code: Int, message: String)
    case invalidRequest(String)
    case untrustedCertificate
    case productionAllocationDisabled
    case submissionUnavailable
    case evidenceNumberExpired
    case evidenceNumberFromOtherMode
    case outcomeUnknown
    /// Outside Demo, no bundled engine or no card identity leaves only the Demo signing
    /// provider, which must never allocate a number or send a record it cannot really sign.
    case demoSignatureOutsideDemo

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Prístupové údaje do EZZK nie sú nastavené. Zadajte ich v Nastaveniach."
        case .authenticationFailed:
            return "Prihlásenie do EZZK zlyhalo. Prihláste sa znova v Nastaveniach."
        case .invalidResponse:
            return "Nečitateľná odpoveď EZZK servera."
        case .serverRejected(let reason):
            return "EZZK zamietlo operáciu: \(reason)"
        case .networkFailure(let detail):
            return "Sieťová chyba pri spojení s EZZK: \(detail)"
        case .credentialsRejected(let code):
            // Only CORE-003 means a wrong name or password. The client stops logging in with
            // credentials EZZK refused for any code until they are saved again in Settings.
            return code == "CORE-003"
                ? "Nesprávne prihlasovacie meno alebo heslo."
                : "EZZK odmietlo prihlásenie (kód \(code)). Prihláste sa znova v Nastaveniach."
        case .accountLocked:
            return "Účet v EZZK je zablokovaný."
        case .serviceRejected(let code, let message):
            return "EZZK odmietlo požiadavku (kód \(code)): \(message)"
        case .invalidRequest(let detail):
            return "EZZK nerozumie požiadavke aplikácie Chevron7 (\(detail)). Ide o chybu aplikácie."
        case .untrustedCertificate:
            return "Certifikát testovacieho prostredia EZZK sa zmenil. Aktualizujte odtlačok v aplikácii."
        case .productionAllocationDisabled:
            return "Pridelenie evidenčných čísel v ostrej evidencii je v tejto verzii zamknuté, hoci je ostrá evidencia zvolená v Nastaveniach. Na skúšku použite skúšobný režim alebo testovaciu evidenciu."
        case .submissionUnavailable:
            return "Odosielanie záznamov do ostrej evidencie EZZK zatiaľ nie je zapnuté. Príde v ďalšej verzii."
        case .evidenceNumberExpired:
            return "Evidenčné číslo bolo pridelené v iný deň a EZZK ho o polnoci spotreboval. Kliknite znova na Autorizovať, pridelí sa nové."
        case .evidenceNumberFromOtherMode:
            return "Evidenčné číslo bolo získané v inom režime EZZK. Kliknite znova na Autorizovať, pridelí sa nové."
        case .outcomeUnknown:
            return "EZZK neodpovedalo zrozumiteľne (prerušené spojenie alebo chyba servera) a nie je isté, či požiadavku spracovalo. Pred opakovaním overte stav v EZZK."
        case .demoSignatureOutsideDemo:
            return "Bez podpisového enginu alebo karty aplikácia podpisuje iba ukážkovo (Demo). Mimo skúšobného režimu EZZK preto nepridelí evidenčné číslo ani neodošle záznam. Vložte kartu SAK a skontrolujte inštaláciu Chevron7."
        }
    }
}

public protocol EZZKServerClock: Sendable {
    func serverTime() async throws -> Date
}

public protocol EZZKEvidenceNumberProvider: Sendable {
    func requestEvidenceNumbers(count: Int) async throws -> [String]
}

public protocol EZZKSubmissionTransport: Sendable {
    func submit(_ envelope: ConversionRecordEnvelope) async throws -> EZZKSOAPSubmissionReceipt
}

public protocol EZZKServicing: EZZKServerClock, EZZKEvidenceNumberProvider, EZZKSubmissionTransport {}

public final class MockEZZKService: EZZKServicing, @unchecked Sendable {
    private struct State {
        var counter: Int
        var submitted: [ConversionRecordEnvelope] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State(counter: 0))
    public let registryCode: String

    public init(registryCode: String = "1563", startingNumber: Int = 1) {
        self.registryCode = registryCode
        _ = state.withLock { $0.counter = startingNumber }
    }

    public func serverTime() async throws -> Date { Date() }

    public func requestEvidenceNumbers(count: Int) async throws -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd"
        let dayStamp = formatter.string(from: Date())
        return state.withLock { st -> [String] in
            var numbers: [String] = []
            for _ in 0..<count {
                numbers.append(String(format: "%@-%@-%d", registryCode, dayStamp, st.counter))
                st.counter += 1
            }
            return numbers
        }
    }

    public func submit(_ envelope: ConversionRecordEnvelope) async throws -> EZZKSOAPSubmissionReceipt {
        state.withLock { $0.submitted.append(envelope) }
        return EZZKSOAPSubmissionReceipt(messageID: UUID().uuidString.lowercased(), submittedAt: Date())
    }

    public var submittedRecords: [ConversionRecordEnvelope] {
        state.withLock { $0.submitted }
    }
}

