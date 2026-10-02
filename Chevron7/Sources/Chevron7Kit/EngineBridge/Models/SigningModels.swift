// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
@_exported import Chevron7WebBridge

enum EngineSigningOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case pades
    case asiceXAdES

    var id: Self { self }

    var signatureLevel: String {
        self == .asiceXAdES ? "XAdES_BASELINE_T" : "PAdES_BASELINE_T"
    }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .pades: "PDF with PAdES"
        case .asiceXAdES: "ASiC-E with XAdES"
        }
    }

    func outputExtension(for sourceURL: URL) -> String {
        if sourceURL.pathExtension.lowercased() == "asice" {
            return "asice"
        }
        return self == .asiceXAdES ? "asice" : sourceURL.pathExtension
    }
}

struct SigningFile: Sendable, Equatable, Identifiable {
    let id: String
    let sourceURL: URL
    let visibleAppearance: VisibleSignatureRequest?
    /// Further documents signed with `sourceURL` as data objects of one ASiC-E.
    let attachmentURLs: [URL]

    var redactedDisplayName: String {
        sourceURL.lastPathComponent
    }

    init(id: String, sourceURL: URL, visibleAppearance: VisibleSignatureRequest? = nil, attachmentURLs: [URL] = []) {
        self.id = id
        self.sourceURL = sourceURL
        self.visibleAppearance = visibleAppearance
        self.attachmentURLs = attachmentURLs
    }
}

struct VisibleSignatureRequest: Sendable, Equatable {
    let renderedPNGURL: URL
    let page: Int
    let originX: Double
    let originY: Double
    let width: Double
    let height: Double
    let signingTime: Date
}

struct EngineSigningRequest: Sendable {
    let sessionID: UUID
    let driverID: String
    let certificateSerial: String
    let pin: Secret
    let files: [SigningFile]
    let outputFormat: EngineSigningOutputFormat
    let eform: EFormSigningAttributes?
    /// Overrides the level derived from `outputFormat`. State portals ask for
    /// Baseline B, which carries no timestamp.
    let signatureLevelOverride: String?
    /// Explicit timestamp endpoints: the authority the person chose, or ZaKo's
    /// qualified list. When set and non-empty, `AutogramCLIEngine.sign` uses exactly
    /// these for a Baseline T signature instead of `timestampSourceProvider.load()`.
    let timestampServersOverride: [String]?

    init(
        sessionID: UUID,
        driverID: String,
        certificateSerial: String,
        pin: Secret,
        files: [SigningFile],
        outputFormat: EngineSigningOutputFormat = .automatic,
        eform: EFormSigningAttributes? = nil,
        signatureLevelOverride: String? = nil,
        timestampServersOverride: [String]? = nil
    ) {
        self.sessionID = sessionID
        self.driverID = driverID
        self.certificateSerial = certificateSerial
        self.pin = pin
        self.files = files
        self.outputFormat = outputFormat
        self.eform = eform
        self.signatureLevelOverride = signatureLevelOverride
        self.timestampServersOverride = timestampServersOverride
    }
}

enum SessionState: Sendable, Equatable {
    case idle
    case inspectingFiles
    case resolvingDriver
    case loadingCertificates
    case selectingCertificate
    case awaitingPIN
    case signing(progress: BatchProgress)
    case completed(BatchSummary)
    case partiallyCompleted(BatchSummary)
    case failed(SigningFailure)
    case cancelled
}

enum SigningActivityPhase: Sendable, Equatable {
    case inspectingDocuments
    case readingSigningCard
    case loadingCertificates
    case preparingSignatures
    case signingDocuments
    case validatingSignedDocuments
    case savingSignedDocuments

    var label: String {
        switch self {
        case .inspectingDocuments:
            "Inspecting documents"
        case .readingSigningCard:
            "Reading the signing card"
        case .loadingCertificates:
            "Loading certificates"
        case .preparingSignatures:
            "Preparing signatures"
        case .signingDocuments:
            "Signing documents and requesting a qualified timestamp"
        case .validatingSignedDocuments:
            "Validating signed documents"
        case .savingSignedDocuments:
            "Saving signed documents"
        }
    }

    init?(machinePhase: String) {
        switch machinePhase {
        case "preparing":
            self = .preparingSignatures
        case "signing":
            self = .signingDocuments
        case "validating":
            self = .validatingSignedDocuments
        case "saving":
            self = .savingSignedDocuments
        default:
            return nil
        }
    }
}

struct BatchProgress: Sendable, Equatable {
    let total: Int
    let completed: Int
    let failed: Int

    init(total: Int, completed: Int = 0, failed: Int = 0) {
        self.total = total
        self.completed = completed
        self.failed = failed
    }
}

struct BatchSummary: Sendable, Equatable {
    let succeeded: Int
    let failed: Int

    init(succeeded: Int, failed: Int) {
        self.succeeded = succeeded
        self.failed = failed
    }
}

enum SigningEvent: Sendable, Equatable {
    case started
    case activity(SigningActivityPhase)
    case fileSigning(String)
    case completed(String, outputURL: URL)
    case failed(String, SigningFailure)
    case cancelled
}

enum SigningFailure: Error, Sendable, Equatable {
    case invalidTransition
    case engine(String)
    case fileFailed(String)
}

extension SigningFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidTransition:
            "The signing workflow entered an invalid state."
        case .engine(let message):
            message
        case .fileFailed:
            "A PDF could not be signed."
        }
    }
}

final class Secret: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    convenience init(_ value: String) {
        self.init(bytes: Array(value.utf8))
    }

    deinit {
        zeroize()
    }

    func consumeBytes() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }

        guard !bytes.isEmpty else { return nil }
        let consumed = bytes
        zeroize()
        return consumed
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        zeroize()
    }

    private func zeroize() {
        for index in bytes.indices {
            bytes[index] = 0
        }
        bytes.removeAll(keepingCapacity: false)
    }
}

extension Array where Element == UInt8 {
    mutating func zeroize() {
        for index in indices {
            self[index] = 0
        }
        removeAll(keepingCapacity: false)
    }
}
