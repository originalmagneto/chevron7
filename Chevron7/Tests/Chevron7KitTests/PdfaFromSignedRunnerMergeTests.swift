// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class PdfaFromSignedRunnerMergeTests: XCTestCase {
    private final class Captured: @unchecked Sendable {
        var arguments: [String] = []
        var inputs: [Data] = []
    }

    func testMergeArgumentsAndOrder() throws {
        let captured = Captured()
        let runner = PdfaFromSignedRunner(launch: { arguments in
            captured.arguments = arguments
            let pairs = arguments.dropFirst(5)
            var index = pairs.startIndex
            while index < pairs.endIndex {
                if pairs[index] == "--raster" { index += 1; continue }
                captured.inputs.append(try Data(contentsOf: URL(fileURLWithPath: pairs[index])))
                index += 2
            }
            try Data("%PDF-merged".utf8).write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        let out = try runner.merge([(Data("one".utf8), "a.pdf"), (Data("two".utf8), "priloha č. 2.png")],
                                   title: "Spis", raster: true)
        XCTAssertEqual(out, Data("%PDF-merged".utf8))
        let a = captured.arguments
        XCTAssertEqual(a[0], "digital.slovensko.autogram.core.PdfaFromSigned")
        XCTAssertEqual(a[1], "--merge")
        XCTAssertEqual(a[3], PDFAConverter.sRGBProfileSystemPath)
        XCTAssertEqual(a[4], "Spis")
        XCTAssertEqual(a[5], "--raster")
        XCTAssertEqual(a[7], "a.pdf")
        XCTAssertEqual(a[9], "priloha č. 2.png")
        XCTAssertEqual(captured.inputs, [Data("one".utf8), Data("two".utf8)])
        XCTAssertFalse(a[6].contains("a.pdf"))
    }

    func testMergeWithoutRasterAndEmptyTitle() throws {
        let captured = Captured()
        let runner = PdfaFromSignedRunner(launch: { arguments in
            captured.arguments = arguments
            try Data("x".utf8).write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        _ = try runner.merge([(Data("one".utf8), "a.pdf")], title: "", raster: false)
        XCTAssertEqual(captured.arguments[4], "Dokument")
        XCTAssertEqual(captured.arguments.count, 7)
        XCTAssertEqual(captured.arguments[6], "a.pdf")
    }

    func testMergeMapsExitCodes() {
        let inputs = [(Data("one".utf8), "a.pdf")]
        XCTAssertThrowsError(try PdfaFromSignedRunner(launch: { _ in (3, "font a\nfont b\n") })
            .merge(inputs, title: "Spis", raster: false)) {
            XCTAssertEqual($0 as? PdfaFromSignedRunner.Failure, .notCompliant(["font a", "font b"]))
        }
        XCTAssertThrowsError(try PdfaFromSignedRunner(launch: { _ in (2, "") })
            .merge(inputs, title: "Spis", raster: false)) {
            XCTAssertEqual($0 as? PdfaFromSignedRunner.Failure, .unreadable)
        }
        XCTAssertThrowsError(try PdfaFromSignedRunner(launch: { _ in (1, "") })
            .merge(inputs, title: "Spis", raster: false)) {
            XCTAssertEqual($0 as? PdfaFromSignedRunner.Failure, .failed)
        }
    }

    func testMergeRefusesNoInputs() {
        XCTAssertThrowsError(try PdfaFromSignedRunner(launch: { _ in (0, "") }).merge([], title: "Spis", raster: false))
    }
}
