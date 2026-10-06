// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Foundation

enum FinderQuickActionService {
    static let menuTitle = "Podpísať s QES + QTS (Chevron7)"
    static let workflowResourceName = "Chevron7 Finder Quick Action"
    static let workflowInstallName = "Chevron7 Finder Quick Action.workflow"

    /// Autogram macOS, this app's name before Chevron7, installed its own Quick Action
    /// ("Podpísať s QES + QTS (Autogram)"). Once that app is gone the workflow stays in
    /// Finder's menu and fails with "Autogram macOS ARM64 helper was not found".
    static let legacyWorkflowNames = ["Autogram Finder Quick Action.workflow"]
    /// Only a workflow carrying Autogram's own script is the one Autogram macOS installed.
    static let legacyWorkflowMarker = "Contents/Resources/autogram-cli-sign.sh"
    static let legacyBundleIdentifier = "sk.autogram.Autogram"

    static let legacyMenuTitle = "Podpísať s QES + QTS (Autogram)"

    @discardableResult
    static func installQuickAction() -> Bool {
        retireLegacyQuickActions(in: servicesDirectory)
        // Its menu entry goes with it once the workflow is gone (retired now or earlier).
        let legacyGone = legacyWorkflowNames.allSatisfy {
            !FileManager.default.fileExists(atPath: servicesDirectory.appendingPathComponent($0).path)
        }
        return installChevron7QuickAction(droppingLegacyEntries: legacyGone)
    }

    private static var servicesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true)
    }

    /// Moves Autogram macOS's Quick Action to the Trash when no Autogram macOS is left
    /// to run it. The Trash keeps it restorable; a workflow without Autogram's script,
    /// or one Autogram macOS can still run, is never touched.
    @discardableResult
    static func retireLegacyQuickActions(
        in servicesDirectory: URL,
        legacyAppInstalled: Bool = legacyAppIsInstalled(),
        moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> [URL] {
        guard !legacyAppInstalled else { return [] }
        var retired: [URL] = []
        for name in legacyWorkflowNames {
            let workflow = servicesDirectory.appendingPathComponent(name, isDirectory: true)
            let marker = workflow.appendingPathComponent(legacyWorkflowMarker)
            guard FileManager.default.fileExists(atPath: marker.path) else { continue }
            do {
                try moveToTrash(workflow)
                retired.append(workflow)
            } catch {
                continue
            }
        }
        return retired
    }

    static func legacyAppIsInstalled() -> Bool {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: legacyBundleIdentifier)
            .contains { !$0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func installChevron7QuickAction(droppingLegacyEntries: Bool) -> Bool {
        guard let source = Bundle.main.url(
            forResource: workflowResourceName,
            withExtension: "workflow"
        ) else {
            return false
        }

        let destination = servicesDirectory.appendingPathComponent(workflowInstallName)
        do {
            try FileManager.default.createDirectory(
                at: servicesDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            enableInstalledWorkflow(droppingLegacyEntries: droppingLegacyEntries)
            return refreshServicesCache()
        } catch {
            return false
        }
    }

    private static func enableInstalledWorkflow(droppingLegacyEntries: Bool) {
        guard let defaults = UserDefaults(suiteName: "pbs") else { return }
        let statuses = defaults.dictionary(forKey: "NSServicesStatus") ?? [:]
        defaults.set(
            servicesStatus(updating: statuses, droppingLegacyEntries: droppingLegacyEntries),
            forKey: "NSServicesStatus"
        )
    }

    private static func statusKey(_ title: String) -> String {
        "(null) - \(title) - runWorkflowAsService"
    }

    /// Finder's Quick Actions menu and the context menu read `presentation_modes`; the
    /// `enabled_*` keys earlier builds wrote are the pre-Mojave format Finder ignores, so
    /// the workflow never appeared under Quick Actions. A person's own choice, once made
    /// in the new format, is kept.
    static func servicesStatus(
        updating statuses: [String: Any],
        droppingLegacyEntries: Bool = false
    ) -> [String: Any] {
        var statuses = statuses
        let key = statusKey(menuTitle)
        let current = statuses[key] as? [String: Any]
        if current?["presentation_modes"] == nil {
            statuses[key] = ["presentation_modes": [
                "ContextMenu": 1,
                "FinderPreview": 1,
                "ServicesMenu": 1,
                "TouchBar": 1
            ]]
        }
        if droppingLegacyEntries {
            statuses[statusKey(legacyMenuTitle)] = nil
        }
        return statuses
    }

    @discardableResult
    static func refreshServicesCache() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        process.arguments = ["-update"]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// Whether Finder offers the Quick Action. Its file nearly always exists (every launch
    /// reinstalls it), so what tells the person something is the `pbs` entry: Finder's
    /// context menu reads `presentation_modes`, and a person who unchecked the action in
    /// Customize… has a zero there.
    static func visibility(workflowInstalled: Bool, statuses: [String: Any]) -> QuickActionVisibility {
        guard workflowInstalled else { return .notInstalled }
        let entry = statuses[statusKey(menuTitle)] as? [String: Any]
        let modes = entry?["presentation_modes"] as? [String: Any]
        let contextMenu = (modes?["ContextMenu"] as? NSNumber)?.intValue ?? 0
        return contextMenu == 1 ? .visible : .hiddenInFinder
    }

    static func currentVisibility() -> QuickActionVisibility {
        let installed = FileManager.default.fileExists(
            atPath: servicesDirectory.appendingPathComponent(workflowInstallName).path)
        let statuses = UserDefaults(suiteName: "pbs")?.dictionary(forKey: "NSServicesStatus") ?? [:]
        return visibility(workflowInstalled: installed, statuses: statuses)
    }
}

enum QuickActionVisibility: Equatable {
    case visible
    case hiddenInFinder
    case notInstalled
}
