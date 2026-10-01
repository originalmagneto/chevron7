// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import Chevron7Kit
import XCTest
@testable import Chevron7App

/// A developer's Mac can have EZZK Test mode saved with a real Keychain password, and a
/// settings store loads whatever settings its `UserDefaults` holds. `makeSettingsStore()` must
/// never let that leak into a controller that could read or write the real Keychain or reach
/// the network, nor let one test's settings reach another test.
@MainActor
final class TestSettingsStoreTests: XCTestCase {
    func testDefaultTestSettingsStoreNeverTouchesTheRealKeychain() {
        let settingsStore = makeSettingsStore()

        settingsStore.ezzkAccountController.setMode(.test)

        XCTAssertEqual(settingsStore.ezzkAccountController.storedLogin, "")
        XCTAssertTrue(settingsStore.ezzkAccountController.credentialStore is MemoryCredentialStore)
    }

    /// A settings change saves at once (`AppSettingsStore.settings` didSet); it must stay in
    /// that store's memory, never reach the runner's `UserDefaults.standard` or the next test.
    func testSettingsChangesNeverReachStandardDefaultsOrAnotherStore() {
        let key = "\(ProductIdentity.bundleIdentifier).settings.v1"
        let standardBefore = UserDefaults.standard.data(forKey: key)
        let first = makeSettingsStore()

        first.settings.ezzkICO = "12345678"

        XCTAssertEqual(first.settings.ezzkICO, "12345678")
        XCTAssertEqual(makeSettingsStore().settings.ezzkICO, AppSettings.standard.ezzkICO)
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), standardBefore)
    }
}
