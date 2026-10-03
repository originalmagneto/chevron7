// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Identity

struct ProcessConfiguration: Sendable {
    let executableURL: URL
    let timeout: Duration?
    let environment: [String: String]
    let maxStdoutLineBytes: Int
    let maxStderrBytes: Int

    init(
        executableURL: URL,
        timeout: Duration? = nil,
        environment: [String: String] = [:],
        maxStdoutLineBytes: Int = 1_048_576,
        maxStderrBytes: Int = 65_536
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.environment = environment
        self.maxStdoutLineBytes = maxStdoutLineBytes
        self.maxStderrBytes = maxStderrBytes
    }

    /// The engine keeps the last good copy of every EU trusted list here, so one national
    /// server that is down does not cost the next visible signature its list.
    static let trustedListCacheKey = "AUTOGRAM_TRUSTED_LIST_CACHE"

    /// `cacheRoot` is the user's Caches folder (`~/Library/Caches`); tests pass their own.
    static func signingHelperEnvironment(
        from source: [String: String] = ProcessInfo.processInfo.environment,
        cacheRoot: URL? = nil
    ) -> [String: String] {
        let allowedKeys = [
            "HOME",
            "TMPDIR",
            "USER",
            "LOGNAME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "__CF_USER_TEXT_ENCODING"
        ]
        var environment = allowedKeys.reduce(into: [String: String]()) { result, key in
            guard let value = source[key], !value.isEmpty else { return }
            result[key] = value
        }
        if environment["HOME"] == nil {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        if environment["TMPDIR"] == nil {
            environment["TMPDIR"] = FileManager.default.temporaryDirectory.path
        }
        let caches = cacheRoot.map { $0.appending(path: ProductIdentity.name, directoryHint: .isDirectory) }
            ?? ProductIdentity.cachesDirectory()
        environment[trustedListCacheKey] = caches
            .appending(path: "Trusted Lists", directoryHint: .isDirectory).path
        return environment
    }
}
