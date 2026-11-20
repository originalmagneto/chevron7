// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import SwiftUI
import XCTest
import Chevron7Kit
import Chevron7TestSupport
@testable import Chevron7App

/// The register detail sheet (owner's screenshot of 2026-11-20): at its default size the footer
/// buttons, the status timeline and the overview fit, so nothing is truncated, wrapped mid-word
/// or hidden below the fold. Measured at the views' ideal (unconstrained) sizes, because text
/// squeezed into a narrower proposal wraps or truncates instead of overflowing.
@MainActor
final class RecordDetailLayoutTests: XCTestCase {
    private var contentWidth: CGFloat { RecordDetailView.idealSize.width - 2 * RecordDetailView.padding }

    private func idealSize<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testFooterWithEveryActionFitsTheDefaultWidth() {
        let footer = RecordDetailFooter(evidenceURI: "https://example.invalid/record/1563-260924-1",
                                        canFinish: true, canSaveRecord: true, canSaveValidation: true,
                                        deleteDisabled: false, onFinish: {}, onSaveRecord: {},
                                        onSaveValidation: {}, onDelete: {}, onClose: {})
        let size = idealSize(footer)
        XCTAssertLessThanOrEqual(size.width, contentWidth, "footer \(size)")
        XCTAssertLessThanOrEqual(size.width, RecordDetailView.minimumSize.width - 2 * RecordDetailView.padding,
                                 "footer \(size) at the minimum width")
        XCTAssertLessThan(size.height, 40, "one row of buttons: \(size)")
        XCTAssertGreaterThan(size.width, 300, "measured the buttons, not an empty view: \(size)")
    }

    func testTimelineLabelsFitOnOneLine() {
        var record = makeRecord()
        record.status = .processed
        let stages = EvidenceRegisterDetail.timeline(for: record).map { (label: $0.label, done: $0.done, failed: $0.failed) }
        let size = idealSize(StatusTimeline(stages: stages))
        XCTAssertLessThanOrEqual(size.width, RecordDetailView.minimumSize.width - 2 * RecordDetailView.padding,
                                 "timeline \(size)")
        // A circle (22) over one caption line, plus the vertical padding: never two lines.
        XCTAssertLessThan(size.height, 60, "timeline \(size)")
        XCTAssertGreaterThan(size.width, 250, "measured the labels: \(size)")
    }

    func testOverviewFitsTheDefaultHeight() throws {
        for (status, stage) in [(EvidenceRecord.Status.processed, RecordFirstPending.Stage.signingClientContainer),
                                (.outcomeUnknown, .awaitingEZZK)] {
            let settingsStore = makeSettingsStore()
            var record = makeRecord()
            record.status = status
            settingsStore.evidenceStore.upsert(record)
            try settingsStore.recordFirstPendingStore.save(pending(id: record.id, stage: stage))
            let view = RecordDetailView(settingsStore: settingsStore, recordID: record.id, onClose: {},
                                        scrollsOverview: false)
                .frame(width: RecordDetailView.idealSize.width)
            let size = idealSize(view)
            XCTAssertLessThanOrEqual(size.height, RecordDetailView.idealSize.height, "\(status): \(size)")
            XCTAssertGreaterThan(size.height, 560, "measured the whole overview, not the minimum: \(size)")
        }
    }

    // MARK: Fixtures

    /// The longest row there is: E→E, one PDF, every submission fact, a long result text.
    private func makeRecord() -> EvidenceRecord {
        let now = Date()
        var record = EvidenceRecord(createdAt: now, status: .processed, direction: .electronicToElectronic,
                                    originalName: "Zmluva o prevode obchodného podielu s prílohami.asice",
                                    newDocumentName: "Zmluva o prevode obchodného podielu s prílohami.pdf",
                                    evidenceNumber: "261120-Wg580fC029",
                                    fingerprintSHA256Hex: String(repeating: "ab", count: 32),
                                    attestationXML: "<x/>", conversionTime: now,
                                    performingPersonName: "JUDr. Mgr. Testovacia Advokátka, PhD.",
                                    securityElementCount: 0, totalPages: 0, totalSheets: 0, ezzkMode: .test,
                                    evidenceNumberAllocatedAt: now)
        record.clientOutput = .singlePDF
        record.revisionOneLength = 1_234_567
        record.submittedAt = now
        record.submissionMessageID = "urn:uuid:" + UUID().uuidString.lowercased()
        record.ezzkResultCode = 1
        record.ezzkResultDescription = "Záznam o konverzii bol úspešne spracovaný a zapísaný do evidencie"
        record.lastLookupAt = now
        record.recordContainerPath = "Evidence/records/x.asice"
        record.validationEvidencePath = "Evidence/validation/x.xml"
        record.validationEvidenceSource = "Overenie voči dôveryhodným zoznamom (Chevron7)"
        return record
    }

    private func pending(id: UUID, stage: RecordFirstPending.Stage) -> RecordFirstPending {
        let attestation = ZakoSessionStore(settingsStore: makeSettingsStore(),
                                           exampleBank: ExampleBank(directory: makeTemporaryDirectory("detail-bank")))
            .attestation
        return RecordFirstPending(
            recordID: id, stage: stage,
            direction: .electronicToElectronic, originalFingerprints: [Data(repeating: 1, count: 32)],
            mode: .test, evidenceNumber: "261120-Wg580fC029", conversionTime: Date(),
            finalPDF: Data("%PDF-1.7\n".utf8), fingerprint: "00", containerDocumentName: "zmluva.pdf",
            containerFiles: [], directory: FileManager.default.temporaryDirectory,
            stampsSignatures: false, timestampServers: nil, tsaURL: nil, attestation: attestation,
            clientOutput: .singlePDF, appendedClause: nil, fixedTarget: nil,
            clientTimestampServers: nil, clientTSAURL: nil)
    }
}
