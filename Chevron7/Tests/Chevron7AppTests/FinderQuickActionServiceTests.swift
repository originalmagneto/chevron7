// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class FinderQuickActionServiceTests: XCTestCase {
    private var services: URL!
    private var retired: [URL] = []

    override func setUpWithError() throws {
        services = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickActionServices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
        retired = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: services)
    }

    private func makeWorkflow(_ name: String, script: String?) throws -> URL {
        let workflow = services.appendingPathComponent(name, isDirectory: true)
        let resources = workflow.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if let script {
            try Data("#!/usr/bin/env bash\n".utf8).write(to: resources.appendingPathComponent(script))
        }
        return workflow
    }

    private func retire(legacyAppInstalled: Bool) -> [URL] {
        FinderQuickActionService.retireLegacyQuickActions(
            in: services,
            legacyAppInstalled: legacyAppInstalled,
            moveToTrash: { self.retired.append($0) }
        )
    }

    func testAutogramWorkflowIsRetiredWhenAutogramMacOSIsGone() throws {
        let legacy = try makeWorkflow("Autogram Finder Quick Action.workflow", script: "autogram-cli-sign.sh")

        XCTAssertEqual(retire(legacyAppInstalled: false), [legacy])
        XCTAssertEqual(retired, [legacy])
    }

    func testAutogramWorkflowStaysWhileAutogramMacOSCanStillRunIt() throws {
        _ = try makeWorkflow("Autogram Finder Quick Action.workflow", script: "autogram-cli-sign.sh")

        XCTAssertEqual(retire(legacyAppInstalled: true), [])
        XCTAssertEqual(retired, [])
    }

    func testWorkflowWithoutAutogramScriptIsNeverTouched() throws {
        // Same name, but not the workflow Autogram macOS installed: the person's own.
        _ = try makeWorkflow("Autogram Finder Quick Action.workflow", script: "something-else.sh")
        _ = try makeWorkflow("Sign with Autogram.workflow", script: nil)

        XCTAssertEqual(retire(legacyAppInstalled: false), [])
        XCTAssertEqual(retired, [])
    }

    func testChevron7WorkflowIsNeverRetired() throws {
        _ = try makeWorkflow(FinderQuickActionService.workflowInstallName, script: "chevron7-cli-sign.sh")

        XCTAssertEqual(retire(legacyAppInstalled: false), [])
    }

    private var chevron7Key: String { "(null) - \(FinderQuickActionService.menuTitle) - runWorkflowAsService" }

    private func modes(_ statuses: [String: Any], _ key: String) -> [String: Int]? {
        (statuses[key] as? [String: Any])?["presentation_modes"] as? [String: Int]
    }

    func testFreshInstallIsShownInFindersQuickActionsAndContextMenu() {
        let statuses = FinderQuickActionService.servicesStatus(updating: [:])

        XCTAssertEqual(modes(statuses, chevron7Key), [
            "ContextMenu": 1, "FinderPreview": 1, "ServicesMenu": 1, "TouchBar": 1
        ])
    }

    func testEntryWrittenByEarlierBuildsIsUpgraded() {
        // Earlier builds wrote only the pre-Mojave keys, which Finder's Quick Actions ignore.
        let old: [String: Any] = [chevron7Key: ["enabled_context_menu": 1, "enabled_services_menu": 1]]

        let statuses = FinderQuickActionService.servicesStatus(updating: old)

        XCTAssertEqual(modes(statuses, chevron7Key)?["FinderPreview"], 1)
        XCTAssertEqual(modes(statuses, chevron7Key)?["ContextMenu"], 1)
    }

    func testPersonsOwnChoiceIsKept() {
        let chosen: [String: Any] = [chevron7Key: ["presentation_modes": [
            "ContextMenu": 0, "FinderPreview": 0, "ServicesMenu": 1, "TouchBar": 0
        ]]]

        let statuses = FinderQuickActionService.servicesStatus(updating: chosen)

        XCTAssertEqual(modes(statuses, chevron7Key)?["FinderPreview"], 0)
    }

    func testOtherServicesAreUntouchedAndRetiredAutogramEntryIsDropped() {
        let autogramKey = "(null) - Podpísať s QES + QTS (Autogram) - runWorkflowAsService"
        let other: [String: Any] = [
            "(null) - Word to PDF - runWorkflowAsService": ["presentation_modes": ["TouchBar": 0]],
            autogramKey: ["enabled_context_menu": 1]
        ]

        let statuses = FinderQuickActionService.servicesStatus(updating: other, droppingLegacyEntries: true)

        XCTAssertEqual(modes(statuses, "(null) - Word to PDF - runWorkflowAsService"), ["TouchBar": 0])
        XCTAssertNil(statuses[autogramKey])
        XCTAssertEqual(
            FinderQuickActionService.servicesStatus(updating: other, droppingLegacyEntries: false)[autogramKey] as? [String: Int],
            ["enabled_context_menu": 1]
        )
    }

    func testMissingServicesFolderRetiresNothing() throws {
        try FileManager.default.removeItem(at: services)

        XCTAssertEqual(retire(legacyAppInstalled: false), [])
    }

    func testVisibilityNeedsTheWorkflow() {
        XCTAssertEqual(FinderQuickActionService.visibility(workflowInstalled: false, statuses: [:]), .notInstalled)
    }

    func testVisibleWhenFinderShowsItInTheContextMenu() {
        let statuses = FinderQuickActionService.servicesStatus(updating: [:])
        XCTAssertEqual(FinderQuickActionService.visibility(workflowInstalled: true, statuses: statuses), .visible)
    }

    func testHiddenWhenThePersonUnchecksIt() {
        let key = "(null) - \(FinderQuickActionService.menuTitle) - runWorkflowAsService"
        let statuses: [String: Any] = [key: ["presentation_modes": ["ContextMenu": 0, "ServicesMenu": 0]]]
        XCTAssertEqual(FinderQuickActionService.visibility(workflowInstalled: true, statuses: statuses), .hiddenInFinder)
    }

    func testHiddenWithoutAModernEntry() {
        XCTAssertEqual(FinderQuickActionService.visibility(workflowInstalled: true, statuses: [:]), .hiddenInFinder)
    }
}
