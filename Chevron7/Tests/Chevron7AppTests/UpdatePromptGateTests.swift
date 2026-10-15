// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class UpdatePromptGateTests: XCTestCase {
    func testStartOwesOneLaunchCheckWhenSparkleOnlySchedules() {
        var gate = UpdatePromptGate()
        gate.updaterStarted()
        XCTAssertTrue(gate.takeLaunchCheck())
        // The reschedule after that check finished must not start another one.
        XCTAssertFalse(gate.takeLaunchCheck())
    }

    func testSparklesOwnOverdueCheckCoversTheLaunch() {
        var gate = UpdatePromptGate()
        gate.updaterStarted()
        gate.checkBegan()
        XCTAssertFalse(gate.takeLaunchCheck())
    }

    func testDisabledAutomaticChecksSkipTheLaunchCheck() {
        var gate = UpdatePromptGate()
        gate.updaterStarted()
        gate.automaticChecksDisabled()
        XCTAssertFalse(gate.takeLaunchCheck())
    }

    func testNoLaunchCheckBeforeTheUpdaterStarts() {
        var gate = UpdatePromptGate()
        XCTAssertFalse(gate.takeLaunchCheck())
    }

    func testUpdateFoundWhileIdleIsShownAtOnce() {
        var gate = UpdatePromptGate()
        XCTAssertTrue(gate.updateFound(canPresent: true))
        XCTAssertFalse(gate.updateWaiting)
        XCTAssertFalse(gate.presentIfWaiting(canPresent: true))
    }

    func testUpdateFoundWhileBusyWaitsAndIsShownOnceWhenIdle() {
        var gate = UpdatePromptGate()
        XCTAssertFalse(gate.updateFound(canPresent: false))
        XCTAssertTrue(gate.updateWaiting)
        XCTAssertFalse(gate.presentIfWaiting(canPresent: false))
        XCTAssertTrue(gate.presentIfWaiting(canPresent: true))
        XCTAssertFalse(gate.presentIfWaiting(canPresent: true))
    }

    func testEndedSessionLeavesNothingToShow() {
        var gate = UpdatePromptGate()
        _ = gate.updateFound(canPresent: false)
        gate.updateSessionEnded()
        // A late idle tick must not start a user-initiated check.
        XCTAssertFalse(gate.presentIfWaiting(canPresent: true))
    }

    @MainActor
    func testUnconfiguredBuildNeverStartsTheUpdater() {
        let updater = AppUpdater(bundle: Bundle(for: Self.self))
        XCTAssertFalse(updater.isConfigured)
        updater.startIfNeeded()
        XCTAssertFalse(updater.hasStarted)
    }
}
