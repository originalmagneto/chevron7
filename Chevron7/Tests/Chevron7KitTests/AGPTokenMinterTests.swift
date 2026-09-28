// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import XCTest
@testable import Chevron7Kit

final class AGPTokenMinterTests: XCTestCase {
    func testMintBuildsVerifiableES256JWT() throws {
        let key = AGPTokenMinter.generateKey()
        let minter = AGPTokenMinter(userID: "123") { key }
        let token = try minter.mint()

        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(segments.count, 3)
        let header = try XCTUnwrap(decodeJSON(String(segments[0])))
        XCTAssertEqual(header["alg"] as? String, "ES256")
        let payload = try XCTUnwrap(decodeJSON(String(segments[1])))
        XCTAssertEqual(payload["sub"] as? String, "123")
        let exp = try XCTUnwrap(payload["exp"] as? Int)
        let skew = Double(exp) - Date().timeIntervalSince1970
        XCTAssertGreaterThan(skew, 0)
        XCTAssertLessThanOrEqual(skew, 15 * 60)
        let jti = try XCTUnwrap(payload["jti"] as? String)
        XCTAssertGreaterThanOrEqual(jti.count, 32)

        // The signature verifies against the public half.
        let signingInput = "\(segments[0]).\(segments[1])"
        let signatureData = try XCTUnwrap(base64urlDecode(String(segments[2])))
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        XCTAssertTrue(key.publicKey.isValidSignature(ecdsa, for: Data(signingInput.utf8)))
    }

    func testMintRejectsEmptyUserID() {
        let minter = AGPTokenMinter(userID: "  ") { AGPTokenMinter.generateKey() }
        XCTAssertThrowsError(try minter.mint()) { error in
            XCTAssertEqual(error as? AGPError, .missingToken)
        }
    }

    func testPublicKeyExportsSPKIPM() throws {
        let key = AGPTokenMinter.generateKey()
        let pem = AGPTokenMinter.spkiPEM(publicKey: key.publicKey)
        XCTAssertTrue(pem.hasPrefix("-----BEGIN PUBLIC KEY-----\n"))
        XCTAssertTrue(pem.hasSuffix("\n-----END PUBLIC KEY-----"))
        let body = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----\n", with: "")
            .replacingOccurrences(of: "\n-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let der = try XCTUnwrap(Data(base64Encoded: body))
        // 26-byte SPKI prefix plus the 65-byte uncompressed point.
        XCTAssertEqual(der.count, 26 + 65)
        XCTAssertEqual(der[der.count - 65], 0x04)
    }
    func testConfiguredRejectsMissingPieces() {
        XCTAssertThrowsError(
            try AGPClient.configured(userID: "  ", baseURL: AGPClient.stagingBaseURL,
                                     keyStore: StubAGPKeyStore(raw: Data(repeating: 1, count: 32)))) { error in
            XCTAssertEqual(error as? AGPError, .missingToken)
        }
        // The key loads lazily: a missing key fails the first mint, not the build.
        let client = try? AGPClient.configured(userID: "123", baseURL: AGPClient.stagingBaseURL,
                                               keyStore: StubAGPKeyStore(raw: nil))
        XCTAssertNotNil(client)
        XCTAssertThrowsError(try client?.minter.mint()) { error in
            XCTAssertEqual(error as? AGPError, .missingToken)
        }
    }

    func testConfiguredBuildsClient() throws {
        let client = try AGPClient.configured(userID: "123", baseURL: AGPClient.stagingBaseURL,
                                              keyStore: StubAGPKeyStore(raw: Data(repeating: 1, count: 32)))
        XCTAssertEqual(client.baseURL, AGPClient.stagingBaseURL)
        XCTAssertEqual(client.minter.userID, "123")
    }

    // MARK: - Helpers

    private func decodeJSON(_ base64url: String) throws -> [String: Any]? {
        guard let data = base64urlDecode(base64url) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func base64urlDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

private struct StubAGPKeyStore: AGPKeyStoring {
    var raw: Data?
    func loadPrivateKey() throws -> Data? { raw }
    func savePrivateKey(_ raw: Data) throws {}
    func delete() throws {}
}
