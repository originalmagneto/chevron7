// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// The portal signing key. The private half lives only in the Keychain; the
/// public half (SPKI PEM from `AGPTokenMinter`) goes into the portal profile
/// ("Verejný kľúč API tokenu"). The protocol is only the test seam.
public protocol AGPKeyStoring: Sendable {
    func loadPrivateKey() throws -> Data?
    func savePrivateKey(_ raw: Data) throws
    func delete() throws
}

public struct AGPKeyStore: AGPKeyStoring {
    static let account = "app.slovensko.chevron7.agp.private-key"

    public init() {}

    public func loadPrivateKey() throws -> Data? {
        guard let base64 = KeychainStore.load(account: Self.account) else { return nil }
        return Data(base64Encoded: base64)
    }

    public func savePrivateKey(_ raw: Data) throws {
        guard KeychainStore.save(secret: raw.base64EncodedString(), account: Self.account) else {
            throw AGPKeyStoreError.saveFailure
        }
    }

    public func delete() throws {
        KeychainStore.delete(account: Self.account)
    }
}

public enum AGPKeyStoreError: Error, Equatable, LocalizedError {
    case saveFailure

    public var errorDescription: String? {
        "Kľúč sa nepodarilo uložiť do Kľúčenky."
    }
}
