// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import PDFKit
import XCTest
@testable import Chevron7App
import Chevron7Kit
import Chevron7TestSupport

/// When the main window hands the keyboard to the eID client's BOK window
/// (`EIDKeyboardHandoff`): around every engine call for an eID, never for a card
/// that takes its PIN here.
@MainActor
final class EIDKeyboardHandoffTests: XCTestCase {
    private let keyboardURL = URL(fileURLWithPath: "/Applications/eID Klient.app/Contents/MacOS/VirtualKeyboard")
    private let eidClientURL = URL(fileURLWithPath: "/Applications/eID Klient.app/Contents/MacOS/eID Klient")

    // MARK: Decisions

    func testAppliesOnlyToTheProtectedAuthenticationPath() {
        XCTAssertTrue(EIDKeyboardHandoff.applies(to: Self.eid))
        XCTAssertFalse(EIDKeyboardHandoff.applies(to: Self.pinCard))
        XCTAssertFalse(EIDKeyboardHandoff.applies(to: nil))
    }

    func testRecognisesOnlyTheEIDClientsKeyboard() {
        XCTAssertTrue(EIDKeyboardHandoff.isEIDKeyboard(executableURL: keyboardURL))
        XCTAssertFalse(EIDKeyboardHandoff.isEIDKeyboard(executableURL: eidClientURL))
        XCTAssertFalse(EIDKeyboardHandoff.isEIDKeyboard(
            executableURL: URL(fileURLWithPath: "/Applications/Other.app/Contents/MacOS/VirtualKeyboard")))
        XCTAssertFalse(EIDKeyboardHandoff.isEIDKeyboard(executableURL: nil))
    }

    func testReclaimsActivationOnlyFromTheEIDClient() {
        // The BOK window closed and handed activation back: nothing to do.
        XCTAssertFalse(EIDKeyboardHandoff.shouldReclaimActivation(isActive: true, frontmostExecutableURL: keyboardURL))
        // The eID client kept it.
        XCTAssertTrue(EIDKeyboardHandoff.shouldReclaimActivation(isActive: false, frontmostExecutableURL: keyboardURL))
        XCTAssertTrue(EIDKeyboardHandoff.shouldReclaimActivation(isActive: false, frontmostExecutableURL: eidClientURL))
        // The person switched to another app meanwhile.
        XCTAssertFalse(EIDKeyboardHandoff.shouldReclaimActivation(
            isActive: false, frontmostExecutableURL: URL(fileURLWithPath: "/Applications/Safari.app/Contents/MacOS/Safari")))
        XCTAssertFalse(EIDKeyboardHandoff.shouldReclaimActivation(isActive: false, frontmostExecutableURL: nil))
    }

    func testDuringEndsTheHandoffWhenTheBodyThrows() async {
        let log = EventLog()
        let handoff = RecordingHandoff(log: log)
        do {
            try await handoff.during(true) { () async throws -> Void in
                log.append("body")
                throw SigningError.identityUnavailable
            }
            XCTFail("The body's error should propagate.")
        } catch {}
        XCTAssertEqual(log.events, ["begin", "body", "end"])
    }

    // MARK: Signing window

    func testReadingCertificatesFromAnEIDHandsTheKeyboardOver() async {
        let log = EventLog()
        let store = makeSigningStore(log: log, identity: Self.eid)
        store.signingPIN = "123456"

        await store.resolveCertificateForPreview(force: true)

        XCTAssertEqual(log.events, ["begin", "resolve", "end"])
    }

    func testTheCardsPlaceholderDecidesWhenTheSelectedCertificateIsGone() async {
        // The reader poll replaced the certificates with the eID's placeholder row
        // (as between batch items); the flag belongs to the driver, so it still applies.
        let log = EventLog()
        let store = makeSigningStore(log: log, identity: Self.eid)
        store.signingPIN = "123456"
        store.identities = [SigningIdentityInfo(
            id: "engine:eid", label: "Karta pripojená: eID", issuerSummary: "",
            isQualified: true, hasPrivateKey: true, requiresPIN: false, usesProtectedAuthenticationPath: true)]

        await store.resolveCertificateForPreview(force: true)

        XCTAssertEqual(log.events, ["begin", "resolve", "end"])
    }

    func testReadingCertificatesFromAPINCardLeavesTheKeyboardAlone() async {
        let log = EventLog()
        let store = makeSigningStore(log: log, identity: Self.pinCard)
        store.signingPIN = "123456"

        await store.resolveCertificateForPreview(force: true)

        XCTAssertEqual(log.events, ["resolve"])
    }

    func testSigningWithAnEIDHandsTheKeyboardOverAndEndsOnFailure() async throws {
        let log = EventLog()
        let store = makeSigningStore(log: log, identity: Self.eid)
        store.signingPIN = "123456"
        store.document = try XCTUnwrap(PDFDocument(data: TestPDFBuilderApp.typicalContractPDF()))

        await store.sign()

        XCTAssertEqual(log.events, ["begin", "sign", "end"])
        XCTAssertNotNil(store.lastError)
    }

    func testSigningWithAPINCardLeavesTheKeyboardAlone() async throws {
        let log = EventLog()
        let store = makeSigningStore(log: log, identity: Self.pinCard)
        store.signingPIN = "123456"
        store.document = try XCTUnwrap(PDFDocument(data: TestPDFBuilderApp.typicalContractPDF()))

        await store.sign()

        XCTAssertEqual(log.events, ["sign"])
    }

    // MARK: No PIN for an eID

    /// The main window asks for a PIN only for a card that takes it from the app;
    /// an eID's BOK goes to the eID client, so neither the field nor the sheet appears.
    func testOnlyAPINCardNeedsAPINToSign() {
        let log = EventLog()
        XCTAssertFalse(makeSigningStore(log: log, identity: Self.eid).signingNeedsPIN)
        XCTAssertTrue(makeSigningStore(log: log, identity: Self.pinCard).signingNeedsPIN)
    }

    func testAnEIDReadsItsCertificatesWithoutAPIN() async {
        let log = EventLog()
        let store = makeSigningStore(log: log, identity: Self.eid)

        await store.resolveCertificateForPreview(force: true)

        XCTAssertEqual(log.events, ["begin", "resolve", "end"])
    }

    func testAPINCardWaitsForItsPINBeforeReadingCertificates() async {
        let log = EventLog()
        let store = makeSigningStore(log: log, identity: Self.pinCard)

        await store.resolveCertificateForPreview(force: true)

        XCTAssertEqual(log.events, [])
    }

    func testSigningWithAnEIDAndNoPINGoesStraightToTheCard() async throws {
        let log = EventLog()
        let store = makeSigningStore(log: log, identity: Self.eid)
        store.document = try XCTUnwrap(PDFDocument(data: TestPDFBuilderApp.typicalContractPDF()))

        await store.sign()

        XCTAssertFalse(store.isAskingForSigningPIN)
        XCTAssertEqual(log.events, ["begin", "sign", "end"])
    }

    /// A visible stamp needs the signer's name, which an eID reads with its BOK.
    func testTheBatchCardAsksForAPINOnlyForAPINCard() {
        let log = EventLog()
        let eid = makeSigningStore(log: log, identity: Self.eid)
        eid.includeVisibleSignature = true
        XCTAssertFalse(eid.batchNeedsPIN)
        XCTAssertTrue(makeSigningStore(log: log, identity: Self.pinCard).batchNeedsPIN)

        let noCard = makeSigningStore(log: log, identity: Self.eid)
        noCard.identities = []
        noCard.selectedIdentityID = nil
        XCTAssertTrue(noCard.batchNeedsPIN)
    }

    // MARK: ZaKo

    func testZakoReadingCertificatesFromAnEIDHandsTheKeyboardOver() async {
        let log = EventLog()
        let settingsStore = makeSettingsStore()
        settingsStore.useRealSigningProvider(LoggingProvider(log: log, identity: Self.eid))
        let store = ZakoSessionStore(settingsStore: settingsStore)
        store.middlewareInput = RecordingHandoff(log: log)
        store.identities = [Self.eid]
        store.selectedIdentityID = Self.eid.id

        // An eID needs no PIN typed here: the BOK goes to the eID client.
        await store.resolveCertificateForAuthorization(force: true)

        XCTAssertEqual(log.events, ["begin", "resolve", "end"])
    }

    func testZakoReadingCertificatesFromAPINCardLeavesTheKeyboardAlone() async {
        let log = EventLog()
        let settingsStore = makeSettingsStore()
        settingsStore.useRealSigningProvider(LoggingProvider(log: log, identity: Self.pinCard))
        let store = ZakoSessionStore(settingsStore: settingsStore)
        store.middlewareInput = RecordingHandoff(log: log)
        store.identities = [Self.pinCard]
        store.selectedIdentityID = Self.pinCard.id
        store.signingPIN = "123456"

        await store.resolveCertificateForAuthorization(force: true)

        XCTAssertEqual(log.events, ["resolve"])
    }

    // MARK: Helpers

    private static let eid = SigningIdentityInfo(
        id: "engine-cert:eid", label: "Ján Tester", issuerSummary: "Disig SVK eID ACA2",
        isQualified: true, hasPrivateKey: true, requiresPIN: false, usesProtectedAuthenticationPath: true)

    private static let pinCard = SigningIdentityInfo(
        id: "engine-cert:ica", label: "Ján Tester", issuerSummary: "I.CA Qualified 2 CA",
        isQualified: true, hasPrivateKey: true, requiresPIN: true, usesProtectedAuthenticationPath: false)

    private func makeSigningStore(log: EventLog, identity: SigningIdentityInfo) -> SigningSessionStore {
        let settings = makeSettingsStore()
        let recent = RecentDocumentStore(settingsStore: settings, defaults: MemoryUserDefaults())
        let store = SigningSessionStore(signingProvider: LoggingProvider(log: log, identity: identity),
                                        settingsStore: settings, recentDocumentStore: recent)
        store.middlewareInput = RecordingHandoff(log: log)
        store.identities = [identity]
        store.selectedIdentityID = identity.id
        store.includeVisibleSignature = false
        store.convertToPDFA = false
        return store
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] { lock.withLock { storage } }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}

@MainActor
private final class RecordingHandoff: MiddlewareInputHandoff {
    let log: EventLog

    init(log: EventLog) {
        self.log = log
    }

    func begin() { log.append("begin") }
    func end() { log.append("end") }
}

/// Logs each engine call into the same log as the handoff, so the order shows
/// whether the call ran inside it; signing always fails.
private final class LoggingProvider: QualifiedSigningProviding, @unchecked Sendable {
    let log: EventLog
    let identity: SigningIdentityInfo

    init(log: EventLog, identity: SigningIdentityInfo) {
        self.log = log
        self.identity = identity
    }

    func availableIdentities() async -> [SigningIdentityInfo] { [identity] }

    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? {
        log.append("resolve")
        return [identity]
    }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        log.append("sign")
        throw SigningError.signingFailed("Test")
    }
}
