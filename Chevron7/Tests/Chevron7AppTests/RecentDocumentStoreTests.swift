// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7TestSupport
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class RecentDocumentStoreTests: XCTestCase {
    func testStoreIsDisabledByDefaultAndDoesNotRecord() {
        XCTAssertFalse(AppSettings().retainRecentDocuments)
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = false
        let defaults = makeDefaults()
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: defaults)
        let url = makeDocument(named: "disabled.pdf")

        store.record(url: url)

        XCTAssertFalse(store.isEnabled)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(defaults.data(forKey: "app.slovensko.chevron7.recentDocuments.v1"))
    }
    func testSigningStoreRecordsOnlyNewlyAcceptedDocuments() async {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let recentStore = RecentDocumentStore(settingsStore: settingsStore, defaults: makeDefaults())
        let signingStore = SigningSessionStore(
            signingProvider: DemoSigningProvider(),
            settingsStore: settingsStore,
            recentDocumentStore: recentStore)
        let firstURL = makeDocument(named: "first.pdf")
        let duplicateURL = firstURL.standardizedFileURL
        let secondURL = makeDocument(named: "second.pdf")

        await signingStore.addDocuments(at: [firstURL, duplicateURL, secondURL], selectLast: false)

        XCTAssertEqual(signingStore.queue.map(\.url.standardizedFileURL), [
            firstURL.standardizedFileURL,
            secondURL.standardizedFileURL
        ])
        XCTAssertEqual(recentStore.entries.map(\.displayName), ["second.pdf", "first.pdf"])
    }

    func testRemovingOrResettingQueueSelectionClearsSelectedQueueID() async {
        let settingsStore = makeSettingsStore()
        let recentStore = RecentDocumentStore(settingsStore: settingsStore, defaults: makeDefaults())
        let signingStore = SigningSessionStore(
            signingProvider: DemoSigningProvider(),
            settingsStore: settingsStore,
            recentDocumentStore: recentStore)
        await signingStore.addDocuments(
            at: [makeDocument(named: "first.pdf"), makeDocument(named: "second.pdf")],
            selectLast: false)

        let firstID = signingStore.queue[0].id
        signingStore.selectedQueueID = firstID
        signingStore.removeQueueItem(firstID)

        XCTAssertNil(signingStore.selectedQueueID)

        signingStore.selectedQueueID = signingStore.queue[0].id
        signingStore.reset()

        XCTAssertNil(signingStore.selectedQueueID)
    }

    func testEnablingPersistenceRecordsEntryAndPersistsMetadata() throws {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let defaults = makeDefaults()
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: defaults)
        let url = makeDocument(named: "enabled.pdf")

        store.record(url: url)

        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].displayName, "enabled.pdf")
        XCTAssertNotNil(store.entries[0].lastOpenedAt)

        let persisted = try XCTUnwrap(defaults.data(forKey: "app.slovensko.chevron7.recentDocuments.v1"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [[String: Any]])
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(Set(raw[0].keys), ["id", "bookmarkData", "displayName", "lastOpenedAt"])

        let reloadedStore = RecentDocumentStore(settingsStore: settingsStore, defaults: defaults)
        XCTAssertEqual(reloadedStore.entries, store.entries)

    }
    func testEntriesAreBoundedAndOrderedMostRecentlyOpenedFirst() {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: makeDefaults())
        let urls = (0..<10).map { makeDocument(named: "document-\($0).pdf") }

        for url in urls {
            store.record(url: url)
        }

        XCTAssertEqual(store.entries.count, 8)
        XCTAssertEqual(store.entries.map(\.displayName), (2..<10).reversed().map { "document-\($0).pdf" })
    }

    func testRecordingDuplicateRefreshesExistingEntryToTheFront() {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: makeDefaults())
        let firstURL = makeDocument(named: "first.pdf")
        let secondURL = makeDocument(named: "second.pdf")

        store.record(url: firstURL)
        let originalID = store.entries[0].id
        store.record(url: secondURL)
        store.record(url: firstURL)

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries[0].displayName, "first.pdf")
        XCTAssertNotEqual(store.entries[0].id, originalID)
        XCTAssertEqual(store.entries.map(\.displayName), ["first.pdf", "second.pdf"])
    }

    func testResolveStartsSecurityScopedAccessAndReturnsDocumentURL() {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: makeDefaults())
        let url = makeDocument(named: "resolve.pdf")
        store.record(url: url)

        let resolved = store.resolve(store.entries[0])

        XCTAssertEqual(resolved?.standardizedFileURL, url.standardizedFileURL)
    }

    func testAvailabilityChecksBookmarkWithoutOpeningDocument() {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: makeDefaults())
        let url = makeDocument(named: "availability.pdf")
        store.record(url: url)
        let entry = store.entries[0]

        XCTAssertTrue(store.isAvailable(entry))
        try? FileManager.default.removeItem(at: url)
        XCTAssertFalse(store.isAvailable(entry))
        XCTAssertEqual(store.entries, [entry])
    }

    func testWithResolvedURLRunsOperationForAvailableEntry() async {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: makeDefaults())
        let url = makeDocument(named: "balanced.pdf")
        store.record(url: url)
        let entry = store.entries[0]
        var operationURL: URL?

        let resolved = await store.withResolvedURL(entry) { resolvedURL in
            operationURL = resolvedURL
        }

        XCTAssertTrue(resolved)
        XCTAssertEqual(operationURL?.standardizedFileURL, url.standardizedFileURL)
    }

    func testResolveReturnsStaleBookmarkURLWithoutRemovingEntry() throws {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let defaults = makeDefaults()
        let originalURL = makeDocument(named: "stale-original.pdf")
        let movedURL = originalURL.deletingLastPathComponent().appendingPathComponent("stale-moved.pdf")
        let bookmarkData = try originalURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        var isStale = false
        let resolvedProbe = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        XCTAssertTrue(isStale)

        let entry = RecentDocumentStore.RecentDocument(
            id: UUID(),
            bookmarkData: bookmarkData,
            displayName: "stale-original.pdf",
            lastOpenedAt: Date())
        defaults.set(try JSONEncoder().encode([entry]), forKey: "app.slovensko.chevron7.recentDocuments.v1")
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: defaults)

        let resolved = store.resolve(entry)

        XCTAssertEqual(resolvedProbe.standardizedFileURL, movedURL.standardizedFileURL)
        XCTAssertEqual(resolved?.standardizedFileURL, movedURL.standardizedFileURL)
        XCTAssertEqual(store.entries, [entry])
    }

    func testMissingBookmarkCanBeRemovedExplicitlyWithoutMutatingDuringResolution() throws {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let defaults = makeDefaults()
        let missing = RecentDocumentStore.RecentDocument(
            id: UUID(),
            bookmarkData: Data([0x01, 0x02, 0x03]),
            displayName: "missing.pdf",
            lastOpenedAt: Date())
        let encoded = try JSONEncoder().encode([missing])
        defaults.set(encoded, forKey: "app.slovensko.chevron7.recentDocuments.v1")
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: defaults)

        XCTAssertNil(store.resolve(missing))
        XCTAssertEqual(store.entries, [missing])

        store.remove(id: missing.id)

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testClearRemovesAllEntriesAndPersistedData() {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.retainRecentDocuments = true
        let defaults = makeDefaults()
        let store = RecentDocumentStore(settingsStore: settingsStore, defaults: defaults)
        store.record(url: makeDocument(named: "one.pdf"))
        store.record(url: makeDocument(named: "two.pdf"))

        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(defaults.data(forKey: "app.slovensko.chevron7.recentDocuments.v1"))
    }

    func testRetainRecentDocumentsDefaultsToFalseWhenMissingFromEncodedSettings() throws {
        let settings = AppSettings()
        let encoded = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "retainRecentDocuments")
        let withoutKey = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: withoutKey)

        XCTAssertFalse(decoded.retainRecentDocuments)
    }

    private func makeDefaults() -> UserDefaults {
        MemoryUserDefaults()
    }

    private func makeDocument(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentDocumentStoreTests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }
}
