// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7TestSupport
import Foundation
import XCTest
@testable import Chevron7Kit

final class EZZKProductionPolicyTests: XCTestCase {
    private let person = EZZKPerson(corporateBodyFullName: "Advokát", ico: "12345678")

    /// Values stay in memory: a named suite would leave a plist in ~/Library/Preferences.
    private func defaults() -> UserDefaults {
        MemoryUserDefaults()
    }

    /// Production is open for everyone: no owner switch is needed any more.
    func testProductionIsAllowedWithoutTheOwnerSwitch() {
        let policy = EZZKProductionPolicy.current(defaults: defaults())
        XCTAssertTrue(EZZKProductionPolicy.enabledForEveryone)
        XCTAssertEqual(policy, .allowed)
        XCTAssertNil(policy.refusal(environment: .production, submitting: true))
    }

    /// The refusal itself still works for code that builds `.refused` (tests, `ezzk-probe`).
    func testARefusedPolicyStillRefusesProduction() {
        let policy = EZZKProductionPolicy.refused
        XCTAssertEqual(policy.refusal(environment: .production, submitting: false), .productionAllocationDisabled)
        XCTAssertEqual(policy.refusal(environment: .production, submitting: true), .submissionUnavailable)
        XCTAssertNil(policy.refusal(environment: .sandbox, submitting: true))
    }

    func testTheOwnerSwitchAllowsProduction() {
        let store = defaults()
        store.set(true, forKey: EZZKProductionPolicy.ownerSwitchKey)
        let policy = EZZKProductionPolicy.current(defaults: store)
        XCTAssertEqual(policy, .allowed)
        XCTAssertNil(policy.refusal(environment: .production, submitting: true))
    }

    func testClientDefaultsToRefusedAndSendsNothingOnProduction() async throws {
        let transport = SOAPScriptedTransport([])
        let client = EZZKSOAPClient(environment: .production, transport: transport,
                                    credentials: { EZZKSOAPCredentials(login: "a", password: "b") })
        XCTAssertEqual(client.productionPolicy, .refused)
        do {
            _ = try await client.evidenceNumbers(for: person)
            XCTFail("production allocation must be refused")
        } catch {
            XCTAssertEqual(error as? EZZKError, .productionAllocationDisabled)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAllowedClientReachesProductionForAllocation() async throws {
        let transport = SOAPScriptedTransport([
            .ok(EZZKSOAPFixtures.loginSucceeded()),
            .ok(EZZKSOAPFixtures.evidenceNumbers(["260917-A"]))
        ])
        let client = EZZKSOAPClient(environment: .production, transport: transport,
                                    credentials: { EZZKSOAPCredentials(login: "a", password: "b") },
                                    productionPolicy: .allowed)
        let numbers = try await client.evidenceNumbers(for: person)
        XCTAssertEqual(numbers, ["260917-A"])
        XCTAssertEqual(transport.requests.count, 2)
    }
}
