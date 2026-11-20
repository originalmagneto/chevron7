// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
@testable import Chevron7App

/// The authorize step (UI clarity decisions 3 and 4): the checklist model and its folding, a card
/// without a mandate refused before the card check, a stale error cleared when the card changes,
/// and the remembered PIN note.
@MainActor
final class ZakoAuthorizeStepTests: XCTestCase {
    private static let synthetic = SigningIdentityInfo(id: "engine:ica", label: "Karta pripojená: I.CA",
                                                       issuerSummary: "Zadajte PIN", isQualified: true,
                                                       requiresPIN: true)
    private static let mandate = SigningIdentityInfo(id: "engine-cert:1", label: "Marián Čuprík OPRÁVNENIE 1042",
                                                     issuerSummary: "I.CA EU Qualified CA-SK",
                                                     isMandateCertificate: true, isQualified: true, requiresPIN: true)

    private var card: MandateCertificate.CardState = .noCard

    /// Testovacia evidencia with a saved login and a stored conversion opened from the Register,
    /// so nothing but the card decides whether authorization may start.
    private func makeStore(provider: ReaderProvider = ReaderProvider(),
                           signedIn: Bool = true) throws -> ZakoSessionStore {
        let credentials = MemoryCredentialStore()
        if signedIn {
            try credentials.save(EZZKSOAPCredentials(login: "advokat", password: "heslo"), environment: .sandbox)
        }
        let controller = EZZKAccountController(mode: .test, credentialStore: credentials,
                                               transportFactory: { _ in ScriptedTransport([]) },
                                               productionPolicy: .refused)
        let settingsStore = makeSettingsStore(ezzkAccountController: controller)
        settingsStore.useRealSigningProvider(provider)
        let store = ZakoSessionStore(settingsStore: settingsStore)
        store.readMandateCardState = { [unowned self] in self.card }
        store.attachRecordFirstPending(RecordFirstPendingStoreTests.samplePending(stage: .signingClientContainer))
        store.isLoadedPendingConversion = true
        store.step = .authorize
        return store
    }

    // MARK: Checklist model

    func testSummaryFoldsMetItemsAndKeepsUnmetWithHints() {
        let summary = ZakoChecklistSummary(items: [
            ZakoChecklistItem(met: true, title: "A", symbol: "a", hint: "never shown"),
            ZakoChecklistItem(met: false, title: "B", symbol: "b", hint: "Vyplňte ho v doložke."),
            ZakoChecklistItem(met: true, title: "C", symbol: "c")
        ])

        XCTAssertEqual(summary.foldedTitle, "2 z 3 pripravené")
        XCTAssertEqual(summary.met.map(\.title), ["A", "C"])
        XCTAssertEqual(summary.unmet.map(\.title), ["B"])
        XCTAssertEqual(summary.unmet.first?.hint, "Vyplňte ho v doložke.")
        XCTAssertNil(summary.met.first?.hint, "a met item carries no hint")
        XCTAssertFalse(summary.allMet)
        XCTAssertTrue(ZakoChecklistSummary(items: [summary.items[0]]).allMet)
    }

    func testSignedOutLoginIsTheLastUnmetItemAndBlocksBeforeTheCard() throws {
        let store = try makeStore(signedIn: false)
        store.isLoadedPendingConversion = false

        let checklist = store.authorizeChecklist
        let login = try XCTUnwrap(checklist.items.last)

        XCTAssertEqual(login.title, "Prihlásenie do EZZK")
        XCTAssertFalse(login.met)
        XCTAssertTrue(login.blocksBeforeCard)
        XCTAssertNotNil(login.hint)
        XCTAssertTrue(checklist.unmet.contains(login))
        for item in checklist.items {
            XCTAssertFalse(item.title.contains("\u{2014}") || (item.hint ?? "").contains("\u{2014}"), "no em dash")
        }
    }

    func testCardItemsSayTheyComeFromTheCard() throws {
        let store = try makeStore()
        store.isLoadedPendingConversion = false

        let mandate = try XCTUnwrap(store.authorizeChecklist.items.first { $0.title == "Mandátny certifikát SAK pripravený" })

        XCTAssertFalse(mandate.met)
        XCTAssertEqual(mandate.hint, "Načíta sa z karty pri autorizácii.")
    }

    // MARK: A card without a mandate

    func testCardWithoutMandateKeepsAuthorizationOffAndNeverChecksTheCard() async throws {
        let provider = ReaderProvider(identities: [Self.synthetic])
        let store = try makeStore(provider: provider)
        card = .noMandate(labels: ["Marián Čuprík"])
        store.refreshMandateCardState()

        XCTAssertEqual(store.mandateGate, .noMandate)
        XCTAssertEqual(store.authorizeCardRefusal, "Vložte kartu s mandátnym certifikátom SAK.")
        XCTAssertFalse(store.canBeginAuthorization)

        await store.beginAuthorization()

        XCTAssertNil(store.cardPrompt)
        XCTAssertNil(store.pendingCardAction)
        XCTAssertEqual(provider.discoveryCount, 0, "the card check never starts")
    }

    func testOtherCardStatesKeepAuthorizationLive() throws {
        let store = try makeStore()

        card = .noCard
        store.refreshMandateCardState()
        XCTAssertEqual(store.mandateGate, .insertCard)
        XCTAssertTrue(store.canBeginAuthorization)

        store.identities = [Self.synthetic]
        XCTAssertEqual(store.mandateGate, .needsUnlock)
        XCTAssertTrue(store.canBeginAuthorization)

        card = .mandate(label: Self.mandate.label)
        store.refreshMandateCardState()
        XCTAssertEqual(store.mandateGate, .ready(label: Self.mandate.label))
        XCTAssertTrue(store.canBeginAuthorization)
        XCTAssertNil(store.authorizeCardRefusal)
    }

    // MARK: The error clears when the card changes

    func testErrorSurvivesIdenticalPollsAndTheOneAfterResolution() throws {
        let store = try makeStore()
        store.applyReaderIdentities([Self.synthetic])
        store.lastError = ZakoSessionStore.noMandateMessage

        store.applyReaderIdentities([Self.synthetic])
        XCTAssertEqual(store.lastError, ZakoSessionStore.noMandateMessage)

        // Resolving the PIN replaces the identities; the same card is still in the reader.
        store.identities = [Self.mandate]
        store.applyReaderIdentities([Self.mandate])
        XCTAssertEqual(store.lastError, ZakoSessionStore.noMandateMessage)
    }

    func testErrorClearsWhenTheCardIsRemoved() throws {
        let store = try makeStore()
        store.applyReaderIdentities([Self.synthetic])
        store.lastError = "Karta odmietla PIN."

        store.applyReaderIdentities([])

        XCTAssertNil(store.lastError)
    }

    func testErrorClearsWhenAnotherCardIsInserted() throws {
        let store = try makeStore()
        card = .noMandate(labels: ["Marián Čuprík"])
        store.applyReaderIdentities([Self.synthetic])
        store.lastError = ZakoSessionStore.noMandateMessage

        card = .mandate(label: Self.mandate.label)
        store.applyReaderIdentities([Self.synthetic])

        XCTAssertNil(store.lastError)
    }

    func testDoneStepErrorSurvivesTakingTheCardOut() throws {
        let store = try makeStore()
        store.step = .done
        store.applyReaderIdentities([Self.synthetic])
        store.lastError = "EZZK neodpovedalo."

        store.applyReaderIdentities([])

        XCTAssertEqual(store.lastError, "EZZK neodpovedalo.")
    }

    func testRunningCardFlowKeepsItsOwnError() throws {
        let store = try makeStore()
        store.applyReaderIdentities([Self.synthetic])
        store.pendingCardAction = .authorization
        store.lastError = ZakoSessionStore.noMandateMessage

        store.applyReaderIdentities([])

        XCTAssertEqual(store.lastError, ZakoSessionStore.noMandateMessage)
    }

    // MARK: Remembered PIN

    func testRememberedPINNoteShowsOnlyWhenThePINWillBeUsed() {
        func note(isDemo: Bool = false, pinHeld: Bool = true, typed: Bool = true, hasCard: Bool = true,
                  isBusy: Bool = false, refused: Bool = false) -> String? {
            ZakoSessionStore.rememberedPINNote(isDemo: isDemo, pinHeld: pinHeld, cardNeedsTypedPIN: typed,
                                               hasCard: hasCard, isBusy: isBusy, cardRefused: refused)
        }
        XCTAssertEqual(note(), ZakoSessionStore.rememberedPINMessage)
        XCTAssertNil(note(isDemo: true))
        XCTAssertNil(note(pinHeld: false))
        XCTAssertNil(note(typed: false), "an eID asks for its BOK every time")
        XCTAssertNil(note(hasCard: false))
        XCTAssertNil(note(isBusy: true))
        XCTAssertNil(note(refused: true), "the refusal is said instead")
        XCTAssertFalse(ZakoSessionStore.rememberedPINMessage.contains("\u{2014}"))
    }

    func testStoreShowsTheNoteForAHeldPINAndACardThatTakesIt() throws {
        let store = try makeStore()
        store.identities = [Self.synthetic]
        XCTAssertNil(store.rememberedPINNoteText)

        store.signingPIN = "1234"
        XCTAssertEqual(store.rememberedPINNoteText, ZakoSessionStore.rememberedPINMessage)

        store.pendingCardAction = .authorization
        XCTAssertNil(store.rememberedPINNoteText, "not while the card flow runs")
        XCTAssertTrue(store.isCardFlowActive)
    }
}

/// A reader that reports fixed identities and counts how often it was asked.
private final class ReaderProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let identities: [SigningIdentityInfo]
    private var discoveries = 0

    init(identities: [SigningIdentityInfo] = []) {
        self.identities = identities
    }

    var discoveryCount: Int { lock.withLock { discoveries } }

    func availableIdentities() async -> [SigningIdentityInfo] {
        lock.withLock { discoveries += 1 }
        return identities
    }

    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.signingFailed("not used")
    }
}
