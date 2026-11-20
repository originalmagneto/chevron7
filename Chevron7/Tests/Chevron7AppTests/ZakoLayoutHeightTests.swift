// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import SwiftUI
import XCTest
import Chevron7Kit
@testable import Chevron7App

/// The ZaKo steps never ask for more height than a window has: a text squeezed into the
/// authorization action bar once grew the step to 1143 points and hid "Autorizovať".
@MainActor
final class ZakoLayoutHeightTests: XCTestCase {
    /// The smallest size the hosting window accepts for the view.
    private func minimumSize<V: View>(_ view: V) -> CGSize {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1000, height: 300))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.view.layoutSubtreeIfNeeded()
        return window.contentMinSize
    }

    func testAuthorizationOutsideDemoWithMobileSigningFitsASmallWindow() {
        let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in ScriptedTransport([]) },
                                               productionPolicy: .refused)
        let settingsStore = makeSettingsStore(ezzkAccountController: controller)
        let original = settingsStore.settings
        addTeardownBlock { await MainActor.run { settingsStore.settings = original } }
        settingsStore.settings.mobileSigningEnabled = true
        let store = ZakoSessionStore(settingsStore: settingsStore)
        store.step = .authorize
        // The notice shows until 1. 1. 2027 (the record-first order then refuses the phone and
        // hides it); the step must fit either way.
        XCTAssertEqual(store.showsMobileOutsideDemoNotice, store.mobileRefusalForClientOutput == nil)

        let size = minimumSize(ZakoFlowView(store: store))

        XCTAssertLessThan(size.height, 300, "the authorization step must not need more height than a small window")
    }
}
