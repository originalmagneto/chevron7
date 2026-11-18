// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation
@testable import Chevron7App

/// Stands in for the WebKit renderer and remembers the clause XML it was given.
@MainActor
final class StubClausePageRenderer: ClausePageRendering, @unchecked Sendable {
    static let pages = Data("%PDF-1.7 clause pages".utf8)
    private(set) var renderedXML: [String] = []
    private(set) var renderedForms: [OfficialForm] = []

    func render(clauseXML: Data, form: OfficialForm) async throws -> Data {
        renderedXML.append(String(decoding: clauseXML, as: UTF8.self))
        renderedForms.append(form)
        return Self.pages
    }
}

/// Plays the engine for the one-PDF request (the source plus a fake revision) and signs the
/// record and any container with the Demo provider. Records every request.
final class SinglePDFRecordingProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [SigningRequest] = []
    private var identityReads = 0
    private let demo = DemoSigningProvider()
    nonisolated(unsafe) var refusesClient = false
    nonisolated(unsafe) var changesPrefix = false

    var supportsAppendedClause: Bool { true }
    var clientRequests: [SigningRequest] { lock.withLock { received.filter { !$0.signsAsRecordContainer } } }
    var recordRequests: [SigningRequest] { lock.withLock { received.filter(\.signsAsRecordContainer) } }
    /// Every request in the order it arrived.
    var requests: [SigningRequest] { lock.withLock { received } }

    /// How often the card was asked for its certificates (with or without a PIN).
    var identityReadCount: Int { lock.withLock { identityReads } }

    func availableIdentities() async -> [SigningIdentityInfo] {
        lock.withLock { identityReads += 1 }
        return []
    }

    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? {
        lock.withLock { identityReads += 1 }
        return nil
    }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        lock.withLock { received.append(request) }
        if !request.signsAsRecordContainer, refusesClient {
            throw SigningError.signingFailed("Karta bola vybratá počas podpisu.")
        }
        if !request.signsAsRecordContainer, request.appendedClause != nil {
            var source = request.pdfData
            if changesPrefix { source[source.startIndex + 10] ^= 0xFF }
            return SignedConversionResult(pdfData: source + Data("\n% clause and signature\n%%EOF\n".utf8),
                                          asicData: nil, signedAt: Date(),
                                          signatureLabel: "Test", isLegallyBinding: false)
        }
        var local = request
        local.includeTimestamp = false
        return try await demo.sign(local)
    }
}
