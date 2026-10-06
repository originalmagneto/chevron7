// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class WebSigningFocusReturnTests: XCTestCase {
    private let own: pid_t = 100
    private let chevron7 = WebSigningFocusReturn.App(processIdentifier: 100, bundleIdentifier: "app.slovensko.chevron7")
    private let safari = WebSigningFocusReturn.App(processIdentifier: 200, bundleIdentifier: "com.apple.Safari")
    private let mail = WebSigningFocusReturn.App(processIdentifier: 300, bundleIdentifier: "com.apple.mail")
    private let keyboard = WebSigningFocusReturn.App(processIdentifier: 400, bundleIdentifier: nil,
                                                     executableName: "VirtualKeyboard")

    func testReturnsActivationToTheBrowserThatAsked() {
        let target = WebSigningFocusReturn.target(requester: safari, running: [chevron7, mail, safari],
                                                  ownProcessIdentifier: own, isActive: true)
        XCTAssertEqual(target, safari.processIdentifier)
    }

    func testLeavesActivationAloneWhenChevron7DoesNotHoldIt() {
        // The person never clicked the panel, or switched to another app meanwhile.
        let target = WebSigningFocusReturn.target(requester: safari, running: [chevron7, safari],
                                                  ownProcessIdentifier: own, isActive: false)
        XCTAssertNil(target)
    }

    func testPrefersTheRequesterOverAnotherRunningSafari() {
        let other = WebSigningFocusReturn.App(processIdentifier: 210, bundleIdentifier: "com.apple.Safari")
        let target = WebSigningFocusReturn.target(requester: safari, running: [other, safari],
                                                  ownProcessIdentifier: own, isActive: true)
        XCTAssertEqual(target, safari.processIdentifier)
    }

    func testFallsBackToSafariWhenTheRequesterQuit() {
        let quit = WebSigningFocusReturn.App(processIdentifier: 300, bundleIdentifier: "com.apple.mail",
                                             isTerminated: true)
        let target = WebSigningFocusReturn.target(requester: mail, running: [chevron7, quit, safari],
                                                  ownProcessIdentifier: own, isActive: true)
        XCTAssertEqual(target, safari.processIdentifier)
    }

    func testFallsBackToSafariWhenChevron7WasFrontmost() {
        // The main window was in front when the portal asked.
        let target = WebSigningFocusReturn.target(requester: chevron7, running: [chevron7, safari],
                                                  ownProcessIdentifier: own, isActive: true)
        XCTAssertEqual(target, safari.processIdentifier)
    }

    func testNeverReturnsToTheEIDKeyboard() {
        let target = WebSigningFocusReturn.target(requester: keyboard, running: [chevron7, keyboard, safari],
                                                  ownProcessIdentifier: own, isActive: true)
        XCTAssertEqual(target, safari.processIdentifier)
    }

    func testNothingToReturnToWithoutABrowser() {
        let target = WebSigningFocusReturn.target(requester: nil, running: [chevron7, mail],
                                                  ownProcessIdentifier: own, isActive: true)
        XCTAssertNil(target)
    }
}
