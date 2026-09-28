// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Observation
import Chevron7Kit

/// Which phone app signs: the open-source Autogram v mobile (AVM relay) or
/// the state eIdentita app (Autogram Portal bundle as relay).
public enum MobileSigningMethod: Sendable {
    case autogramMobile
    case eidentita
}

/// Owns one mobile session at a time and the presentation flag of the QR sheet.
@MainActor
@Observable
final class MobileSigningCoordinator {
    var isPresented = false
    private(set) var session: AVMSigningSession?
    var isEidentitaPresented = false
    private(set) var eidentitaSession: EidentitaSigningSession?

    private let clientFactory: @MainActor () -> AVMClient
    private let agpBaseURL: URL
    private let agpTransport: (any AVMHTTPTransport)?
    private let tokenStore: any AGPTokenStoring
    private let pollInterval: Duration
    private let timeout: Duration
    private let eidentitaPollInterval: Duration
    private let eidentitaTimeout: Duration

    init(clientFactory: @escaping @MainActor () -> AVMClient,
         agpBaseURL: URL = AGPClient.stagingBaseURL,
         agpTransport: (any AVMHTTPTransport)? = nil,
         tokenStore: any AGPTokenStoring = AGPTokenStore(),
         pollInterval: Duration = .seconds(1),
         timeout: Duration = .seconds(900),
         eidentitaPollInterval: Duration = .seconds(10),
         eidentitaTimeout: Duration = .seconds(600)) {
        self.clientFactory = clientFactory
        self.agpBaseURL = agpBaseURL
        self.agpTransport = agpTransport
        self.tokenStore = tokenStore
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.eidentitaPollInterval = eidentitaPollInterval
        self.eidentitaTimeout = eidentitaTimeout
    }

    convenience init(settingsStore: AppSettingsStore) {
        self.init(clientFactory: { AVMClient(baseURL: settingsStore.settings.avmBaseURLValue) })
    }

    func sign(_ request: AVMUploadRequest) async throws -> AVMSignedDocument {
        if let session, session.isActive { session.cancel() }
        let session = AVMSigningSession(client: clientFactory(), pollInterval: pollInterval, timeout: timeout)
        self.session = session
        isPresented = true
        defer {
            isPresented = false
            self.session = nil
        }
        return try await session.run(request)
    }

    func cancel() {
        session?.cancel()
    }

    func signViaEidentita(_ request: AGPSigningRequest) async throws -> AGPSignedFile {
        let token = try Self.loadToken(from: tokenStore)
        if let eidentitaSession, eidentitaSession.isActive { eidentitaSession.cancel() }
        let client = AGPClient(baseURL: agpBaseURL, token: token,
                               transport: agpTransport ?? URLSessionAVMTransport())
        let session = EidentitaSigningSession(client: client,
                                             pollInterval: eidentitaPollInterval, timeout: eidentitaTimeout)
        self.eidentitaSession = session
        isEidentitaPresented = true
        defer {
            isEidentitaPresented = false
            self.eidentitaSession = nil
        }
        return try await session.run(request)
    }

    func cancelEidentita() {
        eidentitaSession?.cancel()
    }

    private static func loadToken(from store: any AGPTokenStoring) throws -> String {
        let token: String?
        do {
            token = try store.load()
        } catch {
            throw AGPError.transport(error.localizedDescription)
        }
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw AGPError.missingToken
        }
        return token
    }
}
