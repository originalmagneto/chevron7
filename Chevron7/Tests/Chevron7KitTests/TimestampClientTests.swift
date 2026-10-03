// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Foundation
@testable import Chevron7Kit

final class TimestampClientTests: XCTestCase {
    struct StaticTransport: LLMTransport {
        var response: Data

        func post(url: URL, headers: [String: String], body: Data) async throws -> Data {
            response
        }
    }

    func testRequestEncodingMatchesGoldenVector() {
        let request = RFC3161TimestampClient.buildRequest(
            for: Data("abc".utf8),
            nonce: 0x01020304050607)
        XCTAssertEqual(request.hexString,
                       "3040020101302f300b06096086480165030402010420ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad0207010203040506070101ff")
    }

    func testParseResponseGoldenVector() throws {
        let data = Data(hexEncoded: "3081823003020100307b06092a864886f70d010702a06e306c02010131003065060b2a864886f70d0109100204a0560454305202010106082b06010505070103302f300b06096086480165030402010420ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad02014d180f32303236303832333132303030305a")
        let reply = try RFC3161TimestampClient.parseResponse(data)

        let expected = ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z")
        XCTAssertEqual(reply.genTime, expected)
        XCTAssertTrue(reply.token.starts(with: Data([0x30])))
        XCTAssertGreaterThan(reply.token.count, 16)
    }

    func testRejectedStatusThrows() {
        let rejected = DER.sequence([DER.sequence([DER.integer(2)])])
        XCTAssertThrowsError(try RFC3161TimestampClient.parseResponse(rejected)) { error in
            XCTAssertEqual(error as? TimestampError, .rejected(status: 2))
        }

        let grantedWithMods = DER.sequence([DER.sequence([DER.integer(1)])])
        let reply = try? RFC3161TimestampClient.parseResponse(grantedWithMods)
        XCTAssertNotNil(reply)
        XCTAssertTrue(reply?.token.isEmpty ?? false)
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try RFC3161TimestampClient.parseResponse(Data([0x04, 0x00])))
        XCTAssertThrowsError(try RFC3161TimestampClient.parseResponse(Data()))
    }

    func testDemoProviderRequestsAndAttachesTimestamp() async throws {
        let goldenResponse = Data(hexEncoded: "3081823003020100307b06092a864886f70d010702a06e306c02010131003065060b2a864886f70d0109100204a0560454305202010106082b06010505070103302f300b06096086480165030402010420ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad02014d180f32303236303832333132303030305a")

        final class StubbedProvider: QualifiedSigningProviding, @unchecked Sendable {
            let demo = DemoSigningProvider()
            let transport: LLMTransport
            init(transport: LLMTransport) { self.transport = transport }
            func availableIdentities() async -> [SigningIdentityInfo] {
                await demo.availableIdentities()
            }
            func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
                let client = RFC3161TimestampClient(transport: transport)
                guard let tsaURL = URL(string: request.tsaURL ?? "") else {
                    throw SigningError.timestampFailed
                }
                let reply = try await client.requestToken(for: request.pdfData, tsaURL: tsaURL)
                return SignedConversionResult(pdfData: request.pdfData,
                                              asicData: nil,
                                              signedAt: Date(),
                                              signatureLabel: "stub",
                                              isLegallyBinding: false,
                                              timestampGenTime: reply.genTime,
                                              timestampToken: reply.token)
            }
        }

        let provider = StubbedProvider(transport: StaticTransport(response: goldenResponse))
        let result = try await provider.sign(SigningRequest(pdfData: Data("d".utf8),
                                                            identityID: "demo",
                                                            includeTimestamp: true,
                                                            tsaURL: "http://tsa.test/qts"))
        XCTAssertEqual(result.timestampGenTime,
                       ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z"))
        XCTAssertNotNil(result.timestampToken)
    }

    func testDemoProviderWithoutTSAThrowsWhenTimestampRequested() async {
        let provider = DemoSigningProvider()
        do {
            _ = try await provider.sign(SigningRequest(pdfData: Data("d".utf8),
                                                       identityID: "demo",
                                                       includeTimestamp: true,
                                                       tsaURL: nil))
            XCTFail("Chýbajúca TSA musí vyhodiť chybu.")
        } catch {
            XCTAssertEqual(error as? SigningError, .timestampFailed)
        }
    }

    func testAppSettingsTSASelectionAndMigration() throws {
        let legacyJSON = Data("{\"tsaURL\":\"http://moja-tsa.kancelaria.sk/tsp\",\"ezzkICO\":\"\"}".utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertTrue(migrated.customTSAServers.contains("http://moja-tsa.kancelaria.sk/tsp"))
        XCTAssertEqual(migrated.selectedTSAURL, "http://moja-tsa.kancelaria.sk/tsp")

        let fresh = AppSettings()
        XCTAssertEqual(fresh.selectedTSAURL, TimestampAuthority.legacyDefaultURL)
        XCTAssertTrue(fresh.availableTSAServers.contains { $0.url == "http://tsa.belgium.be/connect" })
        XCTAssertTrue(fresh.availableTSAServers.contains { $0.url == "http://tsa.disig.sk/qts" })
        XCTAssertEqual(fresh.activeTSA.url, TimestampAuthority.legacyDefaultURL)

        var custom = AppSettings(customTSAServers: ["https://internal.tsa/x"],
                                 selectedTSAURL: "https://internal.tsa/x")
        XCTAssertEqual(custom.activeTSA.url, "https://internal.tsa/x")
        XCTAssertEqual(custom.availableTSAServers.count, TimestampAuthority.builtIn.count + 1)

        let reencoded = try JSONEncoder().encode(custom)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: reencoded)
        XCTAssertEqual(roundTrip.selectedTSAURL, custom.selectedTSAURL)
    }

    /// The pickers sit under a switch labelled "Kvalifikovaná časová pečiatka (QTS)", so the
    /// built-in list offers qualified authorities only.
    func testBuiltInAuthoritiesAreQualifiedOnly() {
        let fresh = AppSettings()
        XCTAssertTrue(TimestampAuthority.builtIn.allSatisfy(\.isQualified))
        XCTAssertTrue(fresh.availableTSAServers.allSatisfy(\.isQualified))
        for retired in TimestampAuthority.retiredUnqualified {
            XCTAssertFalse(fresh.availableTSAServers.contains { $0.url == retired.url })
        }
        XCTAssertFalse(fresh.activeTSAQualificationIsUnverified)
    }

    /// time.certum.pl is not a qualified service, so ZaKo's qualified list never sends it and a
    /// stored selection of it falls back to the default.
    func testCertumIsNotOfferedOrSentAsQualified() throws {
        XCTAssertFalse(TimestampAuthority.qualifiedURLs.map(\.absoluteString).contains("http://time.certum.pl"))
        XCTAssertTrue(TimestampAuthority.isRetiredUnqualified("http://time.certum.pl"))
        let stored = try JSONDecoder().decode(
            AppSettings.self, from: Data("{\"selectedTSAURL\":\"http://time.certum.pl\"}".utf8))
        XCTAssertEqual(stored.activeTSA.url, TimestampAuthority.legacyDefaultURL)
    }

    /// A non-qualified authority chosen before it left the list falls back to the default,
    /// whichever way it was stored, and never becomes a custom server.
    func testARetiredUnqualifiedAuthorityFallsBackToTheDefault() throws {
        let stored = try JSONDecoder().decode(
            AppSettings.self, from: Data("{\"selectedTSAURL\":\"http://timestamp.digicert.com\"}".utf8))
        XCTAssertEqual(stored.selectedTSAURL, TimestampAuthority.legacyDefaultURL)
        XCTAssertTrue(stored.customTSAServers.isEmpty)

        let legacy = try JSONDecoder().decode(
            AppSettings.self, from: Data("{\"tsaURL\":\"http://timestamp.sectigo.com\"}".utf8))
        XCTAssertEqual(legacy.selectedTSAURL, TimestampAuthority.legacyDefaultURL)
        XCTAssertTrue(legacy.customTSAServers.isEmpty)

        let typed = try JSONDecoder().decode(
            AppSettings.self,
            from: Data("{\"customTSAServers\":[\"http://timestamp.digicert.com\"],\"selectedTSAURL\":\"http://timestamp.digicert.com\"}".utf8))
        XCTAssertTrue(typed.customTSAServers.isEmpty)
        XCTAssertEqual(typed.activeTSA.url, TimestampAuthority.legacyDefaultURL)

        let inMemory = AppSettings(customTSAServers: ["http://timestamp.digicert.com"],
                                   selectedTSAURL: "http://timestamp.digicert.com")
        XCTAssertFalse(inMemory.availableTSAServers.contains { $0.url == "http://timestamp.digicert.com" })
        XCTAssertEqual(inMemory.activeTSA.url, TimestampAuthority.legacyDefaultURL)
    }

    /// A custom URL stays usable, but the app cannot know whether it is qualified.
    func testACustomAuthorityIsMarkedUnverified() {
        let custom = AppSettings(customTSAServers: ["https://tsa.kancelaria.test/tsp"],
                                 selectedTSAURL: "https://tsa.kancelaria.test/tsp")
        XCTAssertEqual(custom.activeTSA.url, "https://tsa.kancelaria.test/tsp")
        XCTAssertTrue(custom.activeTSAQualificationIsUnverified)
        XCTAssertFalse(TimestampAuthority.unverifiedQualificationWarning.contains("\u{2014}"))

        let builtIn = AppSettings(customTSAServers: ["https://tsa.kancelaria.test/tsp"],
                                  selectedTSAURL: "http://tsa.disig.sk/qts")
        XCTAssertFalse(builtIn.activeTSAQualificationIsUnverified)
    }

    /// The RFC 3161 client keeps skipping a non-qualified authority after it left the list.
    func testTimestampClientNeverAsksARetiredAuthority() async throws {
        let goldenResponse = Data(hexEncoded: "3081823003020100307b06092a864886f70d010702a06e306c02010131003065060b2a864886f70d0109100204a0560454305202010106082b06010505070103302f300b06096086480165030402010420ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad02014d180f32303236303832333132303030305a")
        let transport = URLRecordingTransport(response: goldenResponse)
        let client = RFC3161TimestampClient(transport: transport)

        _ = try await client.requestToken(for: Data("d".utf8),
                                          tsaURL: try XCTUnwrap(URL(string: "http://timestamp.digicert.com")))

        let asked = await transport.asked()
        XCTAssertEqual(asked, [try XCTUnwrap(TimestampAuthority.qualifiedURLs.first)])
    }
}

private actor URLRecordingTransport: LLMTransport {
    let response: Data
    private var urls: [URL] = []

    init(response: Data) { self.response = response }

    func post(url: URL, headers: [String: String], body: Data) async throws -> Data {
        urls.append(url)
        return response
    }

    func asked() -> [URL] { urls }
}

extension Data {
    init(hexEncoded string: String) {
        let chars = Array(string.lowercased())
        var bytes: [UInt8] = []
        var index = chars.startIndex
        while index + 1 < chars.endIndex,
              let high = chars[index].hexDigitValue,
              let low = chars[index + 1].hexDigitValue {
            bytes.append(UInt8(high * 16 + low))
            index += 2
        }
        self = Data(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
