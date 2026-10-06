// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

final class SettingsAdvancedStateTests: XCTestCase {
    func testDefaultsAreNotActive() {
        let settings = AppSettings()
        XCTAssertFalse(SettingsAdvancedState.ezzkModeIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.customTSAIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.avmServerIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.agpPortalIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.webSigningFolderIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.webSigningRetentionIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.aiProviderIsActive(settings))
    }

    func testOnlyTheTestModeIsAdvanced() {
        XCTAssertTrue(SettingsAdvancedState.ezzkModeIsActive(AppSettings(ezzkMode: .test)))
        XCTAssertFalse(SettingsAdvancedState.ezzkModeIsActive(AppSettings(ezzkMode: .production)))
    }

    func testSelectedCustomTSAIsActive() {
        let url = "https://tsa.example.sk/tsp"
        XCTAssertTrue(SettingsAdvancedState.customTSAIsActive(
            AppSettings(customTSAServers: [url], selectedTSAURL: url)))
        XCTAssertFalse(SettingsAdvancedState.customTSAIsActive(
            AppSettings(customTSAServers: [url])))
    }

    func testChangedServersAreActive() {
        XCTAssertTrue(SettingsAdvancedState.avmServerIsActive(AppSettings(avmBaseURL: "https://avm.example.sk/api/v1")))
        XCTAssertTrue(SettingsAdvancedState.agpPortalIsActive(AppSettings(agpBaseURL: "https://agp.example.sk")))
    }

    func testWebSigningCustomisationsAreActive() {
        XCTAssertTrue(SettingsAdvancedState.webSigningFolderIsActive(AppSettings(webSigningOutputPath: "~/Podpisy")))
        XCTAssertFalse(SettingsAdvancedState.webSigningFolderIsActive(AppSettings(webSigningOutputPath: "  ")))
        XCTAssertTrue(SettingsAdvancedState.webSigningRetentionIsActive(AppSettings(webSigningRetentionDays: 30)))
    }

    func testExternalAIProvidersAreActive() {
        for mode in [AppSettings.AIMode.omlxLocal, .ollamaLocal, .customAPIKey] {
            XCTAssertTrue(SettingsAdvancedState.aiProviderIsActive(AppSettings(aiMode: mode)), "\(mode)")
        }
        XCTAssertFalse(SettingsAdvancedState.aiProviderIsActive(AppSettings(aiMode: .disabled)))
    }
}
