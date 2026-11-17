// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7TestSupport
@testable import Chevron7Kit

final class PdfClauseCheckRunnerTests: XCTestCase {
    private let clause = AppendedClause(pages: TestPDFBuilder.singlePageWhitePDF(),
                                        attachment: Data("<x/>".utf8), attachmentName: "n.xml.xdcf")

    func testCheckMapsExitCodes() throws {
        let source = TestPDFBuilder.singlePageWhitePDF()
        let seen = LockedArguments()
        let ok = PdfClauseCheckRunner(launch: { arguments in seen.set(arguments); return (0, "") })
        try ok.check(source: source, clause: clause)
        let arguments = seen.get()
        XCTAssertEqual(arguments.first, "digital.slovensko.autogram.core.PdfClauseAppender")
        XCTAssertEqual(Array(arguments.suffix(2)), ["n.xml.xdcf", AppendedClause.xdcMimeType])
        XCTAssertEqual(arguments.count, 6)

        let bad = PdfClauseCheckRunner(launch: { _ in (3, "rule 1\nrule 2\n") })
        XCTAssertThrowsError(try bad.check(source: source, clause: clause)) {
            XCTAssertEqual($0 as? PdfClauseCheckRunner.Failure, .notCompliant(["rule 1", "rule 2"]))
        }
        let unreadable = PdfClauseCheckRunner(launch: { _ in (2, "") })
        XCTAssertThrowsError(try unreadable.check(source: source, clause: clause)) {
            XCTAssertEqual($0 as? PdfClauseCheckRunner.Failure, .unreadable)
        }
        let other = PdfClauseCheckRunner(launch: { _ in (1, "") })
        XCTAssertThrowsError(try other.check(source: source, clause: clause)) {
            XCTAssertEqual($0 as? PdfClauseCheckRunner.Failure, .failed)
        }
    }
}

private final class LockedArguments: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    func set(_ new: [String]) { lock.lock(); value = new; lock.unlock() }
    func get() -> [String] { lock.lock(); defer { lock.unlock() }; return value }
}
