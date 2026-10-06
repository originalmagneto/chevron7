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
    // MARK: ready-made containers and several documents

    private let xdcMime = "application/vnd.gov.sk.xmldatacontainer+xml;base64"

    private func severalDocuments(_ attachments: [WebSignAttachment], main: String = "priloha.pdf") -> WebSignRequest {
        WebSignRequest(requestID: "r", filename: main, content: Data("%PDF-1.4".utf8).base64EncodedString(),
                       payloadMimeType: "application/pdf;base64", signatureLevel: "XAdES_BASELINE_B",
                       container: "ASiC_E", attachments: attachments)
    }

    private func attachment(_ name: String, _ text: String = "x", mime: String = "text/plain;base64") -> WebSignAttachment {
        WebSignAttachment(filename: name, content: Data(text.utf8).base64EncodedString(), payloadMimeType: mime)
    }

    func testReadyMadeContainerIsDescribedAndArchivedAsAContainer() {
        let xdc = WebSignRequest(requestID: "r", filename: "form.xdcf", content: "",
                                 payloadMimeType: xdcMime, signatureLevel: "XAdES_BASELINE_B",
                                 container: "ASiC_E", eform: EFormSigningAttributes(embedUsedSchemas: true))
        XCTAssertEqual(WebSigningCoordinator.describeKind(xdc), "Hotový formulár (XML Data Container)")
        XCTAssertEqual(WebSigningCoordinator.archiveExtension(for: xdc), "asice")
        XCTAssertNil(WebSigningCoordinator.plainFileExtension(for: xdc))
    }

    func testAttachmentsKeepTheirNamesAndBytesInOrder() throws {
        let entries = try WebSigningCoordinator.attachmentEntries(
            for: severalDocuments([attachment("poznamka.txt", "Hello"), attachment("form.xdcf", "<x/>", mime: xdcMime)]))
        XCTAssertEqual(entries.map(\.path), ["poznamka.txt", "form.xdcf"])
        XCTAssertEqual(entries.first?.data, Data("Hello".utf8))
    }

    /// The engine writes every data object into one folder on a case-insensitive
    /// volume, and the provider skips an attachment named like the PDF, so a
    /// clash would silently drop a document from the signature.
    func testAttachmentNamesNeverClashWithThePdfOrEachOther() throws {
        let entries = try WebSigningCoordinator.attachmentEntries(
            for: severalDocuments([attachment("Priloha.pdf"), attachment("a.txt"), attachment("A.TXT"),
                                   attachment("a-2.txt")]))
        let names = entries.map(\.path)
        XCTAssertEqual(names, ["Priloha-2.pdf", "a.txt", "A-2.TXT", "a-2-2.txt"])
        XCTAssertEqual(Set(names.map { $0.lowercased() } + ["priloha.pdf"]).count, names.count + 1)
    }

    func testAttachmentNamesLoseAnyPathAndOddCharacters() throws {
        let entries = try WebSigningCoordinator.attachmentEntries(
            for: severalDocuments([attachment("../../etc/passwd.txt"), attachment("?*:")]))
        XCTAssertEqual(entries.map(\.path), ["passwd.txt", "priloha"])
    }

    /// The engine refuses the container's own entry names and compares names in NFC.
    func testReservedAndDecomposedNamesAreRenamedNotRefused() throws {
        let entries = try WebSigningCoordinator.attachmentEntries(
            for: severalDocuments([attachment("mimetype"), attachment("META-INF"),
                                   attachment("Pr\u{00ED}loha.txt"), attachment("Pri\u{0301}loha.txt")]))
        XCTAssertEqual(entries.map(\.path), ["mimetype-2", "META-INF-2", "Pr\u{00ED}loha.txt", "Pri\u{0301}loha-2.txt"])
    }

    func testUnreadableAttachmentIsRefused() {
        let broken = WebSignAttachment(filename: "a.txt", content: "%%%", payloadMimeType: "text/plain;base64")
        XCTAssertThrowsError(try WebSigningCoordinator.attachmentEntries(for: severalDocuments([broken])))
    }

    func testPhoneRefusesWhatTheRelayWasNeverShown() {
        XCTAssertNil(WebSigningCoordinator.mobileRefusal(
            for: request(filename: "dokument.pdf", mime: "application/pdf;base64")))
        XCTAssertNotNil(WebSigningCoordinator.mobileRefusal(
            for: request(filename: "poznamka.txt", mime: "text/plain;base64")))
        XCTAssertNotNil(WebSigningCoordinator.mobileRefusal(
            for: request(filename: "form.xdcf", mime: xdcMime, eform: true)))
        XCTAssertNotNil(WebSigningCoordinator.mobileRefusal(for: severalDocuments([attachment("a.txt")])))
    }
}
