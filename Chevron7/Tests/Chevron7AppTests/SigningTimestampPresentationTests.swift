// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class SigningTimestampPresentationTests: XCTestCase {
    private typealias Row = SigningTimestampPresentation.Row

    func testCardSignatureNamesTheSettingsAuthority() {
        let rows = SigningTimestampPresentation.authorityRows(
            mobileMethod: nil, settingsAuthorityName: "Belgium BOSA (kvalifikovaná)",
            settingsAuthorityURL: "http://tsa.belgium.be/connect", validatedAuthority: "Belgium TSA unit")
        XCTAssertEqual(rows, [Row(label: "Autorita", value: "Belgium BOSA (kvalifikovaná)"),
                              Row(label: "Adresa", value: "http://tsa.belgium.be/connect")])
    }

    func testPhoneSignatureNeverShowsTheSettingsAuthority() {
        // eIDENTITA timestamps on its own; Belgium BOSA from Settings was shown here before.
        let rows = SigningTimestampPresentation.authorityRows(
            mobileMethod: .eidentita, settingsAuthorityName: "Belgium BOSA (kvalifikovaná)",
            settingsAuthorityURL: "http://tsa.belgium.be/connect", validatedAuthority: nil)
        XCTAssertEqual(rows, [Row(label: "Autorita", value: "Pridala aplikácia eIDENTITA")])
    }

    func testPhoneSignatureNamesTheValidatedAuthority() {
        let rows = SigningTimestampPresentation.authorityRows(
            mobileMethod: .autogramMobile, settingsAuthorityName: "Belgium BOSA (kvalifikovaná)",
            settingsAuthorityURL: "http://tsa.belgium.be/connect", validatedAuthority: "Phone TSA unit")
        XCTAssertEqual(rows, [Row(label: "Autorita", value: "Phone TSA unit"),
                              Row(label: "Pridala", value: "Autogram v mobile")])
    }

    func testBlankValidatedAuthorityFallsBackToTheApp() {
        let rows = SigningTimestampPresentation.authorityRows(
            mobileMethod: .autogramMobile, settingsAuthorityName: "x", settingsAuthorityURL: "y",
            validatedAuthority: "  ")
        XCTAssertEqual(rows, [Row(label: "Autorita", value: "Pridala aplikácia Autogram v mobile")])
    }
}
