// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import SwiftUI
import XCTest
import Chevron7Kit
import Chevron7TestSupport
@testable import Chevron7App

/// F16 (2026-11-20): with a record-first conversion waiting for EZZK, the done step grew the
/// main window to 3437 points, past the screen, so the next conversion's buttons were out of
/// reach. The waiting card must fit a window of an ordinary size.
@MainActor
final class ZakoDoneWindowSizeTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    func testWaitingForEZZKKeepsTheWindowSize() async throws {
        let store = makeStore()
        store.attachRecordFirstPending(pending(attestation: store.attestation, stage: .awaitingEZZK))
        let window = host(DoneView(store: store))
        try await Task.sleep(for: .milliseconds(500))

        let content = window.contentRect(forFrameRect: window.frame).size
        XCTAssertLessThanOrEqual(window.contentMinSize.height, 700, "minimum \(window.contentMinSize)")
        XCTAssertEqual(content.height, 700, accuracy: 1, "content \(content)")
    }

    func testClauseReadyKeepsTheWindowSize() async throws {
        let store = makeStore()
        store.attachRecordFirstPending(pending(attestation: store.attestation, stage: .signingClientContainer))
        let window = host(DoneView(store: store))
        try await Task.sleep(for: .milliseconds(500))

        let content = window.contentRect(forFrameRect: window.frame).size
        XCTAssertLessThanOrEqual(window.contentMinSize.height, 700, "minimum \(window.contentMinSize)")
        XCTAssertEqual(content.height, 700, accuracy: 1, "content \(content)")
    }

    private func makeStore() -> ZakoSessionStore {
        let settingsStore = makeSettingsStore()
        let bank = ExampleBank(directory: makeTemporaryDirectory("done-window-bank"))
        return ZakoSessionStore(settingsStore: settingsStore, exampleBank: bank)
    }

    private func pending(attestation: AttestationData, stage: RecordFirstPending.Stage) -> RecordFirstPending {
        RecordFirstPending(
            recordID: UUID(), stage: stage,
            direction: .electronicToElectronic, originalFingerprints: [Data(repeating: 1, count: 32)],
            mode: .demo, evidenceNumber: "261120-qd580FC023", conversionTime: Date(),
            finalPDF: Data("%PDF-1.7\n".utf8), fingerprint: "00", containerDocumentName: "zmluva.pdf",
            containerFiles: [], directory: FileManager.default.temporaryDirectory,
            stampsSignatures: false, timestampServers: nil, tsaURL: nil, attestation: attestation,
            clientOutput: .singlePDF, appendedClause: nil, fixedTarget: nil,
            clientTimestampServers: nil, clientTSAURL: nil)
    }

    private func host<Content: View>(_ view: Content) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)
        self.window = window
        return window
    }
}
