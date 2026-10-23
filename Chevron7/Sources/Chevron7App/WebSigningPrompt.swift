// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Identity
import SwiftUI
import os

private final class WebSigningPanelDelegate: NSObject, NSWindowDelegate {
    private weak var coordinator: WebSigningCoordinator?

    init(coordinator: WebSigningCoordinator) {
        self.coordinator = coordinator
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.cancel()
    }

}

/// What the coordinator needs from the signing panel; tests pass one that shows nothing.
@MainActor
protocol WebSigningPromptPresenting: AnyObject {
    func show(coordinator: WebSigningCoordinator)
    func focus()
    func beginMiddlewareInput()
    func endMiddlewareInput()
    func hide()
}

/// Shows the browser signing prompt in a floating panel instead of a sheet.
///
/// A sheet lives on the app's own window, and since macOS Sonoma an app in the
/// background cannot reliably pull itself in front: `activate(ignoringOtherApps:)`
/// is deprecated and the system grants it only sometimes. The request would then
/// sit behind Safari with nothing to show for it.
///
/// A panel ordered front regardless of activation appears over the browser
/// without stealing the keyboard. Clicking it activates the app the ordinary
/// way, which is what every password prompt on this platform does. It is
/// centered over Safari's front window (`WebSigningPanelPlacement`), so it
/// covers the portal's own waiting modal instead of sitting beside it.
@MainActor
final class WebSigningPrompt: WebSigningPromptPresenting {
    private var panel: NSPanel?
    private var delegate: WebSigningPanelDelegate?
    private var middlewareInputDepth = 0
    private let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "web-signing")
    /// Its own handoff: the panel orders itself beneath the BOK window and hands
    /// activation to the browser when it closes, never back to this app.
    private let keyboardHandoff = EIDKeyboardHandoff(reclaimsActivation: false)
    /// The app in front when the request arrived, normally Safari; it gets the
    /// keyboard back when the panel closes (`WebSigningFocusReturn`).
    private var requester: NSRunningApplication?

    func show(coordinator: WebSigningCoordinator) {
        if let panel {
            place(panel)
            panel.orderFrontRegardless()
            return
        }

        requester = NSWorkspace.shared.frontmostApplication
        let hosting = NSHostingView(rootView: WebSigningSheet(coordinator: coordinator))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: max(size.width, 900), height: max(size.height, 600))),
            styleMask: [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // The brand header runs under the title bar and carries the title itself;
        // the window keeps it for Mission Control and VoiceOver.
        panel.title = "Podpísať dokument zo stránky"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 860, height: 560)
        place(panel)

        let delegate = WebSigningPanelDelegate(coordinator: coordinator)
        panel.delegate = delegate
        self.delegate = delegate
        self.panel = panel

        // Over Safari at the floating level the panel is visible at once, so it no
        // longer bounces the Dock icon, which a web-signing launch does not even show.
        panel.orderFrontRegardless()
    }

    private func place(_ panel: NSPanel) {
        let screens = NSScreen.screens.map {
            WebSigningPanelPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let origin = WebSigningPanelPlacement.origin(panelSize: panel.frame.size,
                                                     safariQuartzBounds: Self.safariFrontWindowBounds(),
                                                     screens: screens,
                                                     mouseLocation: NSEvent.mouseLocation)
        panel.setFrameOrigin(origin)
    }

    /// Front on-screen Safari window, in Quartz coordinates. Window bounds need no
    /// Screen Recording permission; only window titles would.
    private static func safariFrontWindowBounds() -> CGRect? {
        let safariPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
            .map(\.processIdentifier))
        guard !safariPIDs.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, safariPIDs.contains(pid),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 200, bounds.height > 200 else { continue }
            return bounds
        }
        return nil
    }

    /// Moves the keyboard to the PIN field's window, when the system allows it.
    ///
    /// An app in the background cannot take the keyboard since macOS Sonoma, so
    /// this only helps once the person has clicked the prompt or the app.
    func focus() {
        guard let panel, NSApp.isActive else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Steps aside while the eID client asks for the BOK.
    ///
    /// The panel drops to the normal level so it cannot cover the eID client's BOK
    /// window, and `EIDKeyboardHandoff` activates that window, keeping the panel
    /// just beneath it rather than letting it drop behind the browser.
    func beginMiddlewareInput() {
        middlewareInputDepth += 1
        guard middlewareInputDepth == 1 else { return }
        panel?.level = .normal
        keyboardHandoff.onKeyboardWindow = { [weak self] window in
            self?.panel?.order(.below, relativeTo: window)
        }
        keyboardHandoff.begin()
    }

    func endMiddlewareInput() {
        guard middlewareInputDepth > 0 else { return }
        middlewareInputDepth -= 1
        guard middlewareInputDepth == 0 else { return }
        keyboardHandoff.end()
        guard let panel else { return }
        panel.level = .floating
        // Closing the BOK window hands activation back to this app, which raises
        // its main window over the prompt; the prompt takes the front and keyboard back.
        if NSApp.isActive {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        WebSigningQuickLook.shared.close()
        keyboardHandoff.reset()
        middlewareInputDepth = 0
        // Before the panel closes: closing the key panel of the active app would
        // first bring up the main window over the browser.
        returnActivationToRequester()
        panel?.delegate = nil
        panel?.close()
        panel = nil
        delegate = nil
        requester = nil
    }

    /// Gives activation back to the browser that asked, when this app took it
    /// during the request (a click on the panel, the PIN, the BOK handoff). An
    /// activated app orders all its windows front, so without this the main
    /// window, or after a `--web-signing` launch no window at all, held the
    /// keyboard once the panel closed.
    private func returnActivationToRequester() {
        let running = NSWorkspace.shared.runningApplications
        let pid = WebSigningFocusReturn.target(requester: requester.map(Self.snapshot),
                                               running: running.map(Self.snapshot),
                                               ownProcessIdentifier: NSRunningApplication.current.processIdentifier,
                                               isActive: NSApp.isActive)
        guard let pid, let app = running.first(where: { $0.processIdentifier == pid }) else { return }
        NSApp.yieldActivation(to: app)
        let accepted = app.activate(from: .current, options: [])
        log.notice("""
            Activation returned pid=\(pid, privacy: .public) \
            bundle=\(app.bundleIdentifier ?? "-", privacy: .public) accepted=\(accepted, privacy: .public)
            """)
    }

    private static func snapshot(_ app: NSRunningApplication) -> WebSigningFocusReturn.App {
        WebSigningFocusReturn.App(processIdentifier: app.processIdentifier,
                                  bundleIdentifier: app.bundleIdentifier,
                                  executableURL: app.executableURL,
                                  isTerminated: app.isTerminated)
    }
}

