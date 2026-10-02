// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

/// `lipo -archs` answered per path, so no test reads a real Mach-O file.
private struct FakeLipoProcess: LipoProcess {
    let architecturesByPath: [String: Set<MachOArchitecture>]
    let failingPaths: Set<String>

    init(_ architecturesByPath: [String: Set<MachOArchitecture>], failing: Set<String> = []) {
        self.architecturesByPath = architecturesByPath
        failingPaths = failing
    }

    func architectures(at url: URL) throws -> Set<MachOArchitecture> {
        if failingPaths.contains(url.path) { throw DriverRequirementError.architectureInspectionFailed }
        return architecturesByPath[url.path] ?? []
    }
}

final class DriverResolutionTests: XCTestCase {
    private let helperPath = "/Applications/Chevron7.app/Contents/Helpers/AutogramCLI-arm64"
    private let eidPath = "/Library/eID/libeidpkcs11.dylib"
    private let icaPath = "/usr/local/lib/libicasecurestore.dylib"
    private let intelPath = "/usr/local/lib/libintelonly.dylib"

    private func engine(lipo: FakeLipoProcess) -> AutogramCLIEngine {
        AutogramCLIEngine(
            configuration: ProcessConfiguration(executableURL: URL(fileURLWithPath: helperPath)),
            driverResolver: DriverResolver(lipo: lipo))
    }

    private func candidate(_ id: String, _ name: String, _ path: String, tokenPresent: Bool? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "path": .string(path)]
        if let tokenPresent { fields["tokenPresent"] = .bool(tokenPresent) }
        return .object(fields)
    }

    private func payload(_ candidates: [JSONValue]) -> [String: JSONValue] {
        ["drivers": .array(candidates)]
    }

    /// One Intel-only middleware on the Mac used to make DRIVERS throw, and every
    /// other card disappeared with it.
    func testAnIntelOnlyDriverDoesNotHideTheOtherCards() throws {
        let engine = engine(lipo: FakeLipoProcess([
            helperPath: [.arm64], eidPath: [.arm64, .x86_64], icaPath: [.arm64], intelPath: [.x86_64]
        ]))

        let drivers = try engine.signingDrivers(in: payload([
            candidate("eid", "Občiansky preukaz", eidPath, tokenPresent: true),
            candidate("secure_store", "I.CA SecureStore", icaPath, tokenPresent: false),
            candidate("legacy", "Starý ovládač", intelPath, tokenPresent: true)
        ]))

        XCTAssertEqual(drivers.map(\.id), ["eid", "secure_store", "legacy"])
        XCTAssertNil(drivers[0].unavailableReason)
        XCTAssertNil(drivers[1].unavailableReason)
        let reason = try XCTUnwrap(drivers[2].unavailableReason)
        XCTAssertTrue(reason.contains("Starý ovládač"))
        XCTAssertTrue(reason.contains("ARM64"))
        XCTAssertFalse(reason.contains("\u{2014}"))
    }

    /// A driver lipo cannot read is that driver's problem, not the whole list's.
    func testADriverThatCannotBeInspectedStaysOnItsOwn() throws {
        let engine = engine(lipo: FakeLipoProcess([helperPath: [.arm64], eidPath: [.arm64]],
                                                  failing: [intelPath]))

        let drivers = try engine.signingDrivers(in: payload([
            candidate("eid", "Občiansky preukaz", eidPath, tokenPresent: true),
            candidate("broken", "Poškodený ovládač", intelPath, tokenPresent: true)
        ]))

        XCTAssertEqual(drivers.map(\.id), ["eid", "broken"])
        XCTAssertNil(drivers[0].unavailableReason)
        XCTAssertTrue(try XCTUnwrap(drivers[1].unavailableReason).contains("Poškodený ovládač"))
    }

    /// The bundled helper itself without an arm64 slice is still a hard error.
    func testAHelperWithoutArm64IsStillAHardError() {
        let engine = engine(lipo: FakeLipoProcess([helperPath: [.x86_64], eidPath: [.arm64]]))

        XCTAssertThrowsError(try engine.signingDrivers(in: payload([
            candidate("eid", "Občiansky preukaz", eidPath, tokenPresent: true)
        ]))) { error in
            XCTAssertEqual(error as? DriverRequirementError, .arm64Required)
        }
    }

    func testIncompleteCandidatesAreSkipped() throws {
        let engine = engine(lipo: FakeLipoProcess([helperPath: [.arm64], eidPath: [.arm64]]))

        let drivers = try engine.signingDrivers(in: payload([
            .object(["id": .string("noname"), "path": .string(eidPath)]),
            candidate("eid", "Občiansky preukaz", eidPath)
        ]))

        XCTAssertEqual(drivers.map(\.id), ["eid"])
    }

    /// A driver that cannot run is never offered for certificates or signing,
    /// even when the engine saw a token in its reader.
    func testUsableDriversLeaveOutUnavailableOnes() {
        let drivers = [
            SigningDriver(id: "legacy", displayName: "Starý", tokenPresent: true, unavailableReason: "nemá ARM64"),
            SigningDriver(id: "eid", displayName: "eID", tokenPresent: false),
            SigningDriver(id: "secure_store", displayName: "I.CA", tokenPresent: nil)
        ]

        XCTAssertEqual(EngineBridgeSigningProvider.usableDrivers(drivers).map(\.id), ["secure_store"])
        XCTAssertEqual(EngineBridgeSigningProvider.usableDrivers([
            SigningDriver(id: "legacy", displayName: "Starý", tokenPresent: true, unavailableReason: "nemá ARM64"),
            SigningDriver(id: "eid", displayName: "eID", tokenPresent: true)
        ]).map(\.id), ["eid"])
    }

    /// With only an unusable driver left, the person learns why instead of being
    /// told to insert a card that is already in the reader.
    func testResolveIdentitiesNamesTheUnusableDriver() async {
        let reason = "Ovládač karty „Starý“ nemá verziu pre Apple Silicon (ARM64)."
        let provider = EngineBridgeSigningProvider(engine: FixedDriversEngine(drivers: [
            SigningDriver(id: "legacy", displayName: "Starý", tokenPresent: true, unavailableReason: reason)
        ]))

        let identities = await provider.resolveIdentities(pin: "1234")

        XCTAssertEqual(identities ?? [], [])
        XCTAssertEqual(provider.lastResolveError, reason)
    }
}

/// Reports a fixed driver list and nothing else.
private final class FixedDriversEngine: SigningEngine, @unchecked Sendable {
    private let fixedDrivers: [SigningDriver]

    init(drivers: [SigningDriver]) {
        fixedDrivers = drivers
    }

    func capabilities() async throws -> EngineCapabilities {
        EngineCapabilities(protocolVersion: 1, supportsQualifiedTimestamp: true)
    }

    func drivers() async throws -> [SigningDriver] { fixedDrivers }

    func certificates(driverID: String, pin: Secret?) async throws -> [SigningCertificate] { [] }

    func certificateDiscovery(driverID: String, pin: Secret?) async throws -> CertificateDiscovery {
        XCTFail("No certificate discovery on an unusable driver.")
        return CertificateDiscovery(token: SigningToken(tokenKey: "fake", providerName: "Fake"), certificates: [])
    }

    func inspect(files: [PDFItemDescriptor]) async throws -> [PDFInspection] { [] }

    func sign(request: EngineSigningRequest) -> AsyncThrowingStream<SigningEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: SigningFailure.engine("FixedDriversEngine does not sign.")) }
    }

    func cancel() async {}
}
