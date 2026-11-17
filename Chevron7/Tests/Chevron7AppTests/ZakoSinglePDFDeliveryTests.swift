// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
@testable import Chevron7App

private struct StubRenderer: ClausePageRendering {
    let pages: Data
    @MainActor func render(clauseXML: Data, form: OfficialForm) async throws -> Data { pages }
}

private struct StubProvider: QualifiedSigningProviding {
    var supportsAppendedClause: Bool
    func availableIdentities() async -> [SigningIdentityInfo] { [] }
    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.signingFailed("stub")
    }
}

@MainActor
final class ZakoSinglePDFDeliveryTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func touch(_ name: String, in dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    func testFixedTargetKeepsFreeName() throws {
        let dir = try makeDirectory()
        let url = ZakoSinglePDFDelivery.fixedTarget(in: dir, containerDocumentName: "Zmluva.pdf")
        XCTAssertEqual(url.lastPathComponent, "Zmluva.pdf")
    }

    func testFixedTargetAvoidsSourceName() throws {
        let dir = try makeDirectory()
        try touch("Zmluva.pdf", in: dir)
        let url = ZakoSinglePDFDelivery.fixedTarget(in: dir, containerDocumentName: "Zmluva.pdf")
        XCTAssertEqual(url.lastPathComponent, "Zmluva-konvertovane.pdf")
    }

    func testFixedTargetFallsBackToUnique() throws {
        let dir = try makeDirectory()
        try touch("Zmluva.pdf", in: dir)
        try touch("Zmluva-konvertovane.pdf", in: dir)
        let url = ZakoSinglePDFDelivery.fixedTarget(in: dir, containerDocumentName: "Zmluva.pdf")
        XCTAssertEqual(url.lastPathComponent, "Zmluva-konvertovane (2).pdf")
    }

    func testRefusesProductionWhilePolicyOff() {
        XCTAssertFalse(SinglePDFProductionPolicy.enabled)
        XCTAssertEqual(ZakoSinglePDFDelivery.refusal(mode: .production, viaMobile: false,
                                                     provider: StubProvider(supportsAppendedClause: true)),
                       SinglePDFProductionPolicy.refusalMessage)
    }

    func testRefusesPhone() {
        XCTAssertEqual(ZakoSinglePDFDelivery.refusal(mode: .test, viaMobile: true,
                                                     provider: StubProvider(supportsAppendedClause: true)),
                       ZakoSinglePDFDelivery.mobileRefusal)
    }

    func testRefusesProviderWithoutAppend() {
        XCTAssertEqual(ZakoSinglePDFDelivery.refusal(mode: .test, viaMobile: false,
                                                     provider: StubProvider(supportsAppendedClause: false)),
                       "Jeden PDF s doložkou vyžaduje podpisový engine Chevron7.")
    }

    func testAllowsDemoAndTest() {
        let provider = StubProvider(supportsAppendedClause: true)
        XCTAssertNil(ZakoSinglePDFDelivery.refusal(mode: .demo, viaMobile: false, provider: provider))
        XCTAssertNil(ZakoSinglePDFDelivery.refusal(mode: .test, viaMobile: false, provider: provider))
    }

    func testAppendedClauseCarriesXdcBytesAndName() async throws {
        let pages = Data("pages".utf8)
        let xdc = Data("xdc".utf8)
        let clause = try await ZakoSinglePDFDelivery.appendedClause(
            clauseXML: Data("<x/>".utf8), clauseXDCF: xdc, clauseFileName: "ZK1.xml.xdcf",
            form: .clause_1_3, renderer: StubRenderer(pages: pages))
        XCTAssertEqual(clause.pages, pages)
        XCTAssertEqual(clause.attachment, xdc)
        XCTAssertEqual(clause.attachmentName, "ZK1.xml.xdcf")
        XCTAssertEqual(clause.attachmentMimeType, AppendedClause.xdcMimeType)
    }
}
