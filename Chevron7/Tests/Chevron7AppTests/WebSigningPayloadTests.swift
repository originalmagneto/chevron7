// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

/// Plain TXT/PNG payloads from `ditec.js` must never be mistaken for PDF:
/// the mobile path has no correct MIME for them and the card path names the
/// engine source from the filename extension.
final class WebSigningPayloadTests: XCTestCase {
    private func request(filename: String, mime: String, eform: Bool = false) -> WebSignRequest {
        WebSignRequest(requestID: "r", filename: filename, content: "",
                       payloadMimeType: mime, signatureLevel: "XAdES_BASELINE_B",
                       container: "ASiC_E",
                       eform: eform ? EFormSigningAttributes(containerXmlns: "urn:x") : nil)
    }

    func testPlainExtensionFromFilename() {
        XCTAssertEqual(WebSigningCoordinator.plainFileExtension(
            for: request(filename: "poznamka.txt", mime: "text/plain;base64")), "txt")
        XCTAssertEqual(WebSigningCoordinator.plainFileExtension(
            for: request(filename: "obrazok.png", mime: "image/png;base64")), "png")
    }

    func testPlainExtensionFromMimeWhenNameLies() {
        XCTAssertEqual(WebSigningCoordinator.plainFileExtension(
            for: request(filename: "dokument", mime: "text/plain;base64")), "txt")
        XCTAssertEqual(WebSigningCoordinator.plainFileExtension(
            for: request(filename: "dokument", mime: "image/png;base64")), "png")
    }

    func testPdfAndEformAreNotPlain() {
        XCTAssertNil(WebSigningCoordinator.plainFileExtension(
            for: request(filename: "dokument.pdf", mime: "application/pdf;base64")))
        XCTAssertNil(WebSigningCoordinator.plainFileExtension(
            for: request(filename: "formular.xml", mime: "application/xml;base64", eform: true)))
    }

    func testArchiveExtension() {
        XCTAssertEqual(WebSigningCoordinator.archiveExtension(
            for: request(filename: "poznamka.txt", mime: "text/plain;base64")), "asice")
        XCTAssertEqual(WebSigningCoordinator.archiveExtension(
            for: request(filename: "obrazok.png", mime: "image/png;base64")), "asice")
        let plain = WebSignRequest(requestID: "r", filename: "poznamka.txt", content: "",
                                   payloadMimeType: "text/plain;base64",
                                   signatureLevel: "PAdES_BASELINE_B")
        XCTAssertEqual(WebSigningCoordinator.archiveExtension(for: plain), "txt")
        XCTAssertEqual(WebSigningCoordinator.archiveExtension(
            for: request(filename: "dokument.pdf", mime: "application/pdf;base64")), "asice")
    }

    func testDescribeKindLabels() {
        XCTAssertEqual(WebSigningCoordinator.describeKind(
            request(filename: "poznamka.txt", mime: "text/plain;base64")), "Textový dokument (TXT)")
        XCTAssertEqual(WebSigningCoordinator.describeKind(
            request(filename: "obrazok.png", mime: "image/png;base64")), "Obrázok (PNG)")
        XCTAssertEqual(WebSigningCoordinator.describeKind(
            request(filename: "dokument.pdf", mime: "application/pdf;base64")), "Dokument PDF")
    }

    func testOnlyAClosedPromptCountsAsCancellation() {
        // The page hears a cancellation as ERROR_CANCELLED and closes its waiting modal.
        XCTAssertTrue(WebSigningCoordinator.isCancellation(WebSigningCoordinator.Failure.cancelled))
        XCTAssertFalse(WebSigningCoordinator.isCancellation(WebSigningCoordinator.Failure.busy))
        XCTAssertFalse(WebSigningCoordinator.isCancellation(CancellationError()))
    }
}
