// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import Foundation

/// Mints the portal API tokens. The portal holds no passwords for integrators:
/// the user pastes a public key into their portal profile and every request
/// carries a short-lived JWT signed with the matching private key (ES256,
/// `sub` = portal user id, `exp` within 15 minutes, unique `jti`).
/// The private key lives only in the Keychain; the minter stamps one token
/// per call, so nothing stored ever expires.
public struct AGPTokenMinter: Sendable {
    public var userID: String
    private let keyLoader: @Sendable () throws -> P256.Signing.PrivateKey

    public init(userID: String, keyLoader: @escaping @Sendable () throws -> P256.Signing.PrivateKey) {
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyLoader = keyLoader
    }

    /// A token for one request. `lifetime` stays far below the portal's
    /// 15-minute ceiling so clock skew cannot reject it mid-run.
    public func mint(lifetime: TimeInterval = 300, id: String = UUID().uuidString) throws -> String {
        let trimmedID = userID
        guard !trimmedID.isEmpty else { throw AGPError.missingToken }
        let key = try keyLoader()
        let header = ["alg": "ES256", "typ": "JWT"]
        let payload: [String: Any] = [
            "sub": trimmedID,
            "exp": Int(Date().addingTimeInterval(lifetime).timeIntervalSince1970),
            "jti": id.replacingOccurrences(of: "-", with: ""),
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let signingInput = Self.base64url(headerData) + "." + Self.base64url(payloadData)
        guard let inputData = signingInput.data(using: .ascii) else { throw AGPError.invalidResponse }
        let derSignature = try key.signature(for: inputData).derRepresentation
        let rawSignature = try Self.ecdsaRaw(fromDER: derSignature)
        return signingInput + "." + Self.base64url(rawSignature)
    }

    // MARK: - Keys

    /// A fresh P-256 keypair. The portal reads the public half with
    /// `OpenSSL::PKey.read`, so it is exported as SPKI PEM (`PUBLIC KEY`).
    public static func generateKey() -> P256.Signing.PrivateKey {
        P256.Signing.PrivateKey()
    }

    /// SPKI DER of a P-256 public key: fixed prefix plus the 65-byte
    /// uncompressed point (`x963Representation`: `0x04` + x + y).
    public static func spkiDER(publicKey: P256.Signing.PublicKey) -> Data {
        // SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING }
        let prefix: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
            0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01,
            0x07, 0x03, 0x42, 0x00,
        ]
        return Data(prefix + publicKey.x963Representation)
    }

    public static func spkiPEM(publicKey: P256.Signing.PublicKey) -> String {
        let encoded = spkiDER(publicKey: publicKey).base64EncodedString()
        var wrapped = ""
        var rest = encoded[...]
        while !rest.isEmpty {
            wrapped += rest.prefix(64) + "\n"
            rest = rest.dropFirst(64)
        }
        return "-----BEGIN PUBLIC KEY-----\n\(wrapped)-----END PUBLIC KEY-----"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Private
    /// DER `SEQUENCE { INTEGER r, INTEGER s }` to the 64-byte JWS form.
    static func ecdsaRaw(fromDER der: Data) throws -> Data {
        var bytes = [UInt8](der)
        var index = 0
        func take(_ count: Int) throws -> [UInt8] {
            guard index + count <= bytes.count else { throw AGPError.invalidResponse }
            defer { index += count }
            return Array(bytes[index ..< index + count])
        }
        guard try take(1) == [0x30] else { throw AGPError.invalidResponse }
        let totalLength = try lengthPrefix()
        func lengthPrefix() throws -> Int {
            let first = try take(1)[0]
            if first & 0x80 == 0 { return Int(first) }
            let count = Int(first & 0x7F)
            guard (1...2).contains(count) else { throw AGPError.invalidResponse }
            return try take(count).reduce(0) { $0 * 256 + Int($1) }
        }
        guard try take(1) == [0x02] else { throw AGPError.invalidResponse }
        let rLength = try lengthPrefix()
        var r = try take(rLength)
        guard try take(1) == [0x02] else { throw AGPError.invalidResponse }
        let sLength = try lengthPrefix()
        var s = try take(sLength)
        _ = totalLength
        // Strip sign-padding, then left-pad to 32 bytes each.
        while r.count > 32, r.first == 0x00 { r.removeFirst() }
        while s.count > 32, s.first == 0x00 { s.removeFirst() }
        guard r.count <= 32, s.count <= 32 else { throw AGPError.invalidResponse }
        return Data(repeating: 0, count: 32 - r.count) + r + Data(repeating: 0, count: 32 - s.count) + s
    }
}
