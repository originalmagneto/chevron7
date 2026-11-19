// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import Foundation
import os

/// Writes the helper's stderr to the system log, line by line. A failed signature reached
/// the app only as a code such as SIGNING_UNAVAILABLE; the engine prints the exception
/// classes behind it there (`log show --predicate 'category == "EngineBridge"'`). Used by the
/// v2 session and the v1 runner alike: a v1 signature's failure reached no log (F12, 2026-11-19).
final class HelperErrorLog: @unchecked Sendable {
    private static let logger = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "EngineBridge")
    private static let maximumLineLength = 4096
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        let complete: [Data] = lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 10) {
                lines.append(Data(buffer[..<newline]))
                buffer.removeSubrange(...newline)
            }
            if buffer.count > Self.maximumLineLength {
                lines.append(buffer)
                buffer.removeAll()
            }
            return lines
        }
        complete.forEach(Self.log)
    }

    func flush() {
        let rest: Data = lock.withLock {
            defer { buffer.removeAll() }
            return buffer
        }
        Self.log(rest)
    }

    private static func log(_ line: Data) {
        let text = String(decoding: line.prefix(maximumLineLength), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isPublicFailureLine(text) {
            logger.notice("Signing helper: \(text, privacy: .public)")
        } else {
            logger.info("Signing helper: \(text, privacy: .private)")
        }
    }

    /// The engine's failure lines carry only exception classes and PKCS#11 codes; other output
    /// (library logging) may name files, so it stays private.
    static func isPublicFailureLine(_ text: String) -> Bool {
        text.hasPrefix("Signing failed") || text.hasPrefix("Signing a file failed")
    }
}
