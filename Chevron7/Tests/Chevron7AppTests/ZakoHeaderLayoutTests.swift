// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import SwiftUI
import XCTest
import Chevron7Kit
import Chevron7TestSupport
@testable import Chevron7App

/// The conversion header sits above every ZaKo step after intake and must never widen or
/// grow the window: a content minimum past the window's floor once looped AppKit's layout
/// (1.4.3). The widths are the steps' minimums measured before the header existed.
@MainActor
final class ZakoHeaderLayoutTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    private func minimumSize<V: View>(_ view: V) -> CGSize {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1000, height: 300))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.view.layoutSubtreeIfNeeded()
        return window.contentMinSize
    }

    /// The widest header there is: E→E, the 2027 order, one PDF, Testovacia evidencia.
    private func worstCaseStore() -> ZakoSessionStore {
        let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in ScriptedTransport([]) },
                                               productionPolicy: .refused)
        let settingsStore = makeSettingsStore(ezzkAccountController: controller)
        let original = settingsStore.settings
        addTeardownBlock { await MainActor.run { settingsStore.settings = original } }
        settingsStore.settings.zakoRecordFirstPreview = true
        settingsStore.settings.zakoClientOutput = .singlePDF
        let store = ZakoSessionStore(settingsStore: settingsStore,
                                     exampleBank: ExampleBank(directory: makeTemporaryDirectory("header-bank")))
        store.direction = .electronicToElectronic
        store.sourceNameOverride = "Zmluva o prevode obchodného podielu s dlhým názvom a prílohami"
        return store
    }

    func testWorstCaseHeaderShowsEverything() {
        let model = worstCaseStore().conversionHeaderModel
        XCTAssertTrue(model.isRecordFirst)
        XCTAssertEqual(model.environment, .test)
        XCTAssertEqual(model.progress.stages.count, 6)
    }

    func testHeaderAloneFitsANarrowContentArea() {
        let store = worstCaseStore()
        store.step = .authorize
        let size = minimumSize(ZakoConversionHeader(model: store.conversionHeaderModel))
        XCTAssertLessThanOrEqual(size.width, 280, "minimum \(size)")
        XCTAssertLessThan(size.height, 120, "minimum \(size)")
    }

    func testHeaderDoesNotWidenOrGrowTheSteps() {
        // Minimum widths of the steps without the header (2026-11-20): analysis 291,
        // authorize 320; the done step had none.
        let limits: [(ZakoSessionStore.Step, CGFloat)] = [(.analysis, 291), (.authorize, 320), (.done, 320)]
        for (step, limit) in limits {
            let store = worstCaseStore()
            store.step = step
            let size = minimumSize(ZakoFlowView(store: store))
            XCTAssertLessThanOrEqual(size.width, limit, "\(step): minimum \(size)")
            XCTAssertLessThan(size.height, 300, "\(step): minimum \(size)")
        }
    }

    func testWaitingForEZZKUnderTheHeaderKeepsTheWindowSize() async throws {
        let store = worstCaseStore()
        store.attachRecordFirstPending(pending(attestation: store.attestation))
        store.step = .done
        XCTAssertTrue(store.conversionHeaderModel.progress.isWaitingForEZZK)

        let controller = NSHostingController(rootView: ZakoFlowView(store: store))
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)
        self.window = window
        try await Task.sleep(for: .milliseconds(500))

        let content = window.contentRect(forFrameRect: window.frame).size
        XCTAssertLessThanOrEqual(window.contentMinSize.height, 700, "minimum \(window.contentMinSize)")
        XCTAssertEqual(content.height, 700, accuracy: 1, "content \(content)")
        XCTAssertEqual(content.width, 1000, accuracy: 1, "content \(content)")
    }

    private func pending(attestation: AttestationData) -> RecordFirstPending {
        RecordFirstPending(
            recordID: UUID(), stage: .awaitingEZZK,
            direction: .electronicToElectronic, originalFingerprints: [Data(repeating: 1, count: 32)],
            mode: .test, evidenceNumber: "261120-qd580FC023", conversionTime: Date(),
            finalPDF: Data("%PDF-1.7\n".utf8), fingerprint: "00", containerDocumentName: "zmluva.pdf",
            containerFiles: [], directory: FileManager.default.temporaryDirectory,
            stampsSignatures: false, timestampServers: nil, tsaURL: nil, attestation: attestation,
            clientOutput: .singlePDF, appendedClause: nil, fixedTarget: nil,
            clientTimestampServers: nil, clientTSAURL: nil)
    }
}
