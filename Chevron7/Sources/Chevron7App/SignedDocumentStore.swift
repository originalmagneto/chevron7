// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import Foundation
import SwiftUI

/// History of what was signed, kept apart from the list of recently *opened*
/// documents: the two answer different questions, and mixing them would hide
/// signatures behind a preference that is about reopening files.
///
/// This is not the Evidence register. That one is the legal record of zaručená
/// konverzia, with evidence numbers and CEZZK submission, and only conversions
/// belong in it.
@MainActor
@Observable
final class SignedDocumentStore {
    /// Where the signing request came from.
    enum Origin: String, Codable, Sendable {
        case app
        case browser
        case integration

        var label: String {
            switch self {
            case .app: return "V aplikácii"
            case .browser: return "Z prehliadača"
            case .integration: return "Z inej aplikácie"
            }
        }
    }

    /// What actually held the private key.
    enum Method: String, Codable, Sendable {
        case card
        case mobile

        var label: String {
            switch self {
            case .card: return "Kartou"
            case .mobile: return "Mobilom (NFC)"
            }
        }

        var sfSymbol: String {
            switch self {
            case .card: return "creditcard"
            case .mobile: return "iphone.gen3.radiowaves.left.and.right"
            }
        }
    }

    struct SignedDocument: Identifiable, Codable, Hashable, Sendable {
        let id: UUID
        let displayName: String
        let signedAt: Date
        let origin: Origin
        let method: Method
        let signatureLevel: String
        let signedBy: String
        /// Absolute path, when a copy was kept. Browser signatures can be
        /// configured not to keep one, and then there is nothing to reopen.
        let path: String?

        var wasSavedLocally: Bool { path != nil }

        var levelLabel: String { signatureLevel.replacingOccurrences(of: "_", with: " ") }

        /// True when the file is still where it was written.
        var isAvailable: Bool {
            guard let path else { return false }
            return FileManager.default.fileExists(atPath: path)
        }

        var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    }

    private static let storageKey = "\(ProductIdentity.bundleIdentifier).signedDocuments.v1"
    /// Enough history for retention to find old copies; the sidebar shows only a few.
    private static let maximumEntries = 200

    private let defaults: UserDefaults
    private let now: () -> Date
    /// Moves a file to the Trash rather than deleting it, so a copy removed by
    /// mistake can still be put back.
    private let trash: (URL) throws -> Void
    private(set) var entries: [SignedDocument]

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.defaults = defaults
        self.now = now
        self.trash = trash
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([SignedDocument].self, from: data) {
            self.entries = Array(stored.prefix(Self.maximumEntries))
        } else {
            self.entries = []
        }
    }

    func record(displayName: String, origin: Origin, method: Method,
                signatureLevel: String, signedBy: String, url: URL?) {
        let entry = SignedDocument(
            id: UUID(),
            displayName: displayName,
            signedAt: now(),
            origin: origin,
            method: method,
            signatureLevel: signatureLevel,
            signedBy: signedBy,
            path: url?.path)
        entries = Array(([entry] + entries).prefix(Self.maximumEntries))
        persist()
    }

    /// Removes an entry, and with `trashingFile` also moves its kept copy to the Trash.
    func remove(id: UUID, trashingFile: Bool) {
        if trashingFile, let entry = entries.first(where: { $0.id == id }) {
            trashCopy(of: entry)
        }
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear(trashingFiles: Bool) {
        if trashingFiles {
            entries.forEach(trashCopy(of:))
        }
        entries = []
        persist()
    }

    /// Moves copies kept from browser signatures that are older than `days` to the
    /// Trash and drops their entries. Zero keeps everything. Documents signed in the
    /// app are never touched: they sit where the person chose to save them.
    @discardableResult
    func purgeBrowserCopies(olderThanDays days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        let expired = entries.filter { $0.origin == .browser && $0.signedAt < cutoff }
        guard !expired.isEmpty else { return 0 }
        expired.forEach(trashCopy(of:))
        let expiredIDs = Set(expired.map(\.id))
        entries.removeAll { expiredIDs.contains($0.id) }
        persist()
        return expired.count
    }

    private func trashCopy(of entry: SignedDocument) {
        guard entry.origin != .integration, let url = entry.url else { return }
        do {
            try trash(url)
        } catch {
            // Already gone, or moved by the person: nothing left to clean up.
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
