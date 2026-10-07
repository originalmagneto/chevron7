// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit

@MainActor
final class WebSigningSignatureCheckTests: XCTestCase {
    private static let signed = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "Ján Novák", state: .indeterminate)])
    private static let signedPDF = Data("%PDF-1.7\n1 0 obj << /Type /Sig /ByteRange [0 10 20 30] >> endobj\n%%EOF".utf8)
    private static let unsignedPDF = Data("%PDF-1.7\n%%EOF".utf8)

    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("web-check-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func files(in root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".pdf") || $0.hasSuffix(".asice") }
    }

    func testOnlySignedPDFsAndContainersAreInspected() {
        XCTAssertTrue(WebSigningSignatureCheck.inspects(fileName: "a.pdf", data: Self.signedPDF))
        XCTAssertFalse(WebSigningSignatureCheck.inspects(fileName: "a.pdf", data: Self.unsignedPDF))
        XCTAssertFalse(WebSigningSignatureCheck.inspects(fileName: "form.xml", data: Data("<a/>".utf8)))
    }

    func testUnsignedDocumentStartsNothingAndLeavesNoFile() async {
        let provider = TreeProvider(inspect: .tree(Self.signed), validate: .tree(Self.signed))
        let root = root()
        let check = WebSigningSignatureCheck(temporaryRoot: root)
        check.start(fileName: "a.pdf", data: Self.unsignedPDF, provider: provider)
        XCTAssertNil(check.loader)
        XCTAssertNil(check.loadTask)
        XCTAssertNil(check.bannerModel)
        XCTAssertEqual(files(in: root), [])
    }

    func testSignedDocumentShowsCheckingBannerAndStopCleansUp() async throws {
        let provider = TreeProvider(inspect: .tree(Self.signed), validate: .tree(Self.signed))
        let root = root()
        let check = WebSigningSignatureCheck(temporaryRoot: root)
        check.start(fileName: "zmluva.pdf", data: Self.signedPDF, provider: provider)
        await check.loadTask?.value
        XCTAssertEqual(check.bannerModel?.tone, .checking)
        XCTAssertEqual(files(in: root).count, 1)
        let validation = try XCTUnwrap(check.loader?.validationTask)

        check.stop()

        XCTAssertTrue(validation.isCancelled)
        XCTAssertNil(check.bannerModel)
        XCTAssertEqual(files(in: root), [])
        await provider.releaseValidation()
    }

    /// A panel closed right after it opened: the load that had not run yet does nothing,
    /// and neither a loader nor a file is left behind.
    func testStopRightAfterStartLeavesNothing() async throws {
        let provider = TreeProvider(inspect: .tree(Self.signed), validate: .tree(Self.signed))
        let root = root()
        let check = WebSigningSignatureCheck(temporaryRoot: root)
        check.start(fileName: "zmluva.pdf", data: Self.signedPDF, provider: provider)
        let load = try XCTUnwrap(check.loadTask)
        check.stop()
        await load.value
        XCTAssertNil(check.loader)
        XCTAssertNil(check.bannerModel)
        XCTAssertEqual(files(in: root), [])
        XCTAssertEqual(provider.validateCalls, 0)
    }
}
