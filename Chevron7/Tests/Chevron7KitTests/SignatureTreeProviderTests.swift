// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

final class SignatureTreeProviderTests: XCTestCase {
    private func sourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-\(UUID().uuidString).asice")
        try Data("PK\u{3}\u{4}".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let tree = SignatureTree(
        signatures: [DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .valid)],
        documents: [SignedDataObject(name: "report.pdf", content: .plain)])

    func testInspectAndValidateReturnTheEngineTree() async throws {
        let engine = TreeEngine(inspectTree: tree, validateTree: tree)
        let provider = EngineBridgeSigningProvider(engine: engine)
        let url = try sourceFile()

        let inspected = await provider.inspectSignatureTree(in: url)
        let validated = await provider.validateSignatureTree(in: url)

        XCTAssertEqual(inspected, .tree(tree))
        XCTAssertEqual(validated, .tree(tree))
    }

    func testValidationFailureIsReportedNotEmpty() async throws {
        let engine = TreeEngine(inspectTree: tree, validateError: SigningFailure.engine("TRUSTED_LIST_UNAVAILABLE"))
        let provider = EngineBridgeSigningProvider(engine: engine)

        let validated = await provider.validateSignatureTree(in: try sourceFile())

        guard case .failed(let reason) = validated else { return XCTFail("expected failure") }
        XCTAssertEqual(reason, "Dôveryhodné zoznamy nie sú dostupné. Výsledok je len štrukturálny.")
    }

    func testTimeoutIsReportedInSlovak() async throws {
        let engine = TreeEngine(inspectTree: tree, validateError: CLIProcessFailure.timedOut)
        let provider = EngineBridgeSigningProvider(engine: engine)

        let validated = await provider.validateSignatureTree(in: try sourceFile())

        XCTAssertEqual(validated, .failed("Overenie podpisov trvalo príliš dlho. Výsledok je len štrukturálny."))
    }

    /// An error without a known code never reaches the user as raw English.
    func testUnknownValidationErrorIsReportedInSlovak() async throws {
        let engine = TreeEngine(inspectTree: tree, validateError: MachineSessionProcessFailure.helperExited(status: 1))
        let provider = EngineBridgeSigningProvider(engine: engine)

        let validated = await provider.validateSignatureTree(in: try sourceFile())

        XCTAssertEqual(validated, .failed("Overenie podpisov zlyhalo. Výsledok je len štrukturálny."))
    }

    func testUnknownErrorFallbackIsSlovak() {
        let reason = EngineBridgeSigningProvider.treeFailureReason(
            NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Something broke"]))

        XCTAssertEqual(reason, "Overenie podpisov zlyhalo. Výsledok je len štrukturálny.")
    }

    func testHungValidationTimesOut() async throws {
        executionTimeAllowance = 30
        let engine = TreeEngine(inspectTree: tree, validateHangs: true)
        let provider = EngineBridgeSigningProvider(engine: engine, validationTimeout: .milliseconds(300))
        let url = try sourceFile()

        let started = ContinuousClock.now
        let validated = await provider.validateSignatureTree(in: url)

        XCTAssertEqual(validated, .failed("Overenie podpisov trvalo príliš dlho. Výsledok je len štrukturálny."))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    }

    func testMissingFileFails() async {
        let provider = EngineBridgeSigningProvider(engine: TreeEngine(inspectTree: tree))
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf")

        let result = await provider.inspectSignatureTree(in: missing)

        guard case .failed = result else { return XCTFail("expected failure") }
    }

    func testDefaultProviderHasNoFullValidation() async throws {
        let result = await DemoSigningProvider().validateSignatureTree(in: try sourceFile())

        XCTAssertEqual(result, .failed("Plné overenie vyžaduje podpisový engine."))
    }
}

private final class TreeEngine: SigningEngine, @unchecked Sendable {
    let inspectTree: SignatureTree
    let validateTree: SignatureTree?
    let validateError: Error?
    let validateHangs: Bool

    init(inspectTree: SignatureTree, validateTree: SignatureTree? = nil, validateError: Error? = nil,
         validateHangs: Bool = false) {
        self.validateHangs = validateHangs
        self.inspectTree = inspectTree
        self.validateTree = validateTree
        self.validateError = validateError
    }

    func capabilities() async throws -> EngineCapabilities { throw SigningFailure.engine("unused") }
    func drivers() async throws -> [SigningDriver] { [] }
    func certificates(driverID: String, pin: Secret?) async throws -> [SigningCertificate] { [] }
    func certificateDiscovery(driverID: String, pin: Secret?) async throws -> CertificateDiscovery {
        throw SigningFailure.engine("unused")
    }
    func inspect(files: [PDFItemDescriptor]) async throws -> [PDFInspection] {
        [PDFInspection(files: files.map { InspectedPDF(id: $0.id, isSignable: true, tree: inspectTree) })]
    }
    func validate(files: [PDFItemDescriptor]) async throws -> [PDFInspection] {
        if validateHangs { try await Task.sleep(for: .seconds(3600)) }
        if let validateError { throw validateError }
        return [PDFInspection(files: files.map { InspectedPDF(id: $0.id, isSignable: true, tree: validateTree!) })]
    }
    func sign(request: EngineSigningRequest) -> AsyncThrowingStream<SigningEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: SigningFailure.engine("unused")) }
    }
    func cancel() async {}
}
