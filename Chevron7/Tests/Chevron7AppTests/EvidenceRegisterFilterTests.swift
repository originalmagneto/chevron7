// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

/// The Register's environment filter beside the status filter and the search.
final class EvidenceRegisterFilterTests: XCTestCase {
    private let production = record(name: "Ostrá", mode: .production)
    private let test = record(name: "Testovacia", mode: .test, status: .rejected)
    private let demo = record(name: "Skúšobná", mode: .demo)
    private let old = record(name: "Stará", mode: nil)

    private var all: [EvidenceRecord] { [production, test, demo, old] }

    private func names(_ environment: EvidenceRegisterFilter.Environment,
                       status: EvidenceRecord.Status? = nil, text: String = "") -> [String] {
        EvidenceRegisterFilter.apply(all, status: status, environment: environment, text: text).map(\.originalName)
    }

    func testEachEnvironmentShowsOnlyItsRows() {
        XCTAssertEqual(names(.all), ["Ostrá", "Testovacia", "Skúšobná", "Stará"])
        XCTAssertEqual(names(.production), ["Ostrá"])
        XCTAssertEqual(names(.test), ["Testovacia"])
        XCTAssertEqual(names(.demo), ["Skúšobná"])
    }

    func testARowWithoutAStoredModeMatchesOnlyAllEnvironments() {
        for environment in EvidenceRegisterFilter.Environment.allCases where environment != .all {
            XCTAssertFalse(names(environment).contains("Stará"), "\(environment)")
        }
    }

    func testCombinesWithStatusAndSearch() {
        XCTAssertEqual(names(.test, status: .rejected), ["Testovacia"])
        XCTAssertEqual(names(.production, status: .rejected), [])
        XCTAssertEqual(names(.all, text: "skúšob"), ["Skúšobná"])
        XCTAssertEqual(names(.demo, text: "ostrá"), [])
    }

    func testEnvironmentCountsAsAnActiveFilter() {
        XCTAssertFalse(EvidenceRegisterFilter.isActive(status: nil, environment: .all, text: "  "))
        XCTAssertTrue(EvidenceRegisterFilter.isActive(status: nil, environment: .test, text: ""))
        XCTAssertTrue(EvidenceRegisterFilter.isActive(status: .processed, environment: .all, text: ""))
    }

    func testLabels() {
        XCTAssertEqual(EvidenceRegisterFilter.Environment.allCases.map(\.label),
                       ["Všetky prostredia", "Ostrá evidencia", "Testovacia evidencia", "Skúšobný režim"])
    }

    private static func record(name: String, mode: AppSettings.EZZKMode?,
                               status: EvidenceRecord.Status = .processed) -> EvidenceRecord {
        EvidenceRecord(status: status, direction: .paperToElectronic,
                       originalName: name, newDocumentName: name + ".pdf", evidenceNumber: "1563-260924-1",
                       fingerprintSHA256Hex: "ab", attestationXML: "<x/>",
                       conversionTime: Date(), performingPersonName: "JUDr. Test Testovací",
                       securityElementCount: 0, totalPages: 1, totalSheets: 1, ezzkMode: mode)
    }
}
