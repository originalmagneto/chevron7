// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import Chevron7Kit
import Foundation
import OSLog

/// Record-first conversions whose record is signed but whose client output is not, one binary
/// property list per register row (`Evidence/pending/<recordID>.plist`). They outlive a new
/// document in ZaKo and an app restart, so the advocate can finish a conversion once EZZK has
/// processed its record (`RecordFirstWatcher`). The value in memory is the truth: a write that
/// fails keeps the conversion for this app run and reports the failure to the caller.
@MainActor
@Observable
final class RecordFirstPendingStore {
    /// Every pending conversion, oldest record signature first.
    private(set) var all: [RecordFirstPending] = []

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "EZZK")

    init(directory: URL) {
        self.directory = directory
        reload()
    }

    /// The pending conversions folder inside an evidence root (`LocalEvidenceStore`'s convention).
    static func directory(inStorageRoot root: URL) -> URL {
        root.appendingPathComponent("Evidence", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
    }

    func pending(id: UUID) -> RecordFirstPending? {
        all.first { $0.recordID == id }
    }

    /// Keeps the conversion in memory, then writes it. Throws when the write failed; the
    /// conversion stays available until the app quits.
    func save(_ pending: RecordFirstPending) throws {
        all.removeAll { $0.recordID == pending.recordID }
        all.append(pending)
        all.sort { $0.recordSignedAt < $1.recordSignedAt }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(pending).write(to: fileURL(for: pending.recordID), options: [.atomic])
    }

    func remove(id: UUID) {
        all.removeAll { $0.recordID == id }
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// Reads every file again. A file that cannot be decoded is left where it is and logged.
    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = PropertyListDecoder()
        var loaded: [RecordFirstPending] = []
        for file in files where file.pathExtension == "plist" {
            do {
                loaded.append(try decoder.decode(RecordFirstPending.self, from: Data(contentsOf: file)))
            } catch {
                log.error("Pending conversion \(file.lastPathComponent, privacy: .public) could not be read: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        all = loaded.sorted { $0.recordSignedAt < $1.recordSignedAt }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).plist")
    }
}
