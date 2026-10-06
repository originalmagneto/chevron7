// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

final class SettingsStatusTests: XCTestCase {
    private func pill(_ tone: StatusPillModel.Tone, _ text: String) -> StatusPillModel {
        StatusPillModel(tone: tone, text: text)
    }

    func testProfile() {
        XCTAssertEqual(SettingsStatus.profile(AppSettings()), [pill(.attention, "Žiadny profil")])
        var profile = AdvocateProfile()
        profile.fullName = "JUDr. Ján Novák"
        let settings = AppSettings(profiles: [profile], activeProfileID: profile.id)
        XCTAssertEqual(SettingsStatus.profile(settings), [pill(.info, "JUDr. Ján Novák")])
    }

    func testEZZKDemo() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .demo, state: .signedOut, hasStoredCredentials: false, productionAllowed: true),
                       [pill(.info, "Skúšobný režim, bez zápisu do evidencie")])
    }

    func testEZZKProductionWithoutLogin() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .production, state: .signedOut, hasStoredCredentials: false, productionAllowed: true),
                       [pill(.attention, "Nepripojené")])
    }

    func testEZZKConnected() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .production, state: .signedOut, hasStoredCredentials: true, productionAllowed: true),
                       [pill(.ok, "Pripojené"), pill(.ok, "Odosielanie zapnuté")])
        XCTAssertEqual(SettingsStatus.ezzk(mode: .production, state: .signedOut, hasStoredCredentials: true, productionAllowed: false),
                       [pill(.ok, "Pripojené"), pill(.off, "Odosielanie zamknuté")])
    }

    func testEZZKTestMode() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .test, state: .signedOut, hasStoredCredentials: true, productionAllowed: true),
                       [pill(.info, "Testovacia evidencia"), pill(.ok, "Prihlásené")])
        XCTAssertEqual(SettingsStatus.ezzk(mode: .test, state: .signedOut, hasStoredCredentials: false, productionAllowed: true),
                       [pill(.info, "Testovacia evidencia"), pill(.attention, "Neprihlásené")])
    }

    func testEZZKFailedLoginAddsAttention() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .production, state: .failed("x"), hasStoredCredentials: false, productionAllowed: true),
                       [pill(.attention, "Nepripojené"), pill(.attention, "Prihlásenie zlyhalo")])
    }

    func testSigningCustomTSAIsUnverified() {
        let url = "https://tsa.example.sk/tsp"
        let pills = SettingsStatus.signing(AppSettings(customTSAServers: [url], selectedTSAURL: url))
        XCTAssertEqual(pills.last, pill(.attention, "Kvalifikácia neoverená"))
    }

    func testSigningBuiltInQualifiedTSA() {
        let qualified = TimestampAuthority.qualifiedURLs[0].absoluteString
        let pills = SettingsStatus.signing(AppSettings(selectedTSAURL: qualified))
        XCTAssertEqual(pills.last, pill(.ok, "Kvalifikovaná"))
        XCTAssertEqual(pills.first?.tone, .info)
    }

    func testMobile() {
        XCTAssertEqual(SettingsStatus.mobile(mobileSigningEnabled: true, eidentitaKeyStored: true, eidentitaUserID: "37"),
                       [pill(.ok, "Podpis mobilom zapnutý"), pill(.ok, "eIdentita pripravená")])
        XCTAssertEqual(SettingsStatus.mobile(mobileSigningEnabled: false, eidentitaKeyStored: true, eidentitaUserID: " "),
                       [pill(.off, "Podpis mobilom vypnutý"), pill(.attention, "eIdentita nedokončená")])
        XCTAssertEqual(SettingsStatus.mobile(mobileSigningEnabled: true, eidentitaKeyStored: false, eidentitaUserID: ""),
                       [pill(.ok, "Podpis mobilom zapnutý"), pill(.off, "eIdentita nenastavená")])
    }

    func testBrowserFinder() {
        XCTAssertEqual(SettingsStatus.browserFinder(agent: .enabled, quickAction: .visible),
                       [pill(.ok, "Safari prepojené"), pill(.ok, "Quick Action vo Findere")])
        XCTAssertEqual(SettingsStatus.browserFinder(agent: .requiresApproval, quickAction: .hiddenInFinder),
                       [pill(.attention, "Safari nie je prepojené"), pill(.attention, "Quick Action skrytá vo Findere")])
        XCTAssertEqual(SettingsStatus.browserFinder(agent: .unsignedBuild, quickAction: .notInstalled),
                       [pill(.off, "Safari: vývojárska zostava"), pill(.attention, "Quick Action nenainštalovaná")])
    }

    func testAI() {
        XCTAssertEqual(SettingsStatus.ai(mode: .builtInOnDevice, reviewedPages: 10),
                       [pill(.ok, "Interný režim"), pill(.info, "Skontrolované strany: 10 z 40")])
        XCTAssertEqual(SettingsStatus.ai(mode: .disabled, reviewedPages: nil), [pill(.off, "AI vypnutá")])
        XCTAssertEqual(SettingsStatus.ai(mode: .ollamaLocal, reviewedPages: nil), [pill(.info, "Ollama")])
    }
}
