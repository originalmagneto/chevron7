// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7TestSupport
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class SmartcardBadgeTests: XCTestCase {
    private let icaCard = SigningIdentityInfo(
        id: "engine:eid",
        label: "Karta pripojená: I.CA SecureStore",
        issuerSummary: "Zadajte PIN pre načítanie certifikátov",
        isQualified: true,
        requiresPIN: true)
    private let eidCard = SigningIdentityInfo(
        id: "engine:eid",
        label: "Karta pripojená: eID klient",
        issuerSummary: "Zadajte PIN pre načítanie certifikátov",
        isQualified: true,
        requiresPIN: true,
        usesProtectedAuthenticationPath: true)
    private let qualifiedCertificate = SigningIdentityInfo(
        id: "engine-cert:1",
        label: "Mgr. Ján Advokát",
        issuerSummary: "I.CA Qualified 2 CA/RSA 02/2016",
        isQualified: true)
    private let mandateCertificate = SigningIdentityInfo(
        id: "engine-cert:2",
        label: "Mgr. Ján Advokát (mandátny)",
        issuerSummary: "I.CA Qualified 2 CA/RSA 02/2016",
        isMandateCertificate: true,
        isQualified: true)

    func testZakoSectionShowsTheConnectedCardBeforeItsOwnStepReadsIdentities() {
        // ZaKo intake: the ZaKo store has not refreshed identities, nothing selected.
        let badge = SmartcardBadge(
            section: .zako, reader: [icaCard],
            signingSelectedID: icaCard.id, zakoSelectedID: nil, isDemo: false)

        XCTAssertTrue(badge.isConnected)
        XCTAssertEqual(badge.label, "Karta pripojená: I.CA SecureStore")
        XCTAssertEqual(badge.detail, "Karta I.CA · čítačka je pripravená")
    }

    func testEverySectionShowsTheSameCard() {
        for section in RootView.SidebarSection.allCases {
            let badge = SmartcardBadge(
                section: section, reader: [icaCard],
                signingSelectedID: nil, zakoSelectedID: nil, isDemo: false)
            XCTAssertTrue(badge.isConnected, "\(section)")
            XCTAssertEqual(badge.label, icaCard.label, "\(section)")
        }
    }

    func testEachSectionNamesTheCertificateItsOwnStoreSelected() {
        let reader = [qualifiedCertificate, mandateCertificate]

        let signing = SmartcardBadge(
            section: .signing, reader: reader,
            signingSelectedID: qualifiedCertificate.id, zakoSelectedID: mandateCertificate.id,
            isDemo: false)
        let zako = SmartcardBadge(
            section: .zako, reader: reader,
            signingSelectedID: qualifiedCertificate.id, zakoSelectedID: mandateCertificate.id,
            isDemo: false)
        let evidence = SmartcardBadge(
            section: .evidence, reader: reader,
            signingSelectedID: qualifiedCertificate.id, zakoSelectedID: mandateCertificate.id,
            isDemo: false)

        XCTAssertEqual(signing.label, qualifiedCertificate.label)
        XCTAssertEqual(zako.label, mandateCertificate.label)
        XCTAssertEqual(evidence.label, qualifiedCertificate.label)
    }

    func testWithoutASelectionTheMandateCertificateIsNamedFirst() {
        let badge = SmartcardBadge(
            section: .zako, reader: [qualifiedCertificate, mandateCertificate],
            signingSelectedID: nil, zakoSelectedID: nil, isDemo: false)

        XCTAssertEqual(badge.label, mandateCertificate.label)
    }

    func testEIDCardIsNamedAsCitizenCard() {
        let badge = SmartcardBadge(
            section: .zako, reader: [eidCard],
            signingSelectedID: nil, zakoSelectedID: nil, isDemo: false)

        XCTAssertEqual(badge.detail, "Občiansky preukaz (eID) · čítačka je pripravená")
    }

    func testEmptyReaderIsDisconnectedEvenWithAStaleSelection() {
        let badge = SmartcardBadge(
            section: .zako, reader: [],
            signingSelectedID: icaCard.id, zakoSelectedID: icaCard.id, isDemo: false)

        XCTAssertFalse(badge.isConnected)
        XCTAssertEqual(badge.label, "Karta nepripojená")
        XCTAssertEqual(badge.detail, "Vložte eID alebo SAK kartu")
    }

    func testDemoProviderWithoutIdentitiesSaysDemo() {
        let badge = SmartcardBadge(
            section: .signing, reader: [],
            signingSelectedID: nil, zakoSelectedID: nil, isDemo: true)

        XCTAssertFalse(badge.isConnected)
        XCTAssertEqual(badge.label, "DEMO režim")
    }
}

@MainActor
final class CardReaderStatusTests: XCTestCase {
    private let card = SigningIdentityInfo(
        id: "engine:eid", label: "Karta pripojená: I.CA SecureStore",
        issuerSummary: "", isQualified: true, requiresPIN: true)

    func testRefreshPublishesTheReaderAndHandsItToTheStores() async {
        var handedOver: [[SigningIdentityInfo]] = []
        let status = CardReaderStatus(discover: { [card] in [card] })
        status.onRefresh = { handedOver.append($0) }

        await status.refresh()

        XCTAssertEqual(status.identities, [card])
        XCTAssertEqual(handedOver, [[card]])
    }

    func testRefreshAsksTheReaderNothingWhilePaused() async {
        var discoveries = 0
        let status = CardReaderStatus(discover: { [card] in
            discoveries += 1
            return [card]
        })
        status.isPaused = { true }

        await status.refresh()

        XCTAssertEqual(discoveries, 0)
        XCTAssertEqual(status.identities, [])
    }

    func testWatchAsksTheReaderNothingWhileTheAppIsInactive() async {
        var discoveries = 0
        let status = CardReaderStatus(interval: .milliseconds(5), discover: { [card] in
            discoveries += 1
            return [card]
        })

        let watch = Task { await status.watch(isAppActive: { false }) }
        try? await Task.sleep(for: .milliseconds(60))
        watch.cancel()
        await watch.value

        XCTAssertEqual(discoveries, 0)
    }

    func testWatchPollsWhileTheAppIsActive() async {
        var discoveries = 0
        let status = CardReaderStatus(interval: .milliseconds(5), discover: { [card] in
            discoveries += 1
            return [card]
        })

        let watch = Task { await status.watch(isAppActive: { true }) }
        let deadline = ContinuousClock.now + .seconds(2)
        while discoveries < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        watch.cancel()
        await watch.value

        XCTAssertGreaterThan(discoveries, 1)
        XCTAssertEqual(status.identities, [card])
    }
}

@MainActor
final class SigningStoreReaderTests: XCTestCase {
    private let card = SigningIdentityInfo(
        id: "engine:eid", label: "Karta pripojená: I.CA SecureStore",
        issuerSummary: "", isQualified: true, requiresPIN: true)

    private func makeStore() -> SigningSessionStore {
        let settings = makeSettingsStore()
        return SigningSessionStore(
            signingProvider: settings.signingProvider,
            settingsStore: settings,
            recentDocumentStore: RecentDocumentStore(
                settingsStore: settings,
                defaults: MemoryUserDefaults()))
    }

    func testReaderSelectsTheInsertedCard() {
        let store = makeStore()

        store.applyReaderIdentities([card])

        XCTAssertEqual(store.identities, [card])
        XCTAssertEqual(store.selectedIdentityID, card.id)
    }

    func testRemovedCardClearsThePIN() {
        let store = makeStore()
        store.applyReaderIdentities([card])
        store.signingPIN = "1234"

        store.applyReaderIdentities([])

        XCTAssertEqual(store.identities, [])
        XCTAssertNil(store.selectedIdentityID)
        XCTAssertEqual(store.signingPIN, "")
    }

    func testReaderLeavesIdentitiesAloneWhileSigning() {
        let store = makeStore()
        store.applyReaderIdentities([card])
        store.isSigning = true

        store.applyReaderIdentities([])

        XCTAssertEqual(store.identities, [card])
    }
}
