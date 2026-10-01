// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7TestSupport
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class SignedDocumentStoreTests: XCTestCase {
    private var trashed: [URL] = []

    private func makeStore(now: @escaping () -> Date = Date.init) -> SignedDocumentStore {
        SignedDocumentStore(defaults: MemoryUserDefaults(), now: now, trash: { [unowned self] url in
            trashed.append(url)
        })
    }

    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    func testRemovingOnlyFromTheListKeepsTheFile() {
        let store = makeStore()
        store.record(displayName: "a.pdf", origin: .browser, method: .card, signatureLevel: "XAdES_BASELINE_B",
                     signedBy: "X", url: file("a.asice"))

        store.remove(id: store.entries[0].id, trashingFile: false)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(trashed.isEmpty)
    }

    func testRemovingWithTheFileMovesItToTheTrash() {
        let store = makeStore()
        store.record(displayName: "a.pdf", origin: .browser, method: .card, signatureLevel: "XAdES_BASELINE_B",
                     signedBy: "X", url: file("a.asice"))

        store.remove(id: store.entries[0].id, trashingFile: true)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(trashed, [file("a.asice")])
    }

    func testClearingWithFilesTrashesEveryKeptCopy() {
        let store = makeStore()
        store.record(displayName: "a.pdf", origin: .browser, method: .card, signatureLevel: "B", signedBy: "X",
                     url: file("a.asice"))
        store.record(displayName: "b.pdf", origin: .browser, method: .mobile, signatureLevel: "B", signedBy: "X",
                     url: nil)

        store.clear(trashingFiles: true)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(trashed, [file("a.asice")])
    }

    /// Only copies kept from browser signatures expire; a document signed in the
    /// app sits next to its original, where the person chose to put it.
    func testRetentionTrashesOnlyOldBrowserCopies() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: { clock })
        store.record(displayName: "old-web.pdf", origin: .browser, method: .card, signatureLevel: "B", signedBy: "X",
                     url: file("old-web.asice"))
        store.record(displayName: "old-app.pdf", origin: .app, method: .card, signatureLevel: "T", signedBy: "X",
                     url: file("old-app.pdf"))
        clock = clock.addingTimeInterval(31 * 86_400)
        store.record(displayName: "new-web.pdf", origin: .browser, method: .card, signatureLevel: "B", signedBy: "X",
                     url: file("new-web.asice"))

        let removed = store.purgeBrowserCopies(olderThanDays: 30)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(trashed, [file("old-web.asice")])
        XCTAssertEqual(store.entries.map(\.displayName), ["new-web.pdf", "old-app.pdf"])
    }

    func testRetentionOfZeroDaysKeepsEverything() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: { clock })
        store.record(displayName: "web.pdf", origin: .browser, method: .card, signatureLevel: "B", signedBy: "X",
                     url: file("web.asice"))
        clock = clock.addingTimeInterval(400 * 86_400)

        XCTAssertEqual(store.purgeBrowserCopies(olderThanDays: 0), 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testSettingsDefaultToKeepingCopiesAndDecodeOlderSettings() throws {
        XCTAssertEqual(AppSettings().webSigningRetentionDays, 0)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.webSigningRetentionDays, 0)
    }
}
