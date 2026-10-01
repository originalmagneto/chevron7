// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// A `UserDefaults` that keeps every value in memory and never reaches `cfprefsd` or
/// `~/Library/Preferences`, for code under test that takes a `defaults:` parameter.
///
/// A named suite writes `~/Library/Preferences/<name>.plist` as soon as a value is set,
/// and removing its persistent domain afterwards still leaves an empty plist behind,
/// written by `cfprefsd` at its own pace. `register(defaults:)` never touches disk, but
/// its registration domain is shared by the whole process, `.standard` included.
///
/// Foundation routes the typed accessors (`data(forKey:)`, `bool(forKey:)`, `set(true,
/// forKey:)`, ...) through the three primitives overridden here, so values set on one
/// instance are seen only by that instance. The suite name matches the pattern
/// `RealStorageGuard` watches, so a call that slipped past these overrides and wrote the
/// suite to disk would fail the test instead of leaking silently.
public final class MemoryUserDefaults: UserDefaults, @unchecked Sendable {
    public let suiteName: String

    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init() {
        let name = "MemoryUserDefaultsTests-\(UUID().uuidString)"
        suiteName = name
        super.init(suiteName: name)!
    }

    public override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    public override func removeObject(forKey defaultName: String) {
        lock.withLock { values[defaultName] = nil }
    }
}
