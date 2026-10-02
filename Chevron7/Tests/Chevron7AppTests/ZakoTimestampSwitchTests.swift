// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class ZakoTimestampSwitchTests: XCTestCase {
    /// ZaKo's Demo switch cannot turn the timestamp off for the engine, which always adds one;
    /// the conversion then asks for the authority chosen in Settings.
    func testTheEngineAlwaysTimestampsInDemo() {
        let settingsStore = makeSettingsStore()
        settingsStore.ezzkAccountController.setMode(.demo)
        settingsStore.useRealSigningProvider(AlwaysTimestampingProvider())
        let store = ZakoSessionStore(settingsStore: settingsStore)
        XCTAssertTrue(store.showsQualifiedTimestampToggle)

        store.includeQualifiedTimestamp = false

        XCTAssertTrue(store.usesQualifiedTimestamp)
    }

    func testTheDemoProviderStillFollowsTheSwitch() {
        let settingsStore = makeSettingsStore()
        settingsStore.ezzkAccountController.setMode(.demo)
        settingsStore.useRealSigningProvider(DemoSigningProvider())
        let store = ZakoSessionStore(settingsStore: settingsStore)

        store.includeQualifiedTimestamp = false

        XCTAssertFalse(store.usesQualifiedTimestamp)
    }
}

private struct AlwaysTimestampingProvider: QualifiedSigningProviding {
    var alwaysAddsQualifiedTimestamp: Bool { true }

    func availableIdentities() async -> [SigningIdentityInfo] { [] }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.identityUnavailable
    }
}
