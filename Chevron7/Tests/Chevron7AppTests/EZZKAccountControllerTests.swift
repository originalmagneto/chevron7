// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class EZZKAccountControllerTests: XCTestCase {
    func testDemoModeUsesTheLocalMock() {
        let controller = EZZKAccountController(mode: .demo, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in ScriptedTransport([]) }, productionPolicy: .refused)
        XCTAssertTrue(controller.isDemoMode)
        XCTAssertNil(controller.environment)
        XCTAssertTrue(controller.service is MockEZZKService)
    }

    func testSignInVerifiesWithEZZKBeforeSaving() async throws {
        let store = MemoryCredentialStore()
        let transport = ScriptedTransport([loginSucceeded])
        let controller = EZZKAccountController(mode: .test, credentialStore: store,
                                               transportFactory: { _ in transport }, productionPolicy: .refused)

        await controller.signIn(login: " ucet ", password: "heslo")

        guard case let .signedIn(accountName, _) = controller.state else {
            return XCTFail("expected signedIn, got \(controller.state)")
        }
        XCTAssertEqual(accountName, "ucet-test")
        XCTAssertEqual(try store.load(environment: .sandbox), EZZKSOAPCredentials(login: "ucet", password: "heslo"))
        XCTAssertEqual(controller.storedLogin, "ucet")
        XCTAssertTrue(controller.hasStoredCredentials)
    }

    func testRejectedSignInSavesNothing() async throws {
        let store = MemoryCredentialStore()
        let transport = ScriptedTransport([loginRejected])
        let controller = EZZKAccountController(mode: .test, credentialStore: store,
                                               transportFactory: { _ in transport }, productionPolicy: .refused)

        await controller.signIn(login: "ucet", password: "zle")

        XCTAssertEqual(controller.state, .failed("Nesprávne prihlasovacie meno alebo heslo."))
        XCTAssertNil(try store.load(environment: .sandbox))
        XCTAssertFalse(controller.hasStoredCredentials)
    }

    /// A Keychain that refuses to hand over the saved login (an ad hoc build, a denied access) is
    /// said in Settings, not shown as a plain "Neprihlásené" with empty fields.
    func testUnreadableKeychainIsShownNotSwallowed() {
        let store = MemoryCredentialStore()
        store.loadFailure = EZZKTokenStoreError.keychainFailure(status: -25293)
        let controller = EZZKAccountController(mode: .test, credentialStore: store,
                                               transportFactory: { _ in ScriptedTransport([]) }, productionPolicy: .refused)

        XCTAssertEqual(controller.state, .failed("Bezpečné úložisko (Keychain) nie je dostupné (kód -25293)."))
        XCTAssertFalse(controller.hasStoredCredentials)

        store.loadFailure = nil
        controller.setMode(.demo)
        XCTAssertEqual(controller.state, .signedOut, "Demo reads no Keychain item")
    }

    func testEmptyFieldsFailWithoutNetwork() async {
        let transport = ScriptedTransport([])
        let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in transport }, productionPolicy: .refused)

        await controller.signIn(login: "", password: "heslo")

        XCTAssertEqual(controller.state, .failed("Zadajte prihlasovacie meno aj heslo."))
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testSignOutDeletesStoredCredentials() throws {
        let store = MemoryCredentialStore()
        try store.save(EZZKSOAPCredentials(login: "ucet", password: "heslo"), environment: .production)
        let controller = EZZKAccountController(mode: .production, credentialStore: store,
                                               transportFactory: { _ in ScriptedTransport([]) }, productionPolicy: .refused)
        XCTAssertEqual(controller.storedLogin, "ucet")

        controller.signOut()

        XCTAssertNil(try store.load(environment: .production))
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertFalse(controller.hasStoredCredentials)
    }

    func testProductionServiceRefusesAllocationWithoutNetwork() async {
        let transport = ScriptedTransport([])
        let controller = EZZKAccountController(mode: .production, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in transport }, productionPolicy: .refused)

        do {
            _ = try await controller.service.requestEvidenceNumbers(count: 1)
            XCTFail("expected productionAllocationDisabled")
        } catch {
            XCTAssertEqual(error as? EZZKError, .productionAllocationDisabled)
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    /// Pins that `service(for:)` actually wires `productionPolicy` through to the SOAP
    /// client it builds: `.allowed` reaches EZZK for allocation, `.refused` never touches
    /// the network, whatever mode the controller happens to be in.
    func testProductionPolicyAllowedReachesEZZKForAllocation() async throws {
        let store = MemoryCredentialStore()
        try store.save(EZZKSOAPCredentials(login: "ucet", password: "heslo"), environment: .production)
        let transport = ScriptedTransport([loginSucceeded, numbersReply])
        let controller = EZZKAccountController(mode: .production, credentialStore: store,
                                               transportFactory: { _ in transport }, productionPolicy: .allowed)
        controller.configure(person: { EZZKPerson(corporateBodyFullName: "Advokátska kancelária Test", ico: "12345678") },
                             usedEvidenceNumbers: { _ in [] })

        let numbers = try await controller.service(for: .production).requestEvidenceNumbers(count: 1)

        XCTAssertEqual(numbers, ["260917-A"])
        XCTAssertEqual(transport.operations, ["LogIn", "GetConversionRecordEvidenceNumber"])
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testProductionPolicyRefusedTouchesNoNetworkViaServiceForProduction() async {
        let transport = ScriptedTransport([])
        let controller = EZZKAccountController(mode: .production, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in transport }, productionPolicy: .refused)

        do {
            _ = try await controller.service(for: .production).requestEvidenceNumbers(count: 1)
            XCTFail("expected productionAllocationDisabled")
        } catch {
            XCTAssertEqual(error as? EZZKError, .productionAllocationDisabled)
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testModeChangeResetsStateAndLoadsThatEnvironmentsLogin() throws {
        let store = MemoryCredentialStore()
        try store.save(EZZKSOAPCredentials(login: "testovaci", password: "x"), environment: .sandbox)
        let controller = EZZKAccountController(mode: .production, credentialStore: store,
                                               transportFactory: { _ in ScriptedTransport([]) }, productionPolicy: .refused)
        XCTAssertEqual(controller.storedLogin, "")

        controller.setMode(.test)

        XCTAssertEqual(controller.mode, .test)
        XCTAssertEqual(controller.environment, .sandbox)
        XCTAssertEqual(controller.storedLogin, "testovaci")
        XCTAssertEqual(controller.state, .signedOut)
    }

    func testFailedKeychainDeleteOnSignOutStillDropsTheLiveToken() async throws {
        let store = MemoryCredentialStore()
        try store.save(EZZKSOAPCredentials(login: "ucet", password: "heslo"), environment: .sandbox)
        store.deleteFailure = EZZKTokenStoreError.keychainFailure(status: -25308)
        let transport = ScriptedTransport([loginSucceeded, numbersReply, loginSucceeded, numbersReply])
        let controller = makeController(mode: .test, store: store, factory: { _ in transport })
        _ = try await controller.requestTestNumbers()

        controller.signOut()

        XCTAssertEqual(controller.state, .failed("Bezpečné úložisko (Keychain) nie je dostupné (kód -25308)."))
        XCTAssertEqual(controller.storedLogin, "ucet")
        _ = try await controller.requestTestNumbers()
        XCTAssertEqual(transport.operations,
                       ["LogIn", "GetConversionRecordEvidenceNumber", "LogIn", "GetConversionRecordEvidenceNumber"])
    }

    func testFirstCallAfterSignInLogsInWithTheStoredCredentials() async throws {
        let store = MemoryCredentialStore()
        let transport = ScriptedTransport([loginSucceeded, loginSucceeded, numbersReply])
        let controller = makeController(mode: .test, store: store, factory: { _ in transport })
        await controller.signIn(login: "ucet", password: "heslo")
        // Replacing the Keychain item proves the next login reads the store, not the password
        // the verification kept in memory.
        try store.save(EZZKSOAPCredentials(login: "ulozeny-ucet", password: "ulozene-heslo"), environment: .sandbox)

        let numbers = try await controller.requestTestNumbers()

        XCTAssertEqual(numbers, ["260917-A"])
        XCTAssertEqual(transport.operations, ["LogIn", "LogIn", "GetConversionRecordEvidenceNumber"])
        XCTAssertTrue(transport.bodies[1].contains("ulozeny-ucet"))
        XCTAssertTrue(transport.bodies[1].contains("ulozene-heslo"))
        XCTAssertFalse(transport.bodies[1].contains(">heslo<"))
    }

    func testOneTransportPerEnvironmentAcrossSignIns() async throws {
        let environments = EnvironmentLog()
        let transport = ScriptedTransport([loginSucceeded, loginSucceeded, loginSucceeded, numbersReply])
        let controller = makeController(mode: .test, store: MemoryCredentialStore(), factory: {
            environments.append($0)
            return transport
        })

        await controller.signIn(login: "ucet", password: "heslo")
        await controller.signIn(login: "ucet", password: "heslo")
        _ = try await controller.requestTestNumbers()
        XCTAssertEqual(environments.values, [.sandbox])

        controller.setMode(.production)
        _ = try? await controller.lookUp(evidenceNumber: "1563-260824-1")
        XCTAssertEqual(environments.values, [.sandbox, .production])
    }

    private func makeController(mode: AppSettings.EZZKMode, store: MemoryCredentialStore,
                                factory: @escaping @Sendable (EZZKEnvironment) -> any EZZKHTTPTransport)
        -> EZZKAccountController {
        let controller = EZZKAccountController(mode: mode, credentialStore: store, transportFactory: factory,
                                               productionPolicy: .refused)
        controller.configure(person: { EZZKPerson(corporateBodyFullName: "Advokátska kancelária Test", ico: "12345678") },
                             usedEvidenceNumbers: { _ in [] })
        return controller
    }

    private let numbersReply = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><GetConversionRecordEvidenceNumberResponse xmlns="http://www.ditec.sk/IEZZKService"><GetConversionRecordEvidenceNumberResult><Container xmlns="http://schemas.datacontract.org/2004/07/Ditec.IOM.EZZK.Dol"><Result><Code>0</Code><Description>OK</Description><Object><Data><ConversionRecordEvidenceNumberList><ConversionRecordEvidenceNumber>260917-A</ConversionRecordEvidenceNumber></ConversionRecordEvidenceNumberList></Data></Object></Result></Container></GetConversionRecordEvidenceNumberResult></GetConversionRecordEvidenceNumberResponse></s:Body></s:Envelope>"#

    private let loginSucceeded = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><OutputMessageOf_LogInOutput xmlns="http://ditec/2017/06/iam/core"><Content xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><ErrorCode i:nil="true"/><Account><Id>1</Id><Name>ucet-test</Name></Account><TokenDescriptor>token-1</TokenDescriptor></Content></OutputMessageOf_LogInOutput></s:Body></s:Envelope>"#

    /// A register row is looked up and sent in the environment of its own mode, even
    /// after the controller switched to another one.
    func testLookupAndServiceTargetTheGivenModeNotTheCurrentOne() async throws {
        let environments = EnvironmentLog()
        let transport = ScriptedTransport([])
        let controller = makeController(mode: .demo, store: MemoryCredentialStore(), factory: {
            environments.append($0)
            return transport
        })

        _ = try? await controller.lookUp(evidenceNumber: "1563-260924-1", in: .test)
        XCTAssertEqual(environments.values, [.sandbox])
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertTrue(controller.service(for: .test) is EZZKSOAPServiceAdapter)
        XCTAssertTrue(controller.service(for: .demo) is MockEZZKService)
        XCTAssertTrue(controller.service is MockEZZKService, "the current mode is still Demo")
    }

    private let loginRejected = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><OutputMessageOf_LogInOutput xmlns="http://ditec/2017/06/iam/core"><Content xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><ErrorCode>CORE-003</ErrorCode><Account i:nil="true"/><TokenDescriptor i:nil="true"/></Content></OutputMessageOf_LogInOutput></s:Body></s:Envelope>"#
}

private final class EnvironmentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [EZZKEnvironment] = []

    var values: [EZZKEnvironment] {
        lock.withLock { recorded }
    }

    func append(_ environment: EZZKEnvironment) {
        lock.withLock { recorded.append(environment) }
    }
}
