// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Foundation
import Chevron7Kit
import Chevron7Integration
@testable import Chevron7App

@MainActor
final class IntegrationReadServiceTests: XCTestCase {
    func testStructuralProjectionNeverClaimsTrustedValidityOrQualification() throws {
        let signature = DocumentSignatureInfo(id: "s", signerDisplayName: "Signer", hasQualifiedTimestamp: true,
                                              state: .valid, certificateQualification: "QESIG",
                                              dataTimestamp: .init(isQualified: true))
        let result = IntegrationReadService.treeResult(SignatureTree(signatures: [signature]), validated: false)
        XCTAssertEqual(result["validationState"], .string("notValidated"))
        let projected = try XCTUnwrap(result["tree"]?["signatures"]?.array?.first)
        XCTAssertEqual(projected["state"], .string("notValidated"))
        XCTAssertEqual(projected["hasQualifiedTimestamp"], .bool(false))
        XCTAssertEqual(projected["certificateQualification"], .null)
        XCTAssertEqual(projected["dataTimestamp"]?["isQualified"], .bool(false))
    }

    func testNestedFailureAndUnknownAreNotValidAndUnsignedIsExplicit() {
        let nested = SignatureTree(signatures: [.init(id: "nested", signerDisplayName: "B", state: .unknown)])
        let tree = SignatureTree(signatures: [.init(id: "top", signerDisplayName: "A", state: .valid)], documents: [
            .init(name: "nested.pdf", content: .signed(.pdf, nested)),
            .init(name: "deep.asice", content: .skipped(.depthLimit))])
        let result = IntegrationReadService.treeResult(tree, validated: true)
        XCTAssertEqual(result["validationState"], .string("indeterminate"))
        XCTAssertEqual(result["signatureCount"], .number(2))
        XCTAssertEqual(result["unverifiedDocumentCount"], .number(1))
        XCTAssertEqual(result["tree"]?["documents"]?.array?.last?["reason"], .string("DEPTH_LIMIT"))
        XCTAssertEqual(IntegrationReadService.treeResult(SignatureTree(), validated: true)["validationState"], .string("unsigned"))
    }

    func testUnavailableValidationKeepsStructuralEvidenceWithoutValidVerdicts() async throws {
        let settings = makeSettingsStore()
        let tree = SignatureTree(signatures: [.init(id: "s", signerDisplayName: "A", state: .valid)])
        let provider = TreeProvider(inspect: .tree(tree), validate: .failed("offline"))
        await provider.releaseValidation()
        settings.useRealSigningProvider(provider)
        let service = IntegrationReadService(settingsStore: settings, validationBroker: IntegrationValidationBroker())
        let file = settings.storageRoot.appendingPathComponent("synthetic.pdf")
        try Data("%PDF-1.7\n%%EOF".utf8).write(to: file)
        let result = try await service.execute(method: "validate", arguments: ["file": .string(file.path)])
        XCTAssertEqual(result["validationState"], .string("indeterminate"))
        XCTAssertEqual(result["validationError"], .string("offline"))
        XCTAssertEqual(result["tree"]?["signatures"]?.array?.first?["state"], .string("notValidated"))
    }

    func testDemoCannotPretendAnUninspectedFileIsUnsigned() async {
        let settings = makeSettingsStore()
        settings.useRealSigningProvider(DemoSigningProvider())
        do {
            _ = try await IntegrationReadService(settingsStore: settings).execute(method: "inspect", arguments: ["file": .string("/unused.pdf")])
            XCTFail("Expected refusal")
        } catch { XCTAssertEqual((error as? IntegrationError)?.code, "ENGINE_UNAVAILABLE") }
    }

    func testRegisterPaginationIsStableAndReturnsMinimalFieldsWithoutWrites() async throws {
        let settings = makeSettingsStore()
        let first = record("first", time: 200), second = record("second", time: 100)
        settings.evidenceStore.upsert(first)
        settings.evidenceStore.upsert(second)
        let register = settings.storageRoot.appendingPathComponent("Evidence/register.json")
        let before = try Data(contentsOf: register)
        let service = IntegrationReadService(settingsStore: settings)
        let page = try await service.execute(method: "register.list", arguments: ["limit": .number(1)])
        let rows = try XCTUnwrap(page["records"]?.array)
        XCTAssertEqual(rows.first?["id"], .string(first.id.uuidString))
        XCTAssertNil(rows.first?["attestationXML"])
        XCTAssertNil(rows.first?["performingPersonName"])
        let cursor = try XCTUnwrap(page["nextCursor"]?.string)
        let next = try await service.execute(method: "register.list", arguments: ["limit": .number(1), "cursor": .string(cursor)])
        XCTAssertEqual(next["records"]?.array?.first?["id"], .string(second.id.uuidString))
        XCTAssertEqual(next["nextCursor"], .null)
        XCTAssertEqual(try Data(contentsOf: register), before)
        settings.evidenceStore.upsert(record("new", time: 300))
        do {
            _ = try await service.execute(method: "register.list", arguments: ["cursor": .string(cursor)])
            XCTFail("Expected stale page refusal")
        } catch { XCTAssertEqual((error as? IntegrationError)?.code, "CURSOR_EXPIRED") }
    }

    func testInvalidPaginationAndUnreadableRegisterDoNotLookEmpty() async throws {
        let service = IntegrationReadService(settingsStore: makeSettingsStore())
        for limit in [JSONValue.number(0), .number(101), .number(1.5), .string("25")] {
            do {
                _ = try await service.execute(method: "register.list", arguments: ["limit": limit])
                XCTFail("Expected invalid limit")
            } catch { XCTAssertEqual((error as? IntegrationError)?.code, "INVALID_ARGUMENTS") }
        }
        let broken = IntegrationReadService(settingsStore: try makeSettingsStoreWithUnreadableRegister())
        do {
            _ = try await broken.execute(method: "register.list", arguments: [:])
            XCTFail("Expected unavailable")
        } catch { XCTAssertEqual((error as? IntegrationError)?.code, "REGISTER_UNAVAILABLE") }
    }

    func testEZZKLookupUsesSavedModeAndDoesNotChangeRegisterOrLogin() async throws {
        let testTransport = ScriptedTransport([reply(0)])
        let productionTransport = ScriptedTransport([])
        let account = EZZKAccountController(mode: .production, credentialStore: MemoryCredentialStore(),
                                            transportFactory: { $0 == .sandbox ? testTransport : productionTransport },
                                            productionPolicy: .refused)
        let settings = makeSettingsStore(ezzkAccountController: account)
        let row = record("synthetic", time: 200)
        settings.evidenceStore.upsert(row)
        let register = settings.storageRoot.appendingPathComponent("Evidence/register.json")
        let before = try Data(contentsOf: register)
        let result = try await IntegrationReadService(settingsStore: settings)
            .execute(method: "ezzk.lookup", arguments: ["recordId": .string(row.id.uuidString)])
        XCTAssertEqual(result["mode"], .string("test"))
        XCTAssertEqual(result["isProcessed"], .bool(true))
        XCTAssertEqual(testTransport.operations, ["GetConversionRecordInformationPurpose"])
        XCTAssertEqual(productionTransport.requestCount, 0)
        XCTAssertEqual(account.mode, .production)
        XCTAssertEqual(try Data(contentsOf: register), before)
    }

    func testDuplicateLookupRetains106WhenTimeFilteredLookupCannotFindRecord() async throws {
        let transport = ScriptedTransport([reply(106), reply(105)])
        let account = EZZKAccountController(mode: .demo, credentialStore: MemoryCredentialStore(),
                                            transportFactory: { _ in transport }, productionPolicy: .refused)
        let settings = makeSettingsStore(ezzkAccountController: account)
        let row = record("synthetic", time: 200)
        settings.evidenceStore.upsert(row)
        let result = try await IntegrationReadService(settingsStore: settings)
            .execute(method: "ezzk.lookup", arguments: ["recordId": .string(row.id.uuidString)])
        XCTAssertEqual(result["code"], .number(106))
        XCTAssertEqual(result["timeFilteredCode"], .number(105))
        XCTAssertEqual(transport.requestCount, 2)
    }

    private func record(_ name: String, time: TimeInterval) -> EvidenceRecord {
        EvidenceRecord(status: .queuedForSubmission, direction: .paperToElectronic, originalName: name,
                       newDocumentName: "output.pdf", evidenceNumber: "1563-260824-1", fingerprintSHA256Hex: "ab",
                       attestationXML: "PRIVATE XML", conversionTime: Date(timeIntervalSince1970: time),
                       performingPersonName: "PRIVATE PERSON", securityElementCount: 0, totalPages: 1,
                       totalSheets: 1, ezzkMode: .test)
    }

    private func reply(_ code: Int) -> String {
        """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>
        <Result><Code>\(code)</Code><Description>Synthetic result</Description></Result>
        </s:Body></s:Envelope>
        """
    }
}
