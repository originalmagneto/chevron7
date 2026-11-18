// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import PDFKit
import XCTest
import Chevron7TestSupport
@testable import Chevron7Kit

final class ClausePresentationRendererTests: XCTestCase {
    private static let a4 = CGSize(width: 595, height: 842)

    override func setUpWithError() throws {
        for tool in ["/usr/bin/xmllint", "/usr/bin/xsltproc"] where !FileManager.default.isExecutableFile(atPath: tool) {
            throw XCTSkip("\(tool) is needed to build and present the clause.")
        }
    }

    // MARK: - Tests

    @MainActor
    func testRendersP2EClauseOnA4() async throws {
        let clause = try Self.p2eClause(finalPDF: Data("%PDF-1.7 synthetic delivered bytes".utf8))
        let pdf = try await ClausePresentationRenderer().render(clauseXML: Data(clause.clauseXML.utf8), form: .clause_1_3)

        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        Self.assertEveryPageIsA4(document)
        let text = Self.text(of: document)
        XCTAssertTrue(text.contains("Osvedčovacia doložka"), text)
        XCTAssertTrue(text.contains("1563-260824-1"), text)
    }

    @MainActor
    func testRendersE2EClauseOnA4() async throws {
        let clause = try E2EDeliveryBuilder().clause(try Self.e2eModel(signatureCount: 1, timestampCount: 1))
        let pdf = try await ClausePresentationRenderer().render(clauseXML: Data(clause.xml.utf8), form: .clauseE2E_1_3)

        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        Self.assertEveryPageIsA4(document)
        let text = Self.text(of: document)
        XCTAssertTrue(text.contains("Osvedčovacia doložka"), text)
        XCTAssertTrue(text.contains("1563-261016-7"), text)
    }

    @MainActor
    func testLongClauseIsPaginatedWithDiacritics() async throws {
        let clause = try E2EDeliveryBuilder().clause(try Self.e2eModel(signatureCount: 6, timestampCount: 4,
                                                                        office: Self.longOffice))
        let pdf = try await ClausePresentationRenderer().render(clauseXML: Data(clause.xml.utf8), form: .clauseE2E_1_3)

        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertGreaterThanOrEqual(document.pageCount, 2)
        Self.assertEveryPageIsA4(document)
        let text = Self.text(of: document)
        XCTAssertTrue(text.contains("Čuprík"), text)
        XCTAssertTrue(text.contains("kancelária"), text)
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            // The print margins (36 pt) leave the text inside this box; a row WebKit cut at a page
            // break would reach into the margin or past the page edge.
            let printable = page.bounds(for: .mediaBox).insetBy(dx: 30, dy: 30)
            // The last glyph the page draws, i.e. its last line.
            let last = try XCTUnwrap(
                (0..<page.numberOfCharacters).reversed().lazy.map { page.characterBounds(at: $0) }.first { !$0.isEmpty },
                "page \(index + 1) has no text")
            XCTAssertTrue(printable.contains(last), "page \(index + 1): last character \(last) outside \(printable)")
            for offset in 0..<page.numberOfCharacters {
                let glyph = page.characterBounds(at: offset)
                guard !glyph.isEmpty, !glyph.isNull else { continue }
                XCTAssertTrue(printable.contains(glyph), "page \(index + 1): glyph \(offset) \(glyph) outside \(printable)")
            }
        }
    }

    @MainActor
    func testRendersWithoutNetwork() async throws {
        // The rule list the web view runs under blocks every URL.
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(ClausePresentationRenderer.blockEverythingRules.utf8)) as? [[String: [String: String]]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?["trigger"]?["url-filter"], ".*")
        XCTAssertEqual(rules.first?["action"]?["type"], "block")

        // A clause still renders completely, so nothing it needs comes from the network.
        let clause = try Self.p2eClause(finalPDF: Data("%PDF-1.7 offline".utf8))
        let pdf = try await ClausePresentationRenderer().render(clauseXML: Data(clause.clauseXML.utf8), form: .clause_1_3)
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertTrue(Self.text(of: document).contains("Osvedčovacia doložka"))
    }

    func testTransformFailureCarriesXsltprocMessage() async throws {
        let renderer = ClausePresentationRenderer()
        do {
            _ = try await renderer.render(clauseXML: Data("<not-closed>".utf8), form: .clause_1_3)
            XCTFail("broken XML must not render")
        } catch let error as ClausePresentationError {
            guard case .transformFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(error.errorDescription?.hasPrefix("Osvedčovaciu doložku sa nepodarilo vykresliť: ") == true)
        }
    }

    @MainActor
    func testHungLoadFailsAfterTheTimeout() async throws {
        let stages = ClausePrintStages(load: { _, _ in }, print: ClausePrintStages.webKit.print)
        try await assertTimesOut(ClausePresentationRenderer(loadTimeout: .milliseconds(300), stages: stages))
    }

    @MainActor
    func testHungPrintFailsAfterTheTimeout() async throws {
        // The real load keeps the default 60 s, so only the print stage can time out; the print
        // operation never calls back, as when the web content process dies mid-print.
        let stages = ClausePrintStages(load: ClausePrintStages.webKit.load, print: { _, _, _ in })
        try await assertTimesOut(ClausePresentationRenderer(printTimeout: .milliseconds(500), stages: stages))
    }

    @MainActor
    func testLateCallbackAfterTimeoutFindsItsPrintAliveAndReleasesIt() async throws {
        final class Captured: @unchecked Sendable {
            weak var completion: PrintCompletion?
            weak var window: NSWindow?
        }
        let captured = Captured()
        let stages = ClausePrintStages(load: ClausePrintStages.webKit.load, print: { _, window, completion in
            captured.completion = completion
            captured.window = window
        })
        try await assertTimesOut(ClausePresentationRenderer(printTimeout: .milliseconds(300), stages: stages))

        // The render gave up, yet everything the print thread may still touch is alive.
        let completion = try XCTUnwrap(captured.completion)
        XCTAssertNotNil(captured.window)
        XCTAssertTrue(completion.holdsPrint)

        // A late callback is safe and releases the print once the main queue tears the window down.
        completion.printOperationDidRun(NSPrintOperation(view: NSView()), success: true, contextInfo: nil)
        XCTAssertFalse(completion.holdsPrint)
        await Task.yield()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertNil(captured.window)
    }

    func testFileErrorsBecomeTransformFailures() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try ClausePresentationRenderer().transform(
            clauseXML: Data("<a/>".utf8), stylesheet: OfficialForm.clause_1_3.presentation, in: missing)) { error in
            guard case .transformFailed(let message)? = error as? ClausePresentationError else {
                return XCTFail("unmapped \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testMissingXsltprocIsATransformFailure() async throws {
        let renderer = ClausePresentationRenderer(xsltproc: URL(fileURLWithPath: "/nonexistent/xsltproc"))
        do {
            _ = try await renderer.render(clauseXML: Data("<a/>".utf8), form: .clause_1_3)
            XCTFail("a missing xsltproc must not render")
        } catch let error as ClausePresentationError {
            guard case .transformFailed = error else { return XCTFail("\(error)") }
        }
    }

    @MainActor
    private func assertTimesOut(_ renderer: ClausePresentationRenderer,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let clause = try Self.p2eClause(finalPDF: Data("%PDF-1.7 hung".utf8))
        let started = ContinuousClock.now
        do {
            _ = try await renderer.render(clauseXML: Data(clause.clauseXML.utf8), form: .clause_1_3)
            XCTFail("a hung render must fail", file: file, line: line)
        } catch let error as ClausePresentationError {
            XCTAssertEqual(error, .printFailed, file: file, line: line)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(20), file: file, line: line)
    }

    // MARK: - Engine fixtures

    /// Writes the fixtures the engine's clause appender tests read. Run once with
    /// `CHEVRON7_WRITE_FIXTURES=1` (and `CHEVRON7_JAVA_ENGINE_ROOT` pointing at a built engine's
    /// `Contents` for the PDF/A normalizer), then commit the files.
    @MainActor
    func testWriteEngineFixtures() async throws {
        guard ProcessInfo.processInfo.environment["CHEVRON7_WRITE_FIXTURES"] == "1" else {
            throw XCTSkip("Set CHEVRON7_WRITE_FIXTURES=1 to write the engine fixtures.")
        }
        try await writeEngineFixtures()
    }

    @MainActor
    private func writeEngineFixtures() async throws {
        guard JavaEngineLocator().locate() != nil else {
            throw XCTSkip("The bundled engine is needed for normalizeForDelivery; set CHEVRON7_JAVA_ENGINE_ROOT.")
        }
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Chevron7KitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Chevron7
            .deletingLastPathComponent() // repository
            .appendingPathComponent("engine/src/test/resources/digital/slovensko/autogram/core", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), directory.path)

        let source = try XCTUnwrap(PDFDocument(data: Self.oneImagePagePDF()))
        let attestation = ConversionFormModelTests.attestation()
        let converter = PDFAConverter()
        let pdfa = try converter.convert(document: source, mode: .vectorPreserving, title: attestation.newDocumentName)
        let finalPDF = try converter.normalizeForDelivery(pdfa, title: attestation.newDocumentName)

        let p2e = try Self.p2eClause(finalPDF: finalPDF)
        let p2ePages = try await ClausePresentationRenderer().render(clauseXML: Data(p2e.clauseXML.utf8), form: .clause_1_3)
        let e2e = try E2EDeliveryBuilder().clause(try Self.e2eModel(signatureCount: 6, timestampCount: 4,
                                                                     office: Self.longOffice))
        let e2ePages = try await ClausePresentationRenderer().render(clauseXML: Data(e2e.xml.utf8), form: .clauseE2E_1_3)

        try finalPDF.write(to: directory.appendingPathComponent("zako-p2e-final.pdf"))
        try p2e.clauseXDCF.write(to: directory.appendingPathComponent("clause-p2e.xdcf"))
        try p2ePages.write(to: directory.appendingPathComponent("clause-pages-p2e.pdf"))
        try e2ePages.write(to: directory.appendingPathComponent("clause-pages-e2e.pdf"))
    }

    // MARK: - Fixtures

    private static let longOffice = "Advokátska kancelária Čuprík, s. r. o."

    private static func p2eClause(finalPDF: Data) throws -> ZakoClauseDelivery {
        try ZakoClauseDeliveryBuilder().build(
            finalPDF: finalPDF, attestation: ConversionFormModelTests.attestation(),
            securityElements: [ConversionFormModelTests.scanElement()],
            originalNonEmptyPageIndices: [0], usedDevice: "Chevron7 v0.5.0")
    }

    private static func e2eModel(signatureCount: Int, timestampCount: Int,
                                 office: String = "Advokátska kancelária CHZ") throws -> E2EFormModel {
        let sourcePDF = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x42, count: 300)
        let signatures = (1...signatureCount).map { number -> E2EEvidenceFixtures.Signature in
            var signature = E2EEvidenceFixtures.Signature()
            signature.id = "S-\(number)"
            signature.signer = "Ján Klient \(number)"
            signature.signedRevisionLength = sourcePDF.count
            signature.mandate = "1042 OPRÁVNENIE 1042"
            signature.mandants = ["MANDANT Kancelária & synovia s.r.o."]
            signature.signatureValue = Data("signature-value-\(number)".utf8)
            signature.timestamps = (1...timestampCount).map { index in
                var timestamp = E2EEvidenceFixtures.Timestamp()
                timestamp.id = "T-\(number)-\(index)"
                return timestamp
            }
            return signature
        }
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: signatures))
        let original = try ElectronicOriginal.make(sourceName: "zmluva.pdf", sourceData: sourcePDF, evidence: evidence)
        var attestation = AttestationData(
            originalDocumentName: "zmluva.pdf",
            numberOfSheets: 1,
            nonEmptyPageCount: 1,
            paperSizeBreakdown: [],
            newDocumentName: "zmluva.pdf",
            conversionExecutionDateTime: ISO8601DateFormatter().date(from: "2026-10-16T10:15:42Z")!,
            evidenceNumber: "1563-261016-7",
            performingPerson: AdvocateProfile(fullName: "Mgr. Marián Čuprík", position: "advokát",
                                              registrationNumber: "1042", ico: "42249180",
                                              officeName: office))
        attestation.originalDocumentTypeLabel = "zmluva o pôžičke"
        return try E2EFormModel.make(original: original, attestation: attestation, newDocumentName: "zmluva.pdf",
                                     newDocumentData: Data("%PDF-converted".utf8), usedDevice: "Chevron7 1.5.0",
                                     qualifiedReport: nil)
    }

    /// One A4 page holding a drawn raster image, as a scanned original arrives.
    private static func oneImagePagePDF() -> Data {
        let image = NSImage(size: NSSize(width: 595, height: 842), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.5, alpha: 1).setFill()
            NSRect(x: 60, y: 600, width: 475, height: 120).fill()
            NSColor.darkGray.setFill()
            for row in 0..<20 {
                NSRect(x: 60, y: 540 - row * 22, width: row % 3 == 2 ? 300 : 475, height: 8).fill()
            }
            return true
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1240, pixelsHigh: 1754,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let scan = NSImage(size: image.size)
        scan.addRepresentation(bitmap)
        let document = PDFDocument()
        document.insert(PDFPage(image: scan)!, at: 0)
        return document.dataRepresentation()!
    }

    // MARK: - Helpers

    private static func text(of document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    private static func assertEveryPageIsA4(_ document: PDFDocument, file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<document.pageCount {
            guard let box = document.page(at: index)?.bounds(for: .mediaBox) else {
                return XCTFail("page \(index + 1) missing", file: file, line: line)
            }
            XCTAssertEqual(box.width, a4.width, accuracy: 1, "page \(index + 1) width", file: file, line: line)
            XCTAssertEqual(box.height, a4.height, accuracy: 1, "page \(index + 1) height", file: file, line: line)
        }
    }
}
