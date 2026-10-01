// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

final class LiveEngineInspectionTests: XCTestCase {
    func testProviderInspectionDoesNotRequireTrustedList() async throws {
        guard ProcessInfo.processInfo.environment["CHEVRON7_ENGINE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Vyžaduje CHEVRON7_ENGINE_LIVE_TEST=1.")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-engine-inspection-\(UUID().uuidString).pdf")
        try TestPDFBuilder.singlePageWhitePDF().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await EngineBridgeSigningProvider().inspectInputSignatures(in: url)
        XCTAssertNotEqual(result.state, .unavailable, result.detail)
    }

    func testLiveEngineReturnsTheTreeOfAContainer() async throws {
        guard ProcessInfo.processInfo.environment["CHEVRON7_ENGINE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Vyžaduje CHEVRON7_ENGINE_LIVE_TEST=1.")
        }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "engine/src/test/resources/digital/slovensko/autogram/sample_pdf_xades.asice")
        let result = await EngineBridgeSigningProvider().inspectSignatureTree(in: fixture)

        guard case .tree(let tree) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(tree.signatures.count, 1)
        XCTAssertEqual(tree.documents.map(\.name), ["sample.pdf"])
        guard case .signed(.pdf, let nested) = tree.documents[0].content else {
            return XCTFail("sample.pdf should be inspected as a PDF")
        }
        XCTAssertTrue(nested.signatures.isEmpty)
    }
}
