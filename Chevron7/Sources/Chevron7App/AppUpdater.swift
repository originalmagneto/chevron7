// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Foundation
import Sparkle

/// Decides when Chevron7 checks for a new version at launch and when an update
/// Sparkle found in the background may be shown. Pure state, so tests can drive it
/// without Sparkle.
///
/// Launch check: every start of the updater owes one background check. Sparkle's own
/// schedule pays it when the last check is older than the interval (it checks at
/// once); otherwise Sparkle only schedules the next check, and the app then checks
/// itself. A background check honours "Preskočiť túto verziu" as Sparkle does.
///
/// Presentation: an update found by a background check is shown at once only while
/// Chevron7 is the active app and nothing is signing, authorizing a conversion,
/// answering a browser request or talking to EZZK; otherwise it waits until all of
/// that holds, so the update window never takes the keyboard from a PIN field or the
/// eID's BOK window and never pulls Chevron7 in front of another app.
struct UpdatePromptGate: Equatable {
    private(set) var launchCheckOwed = false
    private(set) var updateWaiting = false

    /// The updater started (a regular launch, or a web-signing launch turning regular).
    mutating func updaterStarted() {
        launchCheckOwed = true
    }

    /// A check began, Sparkle's own or ours: the launch is covered.
    mutating func checkBegan() {
        launchCheckOwed = false
    }

    /// Automatic checks are off, so the launch check is not made either.
    mutating func automaticChecksDisabled() {
        launchCheckOwed = false
    }

    /// Sparkle has scheduled its next check instead of checking now. Returns whether the
    /// app still owes the launch check, at most once per start.
    mutating func takeLaunchCheck() -> Bool {
        defer { launchCheckOwed = false }
        return launchCheckOwed
    }

    /// A background check found an update. Returns true when it is to be shown now;
    /// otherwise it waits for `presentIfWaiting`.
    mutating func updateFound(canPresent: Bool) -> Bool {
        updateWaiting = !canPresent
        return canPresent
    }

    /// Returns true exactly once for a waiting update, when it may now be shown.
    mutating func presentIfWaiting(canPresent: Bool) -> Bool {
        guard updateWaiting, canPresent else { return false }
        updateWaiting = false
        return true
    }

    /// The person saw the update or its session ended (installed, skipped, dismissed,
    /// or brought up through the menu), so nothing waits any more.
    mutating func updateSessionEnded() {
        updateWaiting = false
    }
}

/// Owns Sparkle's standard updater for the lifetime of the app.
///
/// Local/ad-hoc builds intentionally leave SUPublicEDKey unset. In that case
/// Sparkle stays dormant instead of showing a configuration error. Production
/// release builds inject both SUFeedURL and SUPublicEDKey into Info.plist.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController
    private let delegate: AppUpdaterDelegate
    private let isBusy: @MainActor () -> Bool
    private let isAppActive: @MainActor () -> Bool
    private var gate = UpdatePromptGate()
    private var waitTask: Task<Void, Never>?
    private(set) var hasStarted = false
    let isConfigured: Bool

    /// How often a waiting update looks again whether it may be shown.
    static let waitPollInterval: Duration = .seconds(1)

    init(bundle: Bundle = .main,
         isBusy: @escaping @MainActor () -> Bool = { false },
         isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false }) {
        self.isBusy = isBusy
        self.isAppActive = isAppActive
        let delegate = AppUpdaterDelegate()
        self.delegate = delegate
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )

        let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isConfigured = !(feed ?? "").isEmpty && !(publicKey ?? "").isEmpty
        delegate.owner = self
    }

    func startIfNeeded() {
        guard isConfigured, !hasStarted else { return }
        gate.updaterStarted()
        controller.startUpdater()
        hasStarted = true
    }

    func checkForUpdates() {
        startIfNeeded()
        guard hasStarted else { return }
        controller.checkForUpdates(nil)
    }

    // MARK: - Sparkle callbacks

    fileprivate func checkBegan() {
        gate.checkBegan()
    }

    fileprivate func automaticChecksDisabled() {
        gate.automaticChecksDisabled()
    }

    /// Sparkle settled its schedule without checking now: the launch check runs on the
    /// next turn, once Sparkle has armed its timer, so the two never collide.
    fileprivate func willScheduleCheck() {
        guard gate.takeLaunchCheck() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let updater = controller.updater
            guard updater.canCheckForUpdates, !updater.sessionInProgress else { return }
            updater.checkForUpdatesInBackground()
        }
    }

    fileprivate func backgroundUpdateFound() {
        if gate.updateFound(canPresent: canPresent) {
            presentWaitingUpdate()
        } else {
            waitUntilPresentable()
        }
    }

    fileprivate func updateSessionEnded() {
        gate.updateSessionEnded()
        waitTask?.cancel()
        waitTask = nil
    }

    private var canPresent: Bool {
        isAppActive() && !isBusy()
    }

    private func waitUntilPresentable() {
        guard waitTask == nil else { return }
        waitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.waitPollInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.gate.updateWaiting else { break }
                if self.gate.presentIfWaiting(canPresent: self.canPresent) {
                    self.presentWaitingUpdate()
                    break
                }
            }
            self?.waitTask = nil
        }
    }

    /// Brings the update Sparkle holds into focus. With an update session showing, the
    /// standard driver only shows that alert; it starts no new check.
    private func presentWaitingUpdate() {
        controller.updater.checkForUpdates()
    }
}

/// Sparkle's delegates for `AppUpdater`: Sparkle keeps them weakly, so the updater owns
/// this object. Sparkle calls both protocols on the main thread.
private final class AppUpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @MainActor weak var owner: AppUpdater?

    // MARK: SPUUpdaterDelegate (main actor)

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        owner?.checkBegan()
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        owner?.willScheduleCheck()
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        owner?.automaticChecksDisabled()
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// The app shows every background update itself, because the standard driver shows
    /// one in an active regular app only within three seconds of the updater's start and
    /// otherwise waits until the person switches away and back.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        MainActor.assumeIsolated {
            owner?.backgroundUpdateFound()
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            owner?.updateSessionEnded()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            owner?.updateSessionEnded()
        }
    }
}
