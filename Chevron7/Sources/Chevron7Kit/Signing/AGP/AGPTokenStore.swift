// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// The Autogram Portal API token. Lives only in the Keychain, same rule as
/// the EZZK password. Without it no bundle can be created, so the eIdentita
/// sheet refuses early with `AGPError.missingToken` instead of failing mid-run.
///
/// Storage goes through the shared `KeychainStore`; the protocol is only the
/// test seam so tests never touch the real Keychain.
public protocol AGPTokenStoring: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

public struct AGPTokenStore: AGPTokenStoring {
    static let account = "app.slovensko.chevron7.agp.api-token"

    public init() {}

    public func load() throws -> String? {
        KeychainStore.load(account: Self.account)
    }

    public func save(_ token: String) throws {
        guard KeychainStore.save(secret: token, account: Self.account) else {
            throw AGPTokenStoreError.saveFailure
        }
    }

    public func delete() throws {
        KeychainStore.delete(account: Self.account)
    }
}

public enum AGPTokenStoreError: Error, Equatable, LocalizedError {
    case saveFailure

    public var errorDescription: String? {
        "Token sa nepodarilo uložiť do Kľúčenky."
    }
}
