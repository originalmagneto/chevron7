// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation
import XCTest
@testable import Chevron7App

/// The sidebar's "Zaručené konverzie" section: the five newest register rows by conversion
/// time, each named, numbered and in the Register's own EZZK state wording.
@MainActor
final class SidebarConversionRowsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z")!

    func testShowsTheFiveNewestByConversionTimeNotByWhenTheRowWasWritten() {
        // Written in the opposite order of their conversion times.
        let records = (0..<7).map { index in
            record(name: "Dokument \(index)",
                   createdAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                   conversionTime: now.addingTimeInterval(TimeInterval(index * 3600) - 24 * 3600))
        }
        let section = SidebarConversionRows.section(from: records, now: now)

        XCTAssertEqual(section.rows.map(\.name),
                       ["Dokument 6", "Dokument 5", "Dokument 4", "Dokument 3", "Dokument 2"])
        XCTAssertEqual(section.total, 7)
        XCTAssertTrue(section.hasMore)
        XCTAssertFalse(section.isEmpty)
    }

    func testSameConversionTimeFallsBackToTheNewerRow() {
        let older = record(name: "Starší", createdAt: now.addingTimeInterval(-60), conversionTime: now)
        let newer = record(name: "Novší", createdAt: now, conversionTime: now)
        let section = SidebarConversionRows.section(from: [older, newer], now: now)

        XCTAssertEqual(section.rows.map(\.name), ["Novší", "Starší"])
        XCTAssertFalse(section.hasMore, "two rows fit, so no \"Zobraziť všetky\"")
    }

    func testPendingStageOverridesSidebarState() {
        let waiting = record(name: "Čaká", status: .acceptedForProcessing)
        let ready = record(name: "Hotové", status: .processed)
        let failed = record(name: "Neodoslané", status: .submissionFailed)
        let section = SidebarConversionRows.section(
            from: [waiting, ready, failed], now: now,
            pendingStages: [waiting.id: .awaitingEZZK, ready.id: .signingClientContainer, failed.id: .awaitingEZZK])
        let rows = Dictionary(uniqueKeysWithValues: section.rows.map { ($0.name, $0) })

        XCTAssertEqual(rows["Čaká"]?.stateLabel, "Čaká na EZZK")
        XCTAssertEqual(rows["Čaká"]?.symbol, "hourglass")
        XCTAssertEqual(rows["Hotové"]?.stateLabel, "Čaká na podpis doložky")
        XCTAssertEqual(rows["Hotové"]?.pendingStage, .signingClientContainer)
        XCTAssertTrue(rows["Hotové"]?.accessibilityLabel.contains("Čaká na podpis doložky") == true)
        XCTAssertEqual(rows["Neodoslané"]?.stateLabel, UXLabels.evidenceStatusLabel(for: .submissionFailed),
                       "a failed send keeps the Register's own state")
    }

    func testWaitingConversionStaysPastTheNewestFive() {
        let old = record(name: "Starý", status: .processed, conversionTime: now.addingTimeInterval(-7 * 24 * 3600))
        let recent = (0..<5).map { record(name: "Nový \($0)", conversionTime: now.addingTimeInterval(TimeInterval(-$0 * 60))) }
        let section = SidebarConversionRows.section(from: recent + [old], now: now,
                                                    pendingStages: [old.id: .signingClientContainer])

        XCTAssertEqual(section.rows.count, 6)
        XCTAssertEqual(section.rows.last?.name, "Starý")
        XCTAssertEqual(section.total, 6)
    }

    func testEmptyRegisterHidesTheSection() {
        let section = SidebarConversionRows.section(from: [], now: now)
        XCTAssertTrue(section.isEmpty)
        XCTAssertTrue(section.rows.isEmpty)
        XCTAssertFalse(section.hasMore)
    }

    func testNameFallsBackToTheNewDocumentName() {
        XCTAssertEqual(SidebarConversionRows.displayName(for: record(name: "Zmluva")), "Zmluva")
        XCTAssertEqual(SidebarConversionRows.displayName(for: record(name: "  ", newName: "Zmluva.pdf")), "Zmluva.pdf")
        XCTAssertEqual(SidebarConversionRows.displayName(for: record(name: "", newName: "")), "Bez názvu")
    }

    func testMissingEvidenceNumberReadsLikeTheRegister() {
        let row = SidebarConversionRows.row(for: record(name: "Zmluva", number: nil), now: now)
        XCTAssertEqual(row.evidenceNumber, "nezískané")
    }

    func testEveryStateUsesTheRegistersWordingSymbolAndTone() {
        for status in EvidenceRecord.Status.allCases {
            // Converted just now, so no row is past its deadline.
            let row = SidebarConversionRows.row(for: record(name: "Zmluva", status: status), now: now)
            XCTAssertEqual(row.stateLabel, UXLabels.evidenceStatusLabel(for: status), "\(status)")
            XCTAssertEqual(row.symbol, status.sfSymbol, "\(status)")
            XCTAssertEqual(row.tone, EZZKRecordPresentation.tone(for: status), "\(status)")
            XCTAssertFalse(row.stateLabel.isEmpty, "\(status)")
        }
    }

    func testEZZKStatesTheAdvocateCaresAbout() {
        let expectations: [(EvidenceRecord.Status, String, EZZKRecordPresentation.Tone)] = [
            (.acceptedForProcessing, "Prijatý na spracovanie", .success),
            (.processed, "Spracovaný v EZZK", .success),
            (.rejected, "Odmietnutý v EZZK", .failure),
            (.outcomeUnknown, "Výsledok neznámy, najprv overte v EZZK", .warning),
            (.recordUnsigned, "Záznam nepodpísaný", .failure),
            (.late, "Oneskorený", .warning),
            (.queuedForSubmission, "Čaká na odoslanie", .pending),
            (.signed, "Podpísaný, čaká na odoslanie", .pending),
        ]
        for (status, label, tone) in expectations {
            let row = SidebarConversionRows.row(for: record(name: "Zmluva", status: status), now: now)
            XCTAssertEqual(row.stateLabel, label, "\(status)")
            XCTAssertEqual(row.tone, tone, "\(status)")
        }
    }

    func testOverdueRowSaysSoLikeTheRegisterUnlessItsStateSaysWhatToDo() {
        let dayAndAHourAgo = now.addingTimeInterval(-25 * 3600)
        let queued = SidebarConversionRows.row(
            for: record(name: "Zmluva", status: .queuedForSubmission, conversionTime: dayAndAHourAgo), now: now)
        XCTAssertEqual(queued.stateLabel, "Po lehote")
        XCTAssertEqual(queued.tone, .failure)
        XCTAssertEqual(queued.symbol, "clock.badge.exclamationmark")

        for status in [EvidenceRecord.Status.outcomeUnknown, .late] {
            let row = SidebarConversionRows.row(
                for: record(name: "Zmluva", status: status, conversionTime: dayAndAHourAgo), now: now)
            XCTAssertEqual(row.stateLabel, UXLabels.evidenceStatusLabel(for: status), "\(status)")
            XCTAssertEqual(row.symbol, status.sfSymbol, "\(status)")
        }

        let processed = SidebarConversionRows.row(
            for: record(name: "Zmluva", status: .processed, conversionTime: dayAndAHourAgo), now: now)
        XCTAssertEqual(processed.stateLabel, "Spracovaný v EZZK", "a processed row is never late")
    }

    func testAccessibilityLabelCarriesNameNumberAndState() {
        let row = SidebarConversionRows.row(for: record(name: "Zmluva", status: .rejected), now: now)
        XCTAssertEqual(row.accessibilityLabel,
                       "Zaručená konverzia Zmluva, evidenčné číslo 1563-260924-1, stav Odmietnutý v EZZK, prostredie Testovacia evidencia")
        let live = SidebarConversionRows.row(for: record(name: "Zmluva", status: .rejected, mode: .production), now: now)
        XCTAssertEqual(live.accessibilityLabel,
                       "Zaručená konverzia Zmluva, evidenčné číslo 1563-260924-1, stav Odmietnutý v EZZK")
    }

    func testEnvironmentBadgeBesideTheNumberNotInIt() {
        let test = SidebarConversionRows.row(for: record(name: "T"), now: now)
        XCTAssertEqual(test.evidenceNumber, "1563-260924-1")
        XCTAssertEqual(test.environmentBadge, "Test")

        let demo = SidebarConversionRows.row(for: record(name: "D", mode: .demo), now: now)
        XCTAssertEqual(demo.evidenceNumber, "1563-260924-1", "no suffix in the number")
        XCTAssertEqual(demo.environmentBadge, "Skúšobný")
        XCTAssertEqual(demo.stateLabel, "Skúšobný režim, mimo EZZK")

        let waitingDemo = SidebarConversionRows.row(for: record(name: "W", status: .acceptedForProcessing, mode: .demo),
                                                    now: now, pendingStage: .awaitingEZZK)
        XCTAssertEqual(waitingDemo.evidenceNumber, "1563-260924-1")
        XCTAssertEqual(waitingDemo.environmentBadge, "Skúšobný")

        XCTAssertNil(SidebarConversionRows.row(for: record(name: "P", mode: .production), now: now).environmentBadge)
        XCTAssertNil(SidebarConversionRows.row(for: record(name: "O", mode: nil), now: now).environmentBadge)
    }

    func testReadsTheRegisterRowsAsStored() {
        let settingsStore = makeSettingsStore()
        XCTAssertTrue(SidebarConversionRows.section(from: settingsStore.evidenceStore.records, now: now).isEmpty)

        let first = record(name: "Prvý", conversionTime: now.addingTimeInterval(-120))
        let second = record(name: "Druhý", status: .processed, conversionTime: now.addingTimeInterval(-60))
        settingsStore.evidenceStore.upsert(first)
        settingsStore.evidenceStore.upsert(second)

        let section = SidebarConversionRows.section(from: settingsStore.evidenceStore.records, now: now)
        XCTAssertEqual(section.rows.map(\.id), [second.id, first.id])
        XCTAssertEqual(section.rows.first?.stateLabel, "Spracovaný v EZZK")
    }

    private func record(name: String,
                        newName: String = "Zmluva.pdf",
                        number: String? = "1563-260924-1",
                        status: EvidenceRecord.Status = .queuedForSubmission,
                        createdAt: Date? = nil,
                        conversionTime: Date? = nil,
                        mode: AppSettings.EZZKMode? = .test) -> EvidenceRecord {
        EvidenceRecord(createdAt: createdAt ?? now, status: status, direction: .paperToElectronic,
                       originalName: name, newDocumentName: newName, evidenceNumber: number,
                       fingerprintSHA256Hex: "ab", attestationXML: "<x/>",
                       conversionTime: conversionTime ?? now, performingPersonName: "JUDr. Test Testovací",
                       securityElementCount: 0, totalPages: 1, totalSheets: 1, ezzkMode: mode)
    }
}
