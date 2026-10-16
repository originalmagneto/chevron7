// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import XCTest
@testable import Chevron7App

@MainActor
final class QualifiedValidationSettingsTests: XCTestCase {
    func testGroupIsAdvancedUntilAServiceIsAdded() {
        let settingsStore = makeSettingsStore()
        XCTAssertFalse(SettingsAdvancedState.qualifiedValidationIsActive(settingsStore.settings))
        settingsStore.settings.qualifiedValidationServices.append(
            QualifiedValidationService(name: "Validácia Disig", provider: "Disig, a.s.",
                                       portalURL: URL(string: "https://eidas.disig.sk")))
        XCTAssertTrue(SettingsAdvancedState.qualifiedValidationIsActive(settingsStore.settings))
    }

    func testFooterNamesTheDecreeAndTheProviders() {
        XCTAssertTrue(QualifiedValidationSection.footer.contains("§ 3 ods. 4 vyhlášky č. 70/2021 Z. z."))
        XCTAssertTrue(QualifiedValidationSection.footer.contains("NFQES"))
    }
}
