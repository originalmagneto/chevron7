// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class ZakoMobileAvailabilityTests: XCTestCase {
    func testMobileZakoIsRefusedOutsideDemo() async {
        let (settingsStore, _) = makeTestModeSettingsStore()
        settingsStore.settings.mobileSigningEnabled = true
        let store = ZakoSessionStore(settingsStore: settingsStore)

        XCTAssertFalse(store.isMobileSigningAvailable)
        await store.authorizeAndSign(viaMobile: true)
        XCTAssertEqual(store.lastError, ZakoSessionStore.mobileOutsideDemoMessage)
    }

    /// Demo EZZK with a real (non-demo) signing provider is the one combination this
    /// guard allows: `isMobileSigningAvailable` checks the EZZK mode, not the signing
    /// provider, so a real card in Demo still offers the phone.
    func testMobileZakoIsOfferedInDemoWithRealSigningProvider() {
        let settingsStore = makeSettingsStore()
        settingsStore.ezzkAccountController.setMode(.demo)
        settingsStore.settings.mobileSigningEnabled = true
        settingsStore.useRealSigningProvider(StubSigningProvider())
        let store = ZakoSessionStore(settingsStore: settingsStore)

        XCTAssertTrue(store.isMobileSigningAvailable)
    }

    /// Outside Demo the phone button disappears; the view falls back to a caption naming
    /// `mobileOutsideDemoMessage` instead of showing nothing.
    func testShowsMobileOutsideDemoNoticeInTestModeWithMobileEnabled() {
        let (settingsStore, _) = makeTestModeSettingsStore()
        settingsStore.settings.mobileSigningEnabled = true
        let store = ZakoSessionStore(settingsStore: settingsStore)

        XCTAssertTrue(store.showsMobileOutsideDemoNotice)
    }

    /// In Demo the phone button itself is available (or the card path is the only one, but
    /// either way the notice is redundant), so the caption must not also appear.
    func testShowsMobileOutsideDemoNoticeIsFalseInDemo() {
        let settingsStore = makeSettingsStore()
        settingsStore.ezzkAccountController.setMode(.demo)
        settingsStore.settings.mobileSigningEnabled = true
        let store = ZakoSessionStore(settingsStore: settingsStore)

        XCTAssertFalse(store.showsMobileOutsideDemoNotice)
    }

    /// With mobile signing turned off in Settings, neither the button nor the notice should
    /// appear.
    func testShowsMobileOutsideDemoNoticeIsFalseWhenMobileDisabled() {
        let (settingsStore, _) = makeTestModeSettingsStore()
        settingsStore.settings.mobileSigningEnabled = false
        let store = ZakoSessionStore(settingsStore: settingsStore)

        XCTAssertFalse(store.showsMobileOutsideDemoNotice)
    }

    /// Builds a settings store on an EZZK controller already in Test mode, with in-memory
    /// credentials and a transport with no replies, exactly as
    /// `ZakoEvidenceNumberTests.testNumberFetchedInDemoIsRefusedAfterSwitchingToTest` does
    /// for its own controller: no Keychain, no network.
    private func makeTestModeSettingsStore() -> (AppSettingsStore, EZZKAccountController) {
        let transport = ScriptedTransport([])
        let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in transport }, productionPolicy: .refused)
        let settingsStore = makeSettingsStore(ezzkAccountController: controller)
        return (settingsStore, controller)
    }

    /// One PDF is signed only with a card: the phone is refused with the delivery's own text,
    /// and the container keeps the phone.
    func testMobileDisabledForSinglePDF() {
        let settingsStore = makeSettingsStore()
        let store = ZakoSessionStore(settingsStore: settingsStore)
        XCTAssertNil(store.mobileRefusalForClientOutput)
        settingsStore.settings.zakoClientOutput = .singlePDF
        XCTAssertEqual(store.mobileRefusalForClientOutput, ZakoSinglePDFDelivery.mobileRefusal)
    }

    /// The order of 1. 1. 2027 signs the record first, which the phone cannot: the button is off
    /// with that reason before a click.
    func testMobileDisabledUnderRecordFirstOrder() {
        let settingsStore = makeSettingsStore()
        let store = ZakoSessionStore(settingsStore: settingsStore)
        XCTAssertNil(store.mobileRefusalForClientOutput)
        settingsStore.settings.zakoRecordFirstPreview = true
        XCTAssertEqual(store.mobileRefusalForClientOutput, ZakoSessionStore.recordFirstMobileMessage)
    }

    /// A disabled button shows no help tag on macOS: the reason is written under it while the
    /// phone button is shown and off, and nothing is written while it is live or hidden.
    func testMobileRefusalIsWrittenOutWhileTheButtonIsShown() {
        let settingsStore = makeSettingsStore()
        settingsStore.ezzkAccountController.setMode(.demo)
        settingsStore.settings.mobileSigningEnabled = true
        settingsStore.useRealSigningProvider(StubSigningProvider())
        let store = ZakoSessionStore(settingsStore: settingsStore)
        XCTAssertNil(store.mobileButtonRefusalNote, "live button, nothing to explain")

        settingsStore.settings.zakoRecordFirstPreview = true
        XCTAssertEqual(store.mobileButtonRefusalNote, ZakoSessionStore.recordFirstMobileMessage)

        settingsStore.settings.mobileSigningEnabled = false
        XCTAssertNil(store.mobileButtonRefusalNote, "no button, no note")
    }

    /// The EZZK login stops the authorization before the card: its unmet item is an orange
    /// warning, every other unmet item keeps the dashed circle.
    func testChecklistMarkerSetsTheBlockingItemApart() {
        XCTAssertEqual(ChecklistMarker(met: false, blocksBeforeCard: true).symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(ChecklistMarker(met: false, blocksBeforeCard: false).symbol, "circle.dashed")
        XCTAssertEqual(ChecklistMarker(met: true, blocksBeforeCard: true).symbol, "checkmark.circle.fill")
    }

    /// The verification screen says what happens to a PDF/A original per chosen output.
    func testKeptOriginalWordingFollowsClientOutput() {
        XCTAssertEqual(ZakoVerificationPresentation.keepNote(output: .asicContainer),
                       "Zostáva nezmenený aj s podpismi klienta: je to PDF/A bez príloh.")
        XCTAssertEqual(ZakoVerificationPresentation.keepNote(output: .singlePDF),
                       "Pri výstupe ako jeden PDF sa prevedie na nový PDF/A a doložka sa pripojí na koniec.")
        XCTAssertEqual(ZakoVerificationPresentation.keptDocumentLine(formatName: "PDF/A-2b", output: .asicContainer),
                       "PDF/A-2b, nezmenený s podpismi klienta")
        XCTAssertEqual(ZakoVerificationPresentation.keptDocumentLine(formatName: "PDF/A-2b", output: .singlePDF),
                       "nový PDF/A-3 s doložkou")
    }

    /// An original that must be converted becomes a PDF/A-2b for the container and a PDF/A-3 with
    /// the clause for the one PDF.
    func testConvertedOriginalWordingFollowsClientOutput() {
        XCTAssertEqual(ZakoVerificationPresentation.convertNote(reason: "Dokument nie je PDF/A", output: .asicContainer),
                       "Dokument nie je PDF/A, preto vznikne nový PDF/A-2b. Podpisy klienta zostanú zapísané v doložke.")
        XCTAssertEqual(ZakoVerificationPresentation.convertNote(reason: "Dokument nie je PDF/A", output: .singlePDF),
                       "Dokument nie je PDF/A, preto vznikne nový PDF/A-3 s doložkou. Podpisy klienta zostanú zapísané v doložke.")
        XCTAssertEqual(ZakoVerificationPresentation.convertedDocumentLine(output: .asicContainer), "nový PDF/A-2b")
        XCTAssertEqual(ZakoVerificationPresentation.convertedDocumentLine(output: .singlePDF), "nový PDF/A-3 s doložkou")
    }
}

/// Minimal non-demo signing provider: only what `QualifiedSigningProviding` requires with
/// no default implementation. Nothing in these tests calls `sign` or `availableIdentities`.
private final class StubSigningProvider: QualifiedSigningProviding, @unchecked Sendable {
    func availableIdentities() async -> [SigningIdentityInfo] { [] }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        SignedConversionResult(pdfData: Data(), asicData: nil, signedAt: Date(),
                               signatureLabel: "stub", isLegallyBinding: false)
    }
}
