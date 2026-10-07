// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

final class MacOS27UXContractTests: XCTestCase {
    private var packageURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: #filePath)
    }

    func testMacOS27DeploymentContract() throws {
        let package = try String(contentsOf: packageURL, encoding: .utf8)
        XCTAssertTrue(package.contains(".macOS(\"27.0\")"))
    }

    func testEvidenceStatusDoesNotDependOnTimerOnly() {
        XCTAssertEqual(EvidenceRecord.submissionDeadlineInterval, 24 * 3600)
    }

    /// The ZaKo form alone fits the narrowest detail column (smallest window, widest
    /// sidebar), and the preview appears only when the form keeps its minimum.
    func testClauseStepFitsTheNarrowestWindow() {
        let narrowestDetail = MacOS27Layout.rootMinimumWidth - 320
        XCTAssertLessThanOrEqual(MacOS27Layout.clauseFormMinimumWidth, narrowestDetail)
        XCTAssertFalse(MacOS27Layout.showsClausePreview(availableWidth: narrowestDetail))
        XCTAssertFalse(MacOS27Layout.showsClausePreview(
            availableWidth: MacOS27Layout.clauseFormMinimumWidth + MacOS27Layout.clausePreviewMinimumWidth))
        XCTAssertTrue(MacOS27Layout.showsClausePreview(availableWidth: 1100))
    }

    /// The root minimum is only a floor below the columns: with an inspector beside the
    /// canvas the window's minimum comes from the columns themselves (`MinimumSizeFloor`;
    /// the inspector never collapsed on its own, and a window narrower than its columns
    /// crashed in 1.4.3, see SigningWindowResizeTests).
    func testRootMinimumIsOnlyAFloorBelowTheColumns() {
        XCTAssertEqual(MacOS27Layout.inspectorMinimumWidth, 0)
        XCTAssertLessThan(
            MacOS27Layout.rootMinimumWidth,
            MacOS27Layout.canvasMinimumWidth + MacOS27Layout.inspectorIdealWidth)
    }
}
