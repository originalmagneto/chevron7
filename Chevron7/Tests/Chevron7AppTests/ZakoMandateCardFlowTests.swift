// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
@testable import Chevron7App

/// ZaKo only with a mandate certificate: the card comes before a real evidence number
/// and before the authorization, and its PIN is asked for once per app run.
@MainActor
final class ZakoMandateCardFlowTests: XCTestCase {
    private static let mandateLabel = "Marián Čuprík OPRÁVNENIE 1042"

    private func makeStore(provider: CardFlowProvider,
                           card: MandateCertificate.CardState) -> ZakoSessionStore {
        let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in ScriptedTransport([]) },
                                               productionPolicy: .refused)
        let settingsStore = makeSettingsStore(ezzkAccountController: controller)
        settingsStore.useRealSigningProvider(provider)
        let store = ZakoSessionStore(settingsStore: settingsStore)
        store.readMandateCardState = { card }
        return store
    }

    func testNoCardAsksForTheCardBeforeANumber() async {
        let store = makeStore(provider: CardFlowProvider(cardInserted: false), card: .noCard)

        await store.requestEvidenceNumber()

        XCTAssertEqual(store.cardPrompt, .insertCard)
        XCTAssertEqual(store.pendingCardAction, .evidenceNumber)
        XCTAssertFalse(store.fetchingEvidenceNumber)
    }

    func testCardWithoutMandateGetsNoNumber() async {
        let store = makeStore(provider: CardFlowProvider(), card: .noMandate(labels: ["Marián Čuprík"]))

        await store.requestEvidenceNumber()

        XCTAssertNil(store.cardPrompt)
        XCTAssertEqual(store.evidenceNumberError, ZakoSessionStore.noMandateMessage)
        XCTAssertNil(store.attestation.evidenceNumber)
    }

    /// The MQC seen without a PIN is enough for the number; the PIN waits for the signature.
    func testMandateSeenWithoutPINLetsTheNumberThrough() async {
        let provider = CardFlowProvider()
        let store = makeStore(provider: provider, card: .mandate(label: Self.mandateLabel))

        await store.requestEvidenceNumber()

        XCTAssertNil(store.cardPrompt)
        XCTAssertNil(store.pendingCardAction)
        XCTAssertEqual(provider.resolvedPINs, [])
        XCTAssertNotEqual(store.evidenceNumberError, ZakoSessionStore.noMandateMessage)
        XCTAssertNotEqual(store.evidenceNumberError, ZakoSessionStore.insertMandateCardMessage)
    }

    func testFetchingDirectlyWithoutTheCardIsRefused() async {
        let store = makeStore(provider: CardFlowProvider(cardInserted: false), card: .noCard)

        await store.fetchEvidenceNumber()

        XCTAssertEqual(store.evidenceNumberError, ZakoSessionStore.insertMandateCardMessage)
    }

    func testAuthorizationAsksForThePINAndSelectsTheMandateCertificate() async {
        let provider = CardFlowProvider()
        let store = makeStore(provider: provider, card: .mandate(label: Self.mandateLabel))

        await store.beginAuthorization()
        XCTAssertEqual(store.cardPrompt, .enterPIN)

        await store.submitCardPIN("1234")

        XCTAssertEqual(provider.resolvedPINs, ["1234"])
        XCTAssertNil(store.cardPrompt)
        XCTAssertEqual(store.selectedIdentityID, CardFlowProvider.mandate.id)
        XCTAssertEqual(store.signingPIN, "1234")
    }

    /// A refused PIN is asked for again and never retried on its own.
    func testWrongPINIsForgottenAndAskedAgain() async {
        let provider = CardFlowProvider()
        let store = makeStore(provider: provider, card: .mandate(label: Self.mandateLabel))
        await store.beginAuthorization()

        await store.submitCardPIN("0000")

        XCTAssertEqual(store.cardPrompt, .enterPIN)
        XCTAssertEqual(store.signingPIN, "")
        XCTAssertEqual(provider.resolvedPINs, ["0000"])
    }

    func testResolvedCardWithoutMandateIsRefusedAtAuthorization() async {
        let provider = CardFlowProvider(resolved: [CardFlowProvider.plain])
        let store = makeStore(provider: provider, card: .noCard)
        await store.beginAuthorization()

        await store.submitCardPIN("1234")

        XCTAssertNil(store.cardPrompt)
        XCTAssertEqual(store.lastError, ZakoSessionStore.noMandateMessage)
    }

    /// Straight to `authorizeAndSign` with a qualified certificate that is not an MQC.
    func testAuthorizeAndSignRefusesANonMandateCertificate() async {
        let store = makeStore(provider: CardFlowProvider(), card: .noCard)
        store.identities = [CardFlowProvider.plain]
        store.selectedIdentityID = CardFlowProvider.plain.id

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError, ZakoSessionStore.noMandateMessage)
        XCTAssertFalse(store.requiresMandateOverride, "a real card gets no override")
    }

    /// Outside Demo a number needs the saved EZZK login: without it the button is off and the
    /// reason is given before the card or its PIN.
    func testSignedOutEZZKKeepsAuthorizationOff() throws {
        let credentials = MemoryCredentialStore()
        let controller = EZZKAccountController(mode: .test, credentialStore: credentials,
                                               transportFactory: { _ in ScriptedTransport([]) },
                                               productionPolicy: .refused)
        let store = ZakoSessionStore(settingsStore: makeSettingsStore(ezzkAccountController: controller))
        XCTAssertEqual(store.ezzkSignInRefusal, ZakoSessionStore.ezzkSignedOutMessage)
        XCTAssertFalse(store.canBeginAuthorization)

        try credentials.save(EZZKSOAPCredentials(login: "advokat", password: "heslo"), environment: .sandbox)
        let signedIn = EZZKAccountController(mode: .test, credentialStore: credentials,
                                             transportFactory: { _ in ScriptedTransport([]) },
                                             productionPolicy: .refused)
        let ready = ZakoSessionStore(settingsStore: makeSettingsStore(ezzkAccountController: signedIn))
        XCTAssertNil(ready.ezzkSignInRefusal)

        let demo = ZakoSessionStore(settingsStore: makeSettingsStore())
        XCTAssertNil(demo.ezzkSignInRefusal, "Demo needs no EZZK login")
    }

    /// Asking the drivers takes seconds: "Kontrolujem kartu…" shows before they answer.
    func testCheckingCardShowsBeforeTheDriversAnswer() async {
        let provider = CardFlowProvider(cardInserted: false)
        let gate = AsyncGate()
        provider.onDiscover = { await gate.wait() }
        let store = makeStore(provider: provider, card: .noCard)

        let flow = Task { await store.beginAuthorization() }
        while provider.discoveryCount == 0 { await Task.yield() }
        XCTAssertEqual(store.cardPrompt, .checkingCard)
        XCTAssertEqual(store.pendingCardAction, .authorization)

        await gate.open()
        await flow.value
        XCTAssertEqual(store.cardPrompt, .insertCard)
    }

    /// Empty reader slots go straight to "Vložte kartu" without asking the drivers.
    func testEmptyReaderAsksForTheCardAtOnce() async {
        let provider = CardFlowProvider(cardInserted: false)
        let store = makeStore(provider: provider, card: .noCard)
        store.readerSlotsHaveCard = { false }

        await store.beginAuthorization()

        XCTAssertEqual(store.cardPrompt, .insertCard)
        XCTAssertEqual(store.pendingCardAction, .authorization)
        XCTAssertEqual(provider.discoveryCount, 0)
    }

    /// Cancelled while the drivers answer: their late result raises no prompt.
    func testCancelWhileCheckingDropsTheLateResult() async {
        let provider = CardFlowProvider(cardInserted: false)
        let gate = AsyncGate()
        provider.onDiscover = { await gate.wait() }
        let store = makeStore(provider: provider, card: .noCard)

        let flow = Task { await store.beginAuthorization() }
        while provider.discoveryCount == 0 { await Task.yield() }
        store.cancelCardFlow()
        await gate.open()
        await flow.value

        XCTAssertNil(store.cardPrompt)
        XCTAssertNil(store.pendingCardAction)
    }

    func testPINOutlivesANewDocumentButNotTheCard() {
        let store = makeStore(provider: CardFlowProvider(), card: .noCard)
        store.signingPIN = "1234"

        store.resetSession(keepingProfile: true)
        XCTAssertEqual(store.signingPIN, "1234")

        store.applyReaderIdentities([])
        XCTAssertEqual(store.signingPIN, "")
    }
}

/// A card reader as the engine reports it: a card before the PIN, its certificates after.
private final class CardFlowProvider: QualifiedSigningProviding, @unchecked Sendable {
    static let synthetic = SigningIdentityInfo(id: "engine:ica", label: "Karta pripojená: I.CA",
                                               issuerSummary: "Zadajte PIN", isQualified: true,
                                               requiresPIN: true)
    static let mandate = SigningIdentityInfo(id: "engine-cert:1", label: "Marián Čuprík OPRÁVNENIE 1042",
                                             issuerSummary: "I.CA EU Qualified CA-SK", isMandateCertificate: true,
                                             isQualified: true, requiresPIN: true)
    static let plain = SigningIdentityInfo(id: "engine-cert:2", label: "Marián Čuprík",
                                           issuerSummary: "I.CA EU Qualified CA-SK", isQualified: true,
                                           requiresPIN: true)

    private let lock = NSLock()
    private let cardInserted: Bool
    private let resolved: [SigningIdentityInfo]
    private var unlocked = false
    private var pins: [String] = []
    private var discoveries = 0
    /// Runs inside `availableIdentities` before it answers, as slow drivers would.
    var onDiscover: (@Sendable () async -> Void)?

    init(cardInserted: Bool = true, resolved: [SigningIdentityInfo] = [mandate, plain]) {
        self.cardInserted = cardInserted
        self.resolved = resolved
    }

    var resolvedPINs: [String] { lock.withLock { pins } }
    var discoveryCount: Int { lock.withLock { discoveries } }

    func availableIdentities() async -> [SigningIdentityInfo] {
        lock.withLock { discoveries += 1 }
        await onDiscover?()
        guard cardInserted else { return [] }
        return lock.withLock { unlocked } ? resolved : [Self.synthetic]
    }

    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? {
        lock.withLock { pins.append(pin) }
        guard pin == "1234" else { return nil }
        lock.withLock { unlocked = true }
        return resolved
    }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.signingFailed("not used")
    }
}

/// Holds `wait()` callers until `open()`.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
