// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Identity
@testable import Chevron7Kit
@testable import Chevron7WebBridge

/// Every name macOS knows the product by. The literals are repeated on purpose:
/// build_app.sh and the scripts carry the same strings, and a changed value here
/// must be changed there too.
final class ProductIdentityTests: XCTestCase {
    func testBundleNamesShareOnePrefix() {
        XCTAssertEqual(ProductIdentity.name, "Chevron7")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "app.slovensko.chevron7")
        XCTAssertEqual(ProductIdentity.webExtensionBundleIdentifier, "app.slovensko.chevron7.WebExtension")
        XCTAssertEqual(ProductIdentity.webBridgeServiceName, "app.slovensko.chevron7.webbridge")
        XCTAssertEqual(ProductIdentity.webBridgeAgentIdentifier, "chevron7-webbridge-agent")
        XCTAssertEqual(ProductIdentity.webBridgeProbeIdentifier, "webbridge-probe")
        XCTAssertEqual(ProductIdentity.urlScheme, "chevron7")
        XCTAssertEqual(ProductIdentity.installedAppURL.path, "/Applications/Chevron7.app")
    }

    func testWebBridgeUsesTheIdentity() {
        XCTAssertEqual(WebSigningBridge.machServiceName, "app.slovensko.chevron7.webbridge")
        XCTAssertEqual(WebSigningBridge.agentLabel, "app.slovensko.chevron7.webbridge")
    }

    func testDataRootsAreNamedAfterTheProduct() {
        XCTAssertEqual(ProductIdentity.applicationSupportDirectory().lastPathComponent, "Chevron7")
        XCTAssertEqual(ProductIdentity.applicationSupportDirectory().deletingLastPathComponent().lastPathComponent, "Application Support")
        XCTAssertEqual(ProductIdentity.cachesDirectory().lastPathComponent, "Chevron7")
        XCTAssertEqual(ProductIdentity.cachesDirectory().deletingLastPathComponent().lastPathComponent, "Caches")
    }

    func testURLSchemeAndInstallPathFollowTheIdentity() {
        XCTAssertEqual(EZZKOAuthConfiguration.nativeCallbackScheme, "chevron7")
        XCTAssertEqual(EZZKOAuthConfiguration.nativeRedirectURI.absoluteString, "chevron7://ezzk/callback")
        XCTAssertEqual(JavaEngineLocator.defaultRoots, ["/Applications/Chevron7.app/Contents"])
        XCTAssertEqual(JavaEngineLocator.environmentKey, "CHEVRON7_JAVA_ENGINE_ROOT")
    }

    @MainActor
    func testStoredStateLivesUnderTheIdentity() {
        let root = ProductIdentity.applicationSupportDirectory()
        XCTAssertEqual(ExampleBank.defaultDirectory, root.appendingPathComponent("VisionBank", isDirectory: true))
        XCTAssertEqual(EZZKSOAPCredentialStore.keychainService, "app.slovensko.chevron7.ezzk.soap")
        XCTAssertEqual(EZZKTokenStore.keychainService, "app.slovensko.chevron7.ezzk.oauth.tokens")
        XCTAssertEqual(KeychainStore.service, "app.slovensko.chevron7")
        XCTAssertEqual(AppSettings.storageKey, "app.slovensko.chevron7.settings.v1")
        XCTAssertEqual(SignaturePlacementState.preferencesKey, "app.slovensko.chevron7.visibleSignature")
    }

    func testSignatureArtworkSharesTheDataRoot() {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SignatureAssetStore(applicationSupportRoot: work)
        XCTAssertEqual(store.assetsDirectory.standardizedFileURL.path,
                       work.appendingPathComponent("Chevron7/Visual Signatures").standardizedFileURL.path)
    }
}
