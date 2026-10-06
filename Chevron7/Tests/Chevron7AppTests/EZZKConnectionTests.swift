// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class EZZKConnectionTests: XCTestCase {
    private func makeStore(replies: [String], credentials: MemoryCredentialStore = MemoryCredentialStore(),
                           mode: AppSettings.EZZKMode = .demo) -> AppSettingsStore {
        let transport = ScriptedTransport(replies)
        let controller = EZZKAccountController(mode: mode, credentialStore: credentials,
                                               transportFactory: { _ in transport }, productionPolicy: .refused)
        let store = makeSettingsStore(ezzkAccountController: controller)
        store.settings.ezzkMode = mode
        return store
    }

    func testIsConnectedOnlyOnProductionWithCredentials() {
        XCTAssertTrue(EZZKConnection.isConnected(mode: .production, hasStoredCredentials: true))
        XCTAssertFalse(EZZKConnection.isConnected(mode: .production, hasStoredCredentials: false))
        XCTAssertFalse(EZZKConnection.isConnected(mode: .test, hasStoredCredentials: true))
        XCTAssertFalse(EZZKConnection.isConnected(mode: .demo, hasStoredCredentials: true))
    }

    func testSuccessfulConnectLeavesProduction() async throws {
        let credentials = MemoryCredentialStore()
        let store = makeStore(replies: [loginSucceeded], credentials: credentials)

        let result = await EZZKConnection.connect(store: store, login: "ucet", password: "heslo")

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(store.settings.ezzkMode, .production)
        XCTAssertEqual(store.ezzkAccountController.mode, .production)
        XCTAssertEqual(try credentials.load(environment: .production),
                       EZZKSOAPCredentials(login: "ucet", password: "heslo"))
    }

    func testFailedConnectRestoresThePreviousMode() async throws {
        let credentials = MemoryCredentialStore()
        let store = makeStore(replies: [loginRejected], credentials: credentials)

        let result = await EZZKConnection.connect(store: store, login: "ucet", password: "zle")

        XCTAssertEqual(result, .failed("Nesprávne prihlasovacie meno alebo heslo."))
        XCTAssertEqual(store.settings.ezzkMode, .demo)
        XCTAssertEqual(store.ezzkAccountController.mode, .demo)
        XCTAssertNil(try credentials.load(environment: .production))
    }

    func testDisconnectKeepsProductionAndDropsCredentials() throws {
        let credentials = MemoryCredentialStore()
        try credentials.save(EZZKSOAPCredentials(login: "ucet", password: "heslo"), environment: .production)
        let store = makeStore(replies: [], credentials: credentials, mode: .production)
        XCTAssertTrue(store.ezzkAccountController.hasStoredCredentials)

        EZZKConnection.disconnect(store: store)

        XCTAssertEqual(store.settings.ezzkMode, .production)
        XCTAssertEqual(store.ezzkAccountController.mode, .production)
        XCTAssertFalse(store.ezzkAccountController.hasStoredCredentials)
        XCTAssertNil(try credentials.load(environment: .production))
    }

    private let loginSucceeded = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><OutputMessageOf_LogInOutput xmlns="http://ditec/2017/06/iam/core"><Content xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><ErrorCode i:nil="true"/><Account><Id>1</Id><Name>ucet-test</Name></Account><TokenDescriptor>token-1</TokenDescriptor></Content></OutputMessageOf_LogInOutput></s:Body></s:Envelope>"#

    private let loginRejected = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><OutputMessageOf_LogInOutput xmlns="http://ditec/2017/06/iam/core"><Content xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><ErrorCode>CORE-003</ErrorCode><Account i:nil="true"/><TokenDescriptor i:nil="true"/></Content></OutputMessageOf_LogInOutput></s:Body></s:Envelope>"#
}
