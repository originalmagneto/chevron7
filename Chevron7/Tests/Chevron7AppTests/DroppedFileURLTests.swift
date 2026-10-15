// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import UniformTypeIdentifiers
@testable import Chevron7App

/// A dropped document must keep its own location and name, so the signed output
/// lands next to the original instead of in a temporary directory under a
/// generated name.
///
/// SwiftUI's `onDrop(of:)` hands over a provider that registers only the first
/// declared type the drag matches (`com.adobe.pdf` for a PDF from Finder), never
/// `public.file-url`, even when `.fileURL` is in the list. Measured on 2026-10-15
/// with a real Finder pasteboard: `loadItem(forTypeIdentifier: public.file-url)`
/// fails there, while `loadInPlaceFileRepresentation` returns the original path.
/// The providers below are built in that shape.
final class DroppedFileURLTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroppedFileURLTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSource(named name: String) throws -> URL {
        let folder = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("%PDF-1.7 test".utf8).write(to: url)
        return url
    }

    private func provider(handing url: URL, inPlace: Bool,
                          type: UTType = .pdf) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                            fileOptions: inPlace ? [.openInPlace] : [],
                                            visibility: .all) { done in
            done(url, inPlace, nil)
            return nil
        }
        return provider
    }

    private func load(_ provider: NSItemProvider, type: UTType = .pdf) -> URL? {
        let done = expectation(description: "dropped file")
        let box = ResultBox()
        DroppedFileURL.load(from: provider,
                            typeIdentifier: type.identifier,
                            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)) { url in
            box.url = url
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return box.url
    }

    /// Finder's drop as SwiftUI hands it over: only the PDF type, in place.
    func testFinderDropResolvesToTheOriginalFile() throws {
        let source = try makeSource(named: "Dohoda s klientom.pdf")
        let provider = provider(handing: source, inPlace: true)
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))

        XCTAssertEqual(load(provider)?.standardizedFileURL, source.standardizedFileURL)
    }

    func testContainerDropResolvesToTheOriginalFile() throws {
        let type = ContainerFileTypes.asice[0]
        let source = try makeSource(named: "zmluva.asice")

        XCTAssertEqual(load(provider(handing: source, inPlace: true, type: type), type: type)?
            .standardizedFileURL, source.standardizedFileURL)
    }

    /// A source that cannot be opened in place (a file promise, an app's own copy)
    /// hands over a file that is gone once the callback returns. The kept copy
    /// survives and still carries the document's own name.
    func testCopyKeepsTheDocumentName() throws {
        let source = try makeSource(named: "Plnomocenstvo Novák.pdf")
        let url = try XCTUnwrap(load(provider(handing: source, inPlace: false)))

        XCTAssertNotEqual(url.standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, "Plnomocenstvo Novák.pdf")
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: source))
        XCTAssertTrue(url.path.hasPrefix(root.appendingPathComponent("tmp").path))
    }

    func testTwoCopiesWithTheSameNameDoNotCollide() throws {
        let source = try makeSource(named: "zmluva.pdf")
        let first = try XCTUnwrap(load(provider(handing: source, inPlace: false)))
        let second = try XCTUnwrap(load(provider(handing: source, inPlace: false)))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "zmluva.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testProviderWithoutTheTypeYieldsNothing() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier,
                                            visibility: .all) { done in
            done(Data([0x89]), nil)
            return nil
        }
        XCTAssertNil(load(provider))
    }

    func testBytesOnlyDropKeepsTheSuggestedName() {
        XCTAssertEqual(DroppedFileURL.pdfName(suggested: "sken zmluvy.jpg"), "sken zmluvy.pdf")
        XCTAssertEqual(DroppedFileURL.pdfName(suggested: "../x/Dohoda.pdf"), "Dohoda.pdf")
        XCTAssertEqual(DroppedFileURL.pdfName(suggested: nil), "dokument.pdf")
        XCTAssertEqual(DroppedFileURL.pdfName(suggested: "  "), "dokument.pdf")
    }
}

private final class ResultBox: @unchecked Sendable {
    var url: URL?
}
