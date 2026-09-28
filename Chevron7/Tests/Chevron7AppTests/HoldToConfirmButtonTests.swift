// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import SwiftUI
import XCTest
@testable import Chevron7App

/// Exercises the hosted hold control with real mouse events: a short press
/// and a drag-away must not commit, a full hold commits exactly once, and a
/// cancelled press can be retried. Store tests cannot cover this interaction.
@MainActor
final class HoldToConfirmButtonTests: XCTestCase {
    private var window: NSWindow!
    private var committed = 0
    private var transitions: [Bool] = []
    private var nextEventNumber = 0

    private func host(duration: TimeInterval = 0.3) {
        committed = 0
        transitions = []
        let view = HoldToConfirmButton(
            title: "Autorizovať", systemImage: "checkmark",
            duration: duration, disabled: false, isWorking: false,
            pressingObserver: { self.transitions.append($0) }
        ) { self.committed += 1 }
            // The frame only centers the capsule: the hit shape under test is
            // the control's own contentShape, nothing added here.
            .frame(width: 300, height: 60)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump(0.2)
    }

    private var pressPoint: NSPoint { NSPoint(x: 150, y: 30) }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: nextEventNumber, clickCount: 1, pressure: 1)!
        nextEventNumber += 1
        NSApplication.shared.sendEvent(event)
    }
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    func testShortPressDoesNotCommit() {
        host()
        mouse(.leftMouseDown, at: pressPoint)
        pump(0.1)
        mouse(.leftMouseUp, at: pressPoint)
        pump(0.3)
        XCTAssertEqual(committed, 0)
        // Cancellation resets pressing, which rewinds the fill in the same step.
        XCTAssertEqual(transitions, [true, false])
    }

    func testFullHoldCommitsExactlyOnce() {
        host()
        mouse(.leftMouseDown, at: pressPoint)
        pump(0.6)
        mouse(.leftMouseUp, at: pressPoint)
        pump(0.2)
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(transitions.first, true)
        XCTAssertEqual(transitions.last, false)
    }

    func testDragAwayCancels() {
        host()
        mouse(.leftMouseDown, at: pressPoint)
        pump(0.1)
        mouse(.leftMouseDragged, at: NSPoint(x: 290, y: 30))
        pump(0.1)
        mouse(.leftMouseUp, at: NSPoint(x: 290, y: 30))
        pump(0.3)
        XCTAssertEqual(committed, 0)
        XCTAssertEqual(transitions, [true, false])
    }

    func testRetryAfterCancelCommits() {
        host()
        mouse(.leftMouseDown, at: pressPoint)
        pump(0.1)
        mouse(.leftMouseUp, at: pressPoint)
        pump(0.2)
        XCTAssertEqual(committed, 0)
        mouse(.leftMouseDown, at: pressPoint)
        pump(0.6)
        mouse(.leftMouseUp, at: pressPoint)
        pump(0.2)
        XCTAssertEqual(committed, 1)
    }

    /// A press outside the rendered capsule reaches no gesture at all: the hit
    /// shape is the capsule, not the window.
    func testPressOutsideCapsuleDoesNothing() {
        host()
        mouse(.leftMouseDown, at: NSPoint(x: 10, y: 10))
        pump(0.6)
        mouse(.leftMouseUp, at: NSPoint(x: 10, y: 10))
        pump(0.2)
        XCTAssertEqual(committed, 0)
        XCTAssertEqual(transitions, [])
    }
}
