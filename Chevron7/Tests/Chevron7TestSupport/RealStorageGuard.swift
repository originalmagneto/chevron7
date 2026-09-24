// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import Foundation
import XCTest

/// Fails any test that creates, changes or removes anything under the user's real
/// `~/Library/Application Support/Chevron7` or `~/Library/Caches/Chevron7`, a
/// preference file in `~/Library/Preferences` named after a test suite, or a key of the
/// test runner's own `UserDefaults.standard` domain.
///
/// The evidence register there is a legal record, so tests must pass a temporary
/// directory to every store instead. A `UserDefaults` suite a test opens by name is
/// written to `~/Library/Preferences/<name>.plist` and never removed, so tests pass a
/// `MemoryUserDefaults` instead. The guard lists both folders and the matching
/// preference files (path, size and modification date) when it is installed, checks
/// them again at the end of every test and records a failure on the test that changed
/// them. A change made after the last test ends the process with a non-zero status.
///
/// Under XCTest `UserDefaults.standard` is the runner's domain (`com.apple.dt.xctest.tool`
/// under `swift test`), kept in `~/Library/Preferences/<domain>.plist` and shared by every
/// test run on the Mac, so a value one test saves there is what a later test, or a later
/// run, reads back. Code under test takes a `defaults:` parameter instead, and tests pass
/// a `MemoryUserDefaults`. The guard compares the domain as this process sees it, not the
/// plist: `cfprefsd` writes the file at its own pace, which would blame a later test.
///
/// SwiftPM offers no `NSPrincipalClass` for the test bundle, so the guard installs
/// itself from a module initializer (`installRealStorageGuardAtLoad`) when the bundle is
/// loaded: before XCTest picks the tests, which covers `--filter` runs too.
/// Runs when the test bundle is loaded, like an Objective-C `+load`.
@used @section("__DATA,__mod_init_func")
let installRealStorageGuardAtLoad: @convention(c) () -> Void = { RealStorageGuard.install() }

public final class RealStorageGuard: NSObject, XCTestObservation, @unchecked Sendable {
    public static let watchedRoots = [
        ProductIdentity.applicationSupportDirectory(),
        ProductIdentity.cachesDirectory()
    ]

    private nonisolated(unsafe) static var shared: RealStorageGuard?
    private static let lock = NSLock()

    public static let preferencesDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences", isDirectory: true)

    /// Preference files named after a test class, such as `SigningBatchTests.<UUID>.plist`
    /// or `EZZKProductionPolicyTests-<UUID>.plist`. Real preference domains are reverse
    /// DNS names starting in lower case, so they never match.
    public static let testSuitePreferencePattern = try! NSRegularExpression(
        pattern: #"^[A-Z][A-Za-z0-9]*Tests[.-].*\.plist$"#)

    /// The persistent domain `UserDefaults.standard` writes to in this process.
    public static var standardDefaultsDomain: String {
        Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }

    private let lock = NSLock()
    private var baseline: [String: String]
    private var preferencesBaseline: [String: String]
    private var standardDefaultsBaseline: [String: Any]

    private init(baseline: [String: String], preferencesBaseline: [String: String],
                 standardDefaultsBaseline: [String: Any]) {
        self.baseline = baseline
        self.preferencesBaseline = preferencesBaseline
        self.standardDefaultsBaseline = standardDefaultsBaseline
    }

    /// Registers the observer once per process; later calls do nothing.
    public static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard shared == nil else { return }
        let observer = RealStorageGuard(baseline: snapshot(), preferencesBaseline: preferencesSnapshot(),
                                        standardDefaultsBaseline: standardDefaultsSnapshot())
        shared = observer
        XCTestObservationCenter.shared.addTestObserver(observer)
    }

    public static var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shared != nil
    }

    // MARK: - XCTestObservation

    public func testCaseWillStart(_ testCase: XCTestCase) {
        // A teardown block runs inside the test, so the failure lands on this test.
        testCase.addTeardownBlock { [self] in
            for message in takeMessages() {
                XCTFail(message)
            }
        }
    }

    public func testBundleDidFinish(_ testBundle: Bundle) {
        let messages = takeMessages()
        guard !messages.isEmpty else { return }
        for message in messages {
            FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        }
        exit(EXIT_FAILURE)
    }

    // MARK: - Snapshots

    /// One failure message per kind of change since the last check; the new state becomes
    /// the baseline so one offender does not fail every later test.
    private func takeMessages() -> [String] {
        let current = Self.snapshot()
        let currentPreferences = Self.preferencesSnapshot()
        let currentStandardDefaults = Self.standardDefaultsSnapshot()
        lock.lock()
        defer { lock.unlock() }
        let changes = Self.differences(baseline, current)
        let preferenceChanges = Self.differences(preferencesBaseline, currentPreferences)
        let standardDefaultsChanges = Self.changedKeys(standardDefaultsBaseline, currentStandardDefaults)
        baseline = current
        preferencesBaseline = currentPreferences
        standardDefaultsBaseline = currentStandardDefaults
        var messages: [String] = []
        if !changes.isEmpty {
            messages.append("The test changed the user's real Chevron7 data; pass a temporary directory instead "
                + "(or quit Chevron7 if the app itself was writing there during the run):\n"
                + Self.list(changes))
        }
        if !preferenceChanges.isEmpty {
            messages.append("The test wrote a UserDefaults suite named after a test to ~/Library/Preferences, "
                + "where it stays for good; pass a MemoryUserDefaults() instead (or wait for another checkout's "
                + "test run to finish if one was leaking there at the same time):\n"
                + Self.list(preferenceChanges))
        }
        if !standardDefaultsChanges.isEmpty {
            messages.append("The test changed UserDefaults.standard, the test runner's domain "
                + "\(Self.standardDefaultsDomain) that stays in ~/Library/Preferences and is read by later tests; "
                + "pass a MemoryUserDefaults() to the code's defaults: parameter (makeSettingsStore() already "
                + "does for AppSettingsStore):\n"
                + Self.list(standardDefaultsChanges))
        }
        return messages
    }

    private static func differences(_ old: [String: String], _ new: [String: String]) -> [String] {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
    }

    /// Keys added, removed or given another value; values are property list objects, so
    /// `isEqual` compares them by content.
    public static func changedKeys(_ old: [String: Any], _ new: [String: Any]) -> [String] {
        Set(old.keys).union(new.keys).filter { key in
            switch (old[key], new[key]) {
            case (nil, nil): false
            case let (before?, after?): !(before as AnyObject).isEqual(after)
            default: true
            }
        }.sorted()
    }

    private static func list(_ paths: [String]) -> String {
        paths.map { "  \($0)" }.joined(separator: "\n")
    }

    /// Path to "size modification-date" for every item under the watched roots,
    /// including each root itself, so a created root counts as a change too.
    static func snapshot(fileManager: FileManager = .default) -> [String: String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        var result: [String: String] = [:]
        for root in watchedRoots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            var items = [root]
            if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) {
                for case let url as URL in enumerator { items.append(url) }
            }
            // Finder writes .DS_Store whenever someone browses the folder.
            for url in items where url.lastPathComponent != ".DS_Store" {
                let values = try? url.resourceValues(forKeys: Set(keys))
                // Directory dates change whenever an entry does; the entries already show that.
                let date = values?.isDirectory == true ? "dir"
                    : values?.contentModificationDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "?"
                result[url.standardizedFileURL.path] = "\(values?.fileSize ?? 0) \(date)"
            }
        }
        return result
    }

    /// Path to "size modification-date" for every file directly in `~/Library/Preferences`
    /// whose name matches `testSuitePreferencePattern`. Other apps rewrite their own
    /// preference files all the time, so only test-named files are listed.
    static func preferencesSnapshot(fileManager: FileManager = .default) -> [String: String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: preferencesDirectory.path)) ?? []
        var result: [String: String] = [:]
        for name in names where isTestSuitePreferenceFile(name) {
            let path = preferencesDirectory.appendingPathComponent(name).path
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let date = (attributes?[.modificationDate] as? Date).map { String($0.timeIntervalSinceReferenceDate) } ?? "?"
            result[path] = "\(size) \(date)"
        }
        return result
    }

    public static func isTestSuitePreferenceFile(_ name: String) -> Bool {
        testSuitePreferencePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Every key of `standardDefaultsDomain` as this process sees it, including writes
    /// `cfprefsd` has not flushed to the plist yet.
    static func standardDefaultsSnapshot() -> [String: Any] {
        UserDefaults.standard.persistentDomain(forName: standardDefaultsDomain) ?? [:]
    }
}
