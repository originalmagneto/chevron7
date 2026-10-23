// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Foundation
import Observation

/// Another Chevron7.app on this Mac, with the same bundle identifier as the running one.
struct AppCopy: Equatable, Identifiable, Sendable {
    let url: URL
    let version: String?
    /// The copy is newer than the running app, so trashing it would keep the older one.
    let isNewerThanRunning: Bool
    /// The copy itself runs; the Trash would only take its files from under it.
    let isRunning: Bool

    var id: String { url.path }
}

/// Finds other copies of Chevron7 that Launch Services knows about.
///
/// Every copy carries its own Safari web extension, and Safari lists and runs each
/// of them. Two extensions then race for `window.ditec` on a portal, and one left
/// from an old copy answered the status request with nothing, so the portal showed
/// "-200: Chevron7 nie je dostupný" while the current app and agent ran fine
/// (MacBook Air, 2026-10-23: "Chevron7 2.app" 1.5.4 next to Chevron7.app 1.15.1,
/// Finder's "Keep Both" when the DMG was copied over an installed app). Sparkle
/// updates only the copy it runs from, so the other one never catches up.
enum DuplicateAppCopies {
    /// Whether the running app may look for, and offer to trash, other copies. A
    /// development build, a translocated copy or one on a disk image would point at
    /// the installed app as the duplicate, which is the one to keep.
    static func scansFrom(runningPath: String, isOnReadOnlyVolume: Bool) -> Bool {
        !isOnReadOnlyVolume && !isTransient(path: runningPath)
    }

    /// The registered copies worth offering: not the running bundle, not one already
    /// in the Trash, not a development build, Sparkle's unpacked update or a
    /// translocated copy, and not one on a read-only volume such as a mounted DMG,
    /// which the Trash cannot take anyway.
    static func candidatePaths(registered: [String], runningPath: String,
                               exists: (String) -> Bool,
                               isOnReadOnlyVolume: (String) -> Bool) -> [String] {
        let running = normalized(runningPath)
        var seen: Set<String> = [running]
        return registered.compactMap { path in
            let path = normalized(path)
            guard seen.insert(path).inserted, !isTransient(path: path),
                  exists(path), !isOnReadOnlyVolume(path) else { return nil }
            return path
        }
    }

    /// True when `version` is a later release than `running` (numeric comparison of
    /// the dotted parts, so 1.15.1 is later than 1.5.4). An unreadable version is
    /// never newer.
    static func isNewer(_ version: String?, than running: String?) -> Bool {
        guard let version, let running else { return false }
        return version.compare(running, options: .numeric) == .orderedDescending
    }

    private static let transientMarkers = [
        "/.Trash/", "/.build/", "/DerivedData/", "/AppTranslocation/", "/org.sparkle-project.Sparkle/",
    ]

    private static func isTransient(path: String) -> Bool {
        transientMarkers.contains { path.contains($0) }
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: system

    /// The running copy as Settings names it: its version and where it lies.
    static var runningDescription: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return [version.map { "verzia \($0)" }, Bundle.main.bundleURL.path].compactMap(\.self).joined(separator: ", ")
    }

    static func find(bundle: Bundle = .main) -> [AppCopy] {
        let runningPath = bundle.bundleURL.path
        guard let identifier = bundle.bundleIdentifier,
              scansFrom(runningPath: runningPath, isOnReadOnlyVolume: isOnReadOnlyVolume(runningPath)) else {
            return []
        }
        let runningVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let registered = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).map(\.path)
        let runningBundles = Set(NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .compactMap { $0.bundleURL.map { normalized($0.path) } })
        return candidatePaths(registered: registered, runningPath: runningPath,
                              exists: { FileManager.default.fileExists(atPath: $0) },
                              isOnReadOnlyVolume: isOnReadOnlyVolume)
            .map { path in
                let url = URL(fileURLWithPath: path)
                let version = shortVersion(of: url)
                return AppCopy(url: url, version: version,
                               isNewerThanRunning: isNewer(version, than: runningVersion),
                               isRunning: runningBundles.contains(path))
            }
    }

    /// Read from Info.plist directly: `Bundle(url:)` caches its dictionary for the run.
    static func shortVersion(of appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    private static func isOnReadOnlyVolume(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }
}

/// The other copies found at launch, for Settings, Prehliadač a Finder.
@MainActor
@Observable
final class DuplicateAppCopyMonitor {
    static let shared = DuplicateAppCopyMonitor()

    private(set) var copies: [AppCopy] = []

    /// A copy Settings can offer to trash: older than or as old as this one, and not running.
    var hasTrashableCopy: Bool {
        copies.contains { !$0.isNewerThanRunning && !$0.isRunning }
    }

    /// Launch Services can take a moment, so the scan leaves the main thread.
    func refresh() {
        Task {
            let found = await Task.detached(priority: .utility) { DuplicateAppCopies.find() }.value
            copies = found
        }
    }

    /// Moves the copy to the Trash through Finder, which asks for an administrator
    /// password when the copy is not the person's own, and takes it off the list.
    /// Returns the message for Settings.
    func moveToTrash(_ copy: AppCopy) async -> String {
        do {
            _ = try await NSWorkspace.shared.recycle([copy.url])
            copies.removeAll { $0.id == copy.id }
            return Self.trashedMessage
        } catch {
            return "Kópiu sa nepodarilo presunúť do Koša: \(error.localizedDescription)"
        }
    }

    static let trashedMessage =
        "Kópia je v Koši. Ukončite Safari (⌘Q) a otvorte ho znova, aby používalo iba rozšírenie tejto kópie."
}
