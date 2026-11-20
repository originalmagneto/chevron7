// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

/// The authorize step's "Čo podpíšete" and the done step's summary: which layout a size gets,
/// what the client's files are called, and what the summary lists.
final class ZakoDeliveryPreviewTests: XCTestCase {
    private let a4: CGFloat = 595.0 / 842.0

    func testWideWindowPutsTheFilesBesideThePage() throws {
        let columns = try XCTUnwrap(ZakoAuthorizeLayout.columns(for: CGSize(width: 1775, height: 930), pageAspect: a4))
        XCTAssertTrue(columns.planBesidePage)
        XCTAssertLessThanOrEqual(columns.previewWidth + columns.detailsWidth, 1775)
        XCTAssertGreaterThanOrEqual(columns.detailsWidth, ZakoAuthorizeLayout.minDetailsWidth)
    }

    func testSmallOrShortAreasKeepOneColumn() {
        XCTAssertNil(ZakoAuthorizeLayout.columns(for: CGSize(width: 1000, height: 150), pageAspect: a4))
        XCTAssertNil(ZakoAuthorizeLayout.columns(for: CGSize(width: 600, height: 900), pageAspect: a4))
        XCTAssertNil(ZakoAuthorizeLayout.columns(for: CGSize(width: 1500, height: 900), pageAspect: 0))
    }

    func testMiddleWidthsPutTheFilesBelowThePage() throws {
        let columns = try XCTUnwrap(ZakoAuthorizeLayout.columns(for: CGSize(width: 1000, height: 900), pageAspect: a4))
        XCTAssertFalse(columns.planBesidePage)
        XCTAssertGreaterThanOrEqual(columns.detailsWidth, ZakoAuthorizeLayout.minDetailsWidth)
    }

    func testPlanNamesOnlyWhatIsCertain() {
        let container = ZakoDeliveryPlan.make(output: .asicContainer, documentName: "Zmluva.pdf",
                                              clauseName: nil, containerName: nil)
        XCTAssertEqual(container.items.map(\.title), ["Súbor .asice", "Zmluva.pdf", "Osvedčovacia doložka v XML"])
        XCTAssertEqual(container.items.map(\.indented), [false, true, true])

        let single = ZakoDeliveryPlan.make(output: .singlePDF, documentName: "Zmluva.pdf",
                                           clauseName: "261120-TEST000001.xml.xdcf", containerName: nil)
        XCTAssertEqual(single.items.map(\.title), ["Zmluva.pdf", "Osvedčovacia doložka", "261120-TEST000001.xml.xdcf"])
        XCTAssertEqual(single.outputLabel, "Jeden PDF s doložkou")
    }

    func testSummaryListsTheRowAndNothingWithoutOne() throws {
        XCTAssertNil(ZakoDoneSummary.make(pending: nil, record: nil, evidenceNumber: nil, outputDirectory: nil))

        var row = EvidenceRecord(id: UUID(), createdAt: Date(), status: .processed, direction: .paperToElectronic,
                                 originalName: "Zmluva.pdf",
                                 newDocumentName: "Zmluva.pdf", evidenceNumber: "261120-TEST000001",
                                 fingerprintSHA256Hex: "ab", attestationXML: "<x/>", conversionTime: Date(),
                                 performingPersonName: "Mgr. Test", securityElementCount: 0, totalPages: 1,
                                 totalSheets: 1, ezzkMode: .test, clientOutput: .asicContainer)
        row.deliveredFileName = "Zmluva.asice"
        row.submittedAt = Date()
        let summary = try XCTUnwrap(ZakoDoneSummary.make(pending: nil, record: row, evidenceNumber: nil,
                                                         outputDirectory: URL(fileURLWithPath: "/tmp/out")))
        XCTAssertEqual(summary.rows.map(\.id), ["document", "number", "output", "delivered", "environment", "sent"])
        XCTAssertEqual(summary.mode, .test)
        XCTAssertEqual(summary.folder, "/tmp/out")
    }
}
