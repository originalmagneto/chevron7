// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import SwiftUI
import XCTest
import Chevron7Kit
import Chevron7TestSupport
@testable import Chevron7App

/// 1.4.3 crashed when the signing window with the inspector was resized to 1200 x 788:
/// the main window's `.frame(minWidth: 760)` let it shrink below sidebar + content +
/// inspector, and AppKit threw "more Update Constraints in Window passes than there are
/// views". These tests host the signing screen in the main window's split view and resize it.
@MainActor
final class SigningWindowResizeTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    func testFloorRaisesOnlyASmallerMinimum() {
        let floor = CGSize(width: 760, height: 640)
        XCTAssertEqual(MinimumSizeFloor.raise(CGSize(width: 300, height: 200), to: floor), floor)
        XCTAssertEqual(MinimumSizeFloor.raise(CGSize(width: 1064, height: 311), to: floor),
                       CGSize(width: 1064, height: 640))
        XCTAssertEqual(MinimumSizeFloor.raise(CGSize(width: 1200, height: 900), to: floor),
                       CGSize(width: 1200, height: 900))
    }

    func testSigningScreenWithSidebarAndInspectorSurvivesShrinkingTheWindow() async throws {
        let store = try await signingStore()
        let window = host(store: store)
        try await settle()

        for size in [(1200, 788), (1100, 760), (1060, 740), (1000, 700), (900, 680), (760, 640), (600, 500)] {
            try await resize(window, to: size)
        }
        XCTAssertGreaterThan(window.contentMinSize.width, MacOS27Layout.rootMinimumWidth,
                             "with the sidebar and the inspector the window needs more than the floor")
    }

    /// The sidebar hidden with the toolbar button collapses AppKit's split view item
    /// (`RootView.toggleSidebar`); the window may then shrink to the floor.
    func testSigningScreenWithSidebarHiddenFromTheToolbarSurvivesShrinkingTheWindow() async throws {
        let store = try await signingStore()
        let window = host(store: store)
        try await settle()
        let sidebarSplit = try XCTUnwrap(splitViewControllers(in: window.contentView).first {
            $0.splitViewItems.contains { $0.behavior == .sidebar }
        })
        sidebarSplit.toggleSidebar(nil)
        try await settle()
        XCTAssertTrue(try XCTUnwrap(sidebarSplit.splitViewItems.first { $0.behavior == .sidebar }).isCollapsed)

        for size in [(1200, 788), (1000, 700), (900, 680), (800, 650), (760, 640), (600, 500)] {
            try await resize(window, to: size)
        }
    }

    /// A document opened while the window is at the floor brings the inspector: the window
    /// has to grow to fit it rather than squeeze the content below its minimum.
    func testOpeningADocumentInANarrowWindowGrowsIt() async throws {
        let store = try await signingStore(openDocument: false)
        let window = host(store: store)
        try await settle()
        try await resize(window, to: (760, 640))

        try await open(document(), in: store)
        try await settle()

        assertFits(window)
        XCTAssertGreaterThan(window.frame.width, MacOS27Layout.rootMinimumWidth)
    }

    // MARK: - Helpers

    private func signingStore(openDocument: Bool = true) async throws -> SigningSessionStore {
        let settings = makeSettingsStore()
        settings.useRealSigningProvider(DemoSigningProvider())
        let recent = RecentDocumentStore(settingsStore: settings, defaults: MemoryUserDefaults())
        let store = SigningSessionStore(signingProvider: settings.signingProvider, settingsStore: settings,
                                        recentDocumentStore: recent)
        if openDocument { try await open(document(), in: store) }
        return store
    }

    private func document() throws -> URL {
        let url = makeTemporaryDirectory("resize").appendingPathComponent("zmluva.pdf")
        try TestPDFBuilderApp.typicalContractPDF().write(to: url)
        return url
    }

    /// The document as the crash had it: on the signing screen with a validated tree of two
    /// existing signatures in the inspector.
    private func open(_ url: URL, in store: SigningSessionStore) async throws {
        await store.addDocuments(at: [url])
        XCTAssertEqual(store.step, .prepare)
        store.existingSignatureState = SignatureTreeState(
            tree: SignatureTree(signatures: [
                DocumentSignatureInfo(id: "S-1", signerDisplayName: "Mgr. Ján Vzorový, advokát",
                                      format: "PAdES_BASELINE_T", signingTime: Date(),
                                      hasQualifiedTimestamp: true, state: .valid,
                                      certificateQualification: "QESIG"),
                DocumentSignatureInfo(id: "S-2", signerDisplayName: "Ing. Eva Vzorová",
                                      format: "PAdES_BASELINE_B", signingTime: Date(), state: .valid,
                                      certificateQualification: "QESIG"),
            ]),
            phase: .validated)
    }

    /// The main window's composition (`Chevron7App`, `RootView`) around the real signing
    /// screen, with the toolbar and title bridged into the window as the scene does.
    private func host(store: SigningSessionStore) -> NSWindow {
        let root = NavigationSplitView {
            List { Text("Podpisovanie") }
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            SigningFlowView(store: store)
                .navigationTitle("Podpisovanie")
                .navigationSubtitle("nastavenie podpisu · demo")
        }
        .minimumSizeFloor(width: MacOS27Layout.rootMinimumWidth, height: MacOS27Layout.rootMinimumHeight)
        .frame(idealWidth: 1320, idealHeight: 860)

        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1835, height: 1082),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1835, height: 1082))
        window.orderFront(nil)
        self.window = window
        return window
    }

    private func splitViewControllers(in view: NSView?) -> [NSSplitViewController] {
        guard let view else { return [] }
        let own = ((view as? NSSplitView)?.delegate as? NSSplitViewController).map { [$0] } ?? []
        return own + view.subviews.flatMap { splitViewControllers(in: $0) }
    }

    private func resize(_ window: NSWindow, to size: (Int, Int)) async throws {
        window.setFrame(NSRect(x: 100, y: 100, width: size.0, height: size.1), display: true)
        try await settle()
        assertFits(window)
    }

    private func assertFits(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let content = window.contentRect(forFrameRect: window.frame).size
        XCTAssertGreaterThanOrEqual(content.width, window.contentMinSize.width, file: file, line: line)
        XCTAssertGreaterThanOrEqual(content.height, window.contentMinSize.height, file: file, line: line)
    }

    /// A few display cycles: the crash came from AppKit's update-constraints pass.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }
}
