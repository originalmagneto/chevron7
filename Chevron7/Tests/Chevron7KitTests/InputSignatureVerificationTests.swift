// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

final class InputSignatureVerificationTests: XCTestCase {
    func testCompletedInspectionWithNoSignaturesIsValid() {
        let result = InputSignatureInspectionResult.completed(signatures: [])

        XCTAssertEqual(result.state, .valid)
        XCTAssertTrue(result.signatures.isEmpty)
        XCTAssertNil(result.oldestQualifiedTimestamp)
    }

    func testInvalidSignatureMakesInspectionInvalid() {
        let signature = DocumentSignatureInfo(id: "s1", signerDisplayName: "Test",
                                              state: .invalid)

        XCTAssertEqual(InputSignatureInspectionResult.completed(signatures: [signature]).state,
                       .invalid)
    }

    func testIndeterminateSignatureMakesInspectionUnknown() {
        let signature = DocumentSignatureInfo(id: "s1", signerDisplayName: "Test",
                                              state: .indeterminate)

        XCTAssertEqual(InputSignatureInspectionResult.completed(signatures: [signature]).state,
                       .unknown)
    }

    func testUnavailableInspectionPreservesFailureDetail() {
        let result = InputSignatureInspectionResult.unavailable(detail: "Verifier unavailable")

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.detail, "Verifier unavailable")
    }
    func testDefaultBulkInputInspectionPreservesEachURLResult() async throws {
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-first-\(UUID().uuidString).pdf")
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-second-\(UUID().uuidString).pdf")
        let provider = BulkInspectionProbeProvider()

        let results = await provider.inspectInputSignatures(in: [first, second])

        XCTAssertEqual(results[EnginePaths.canonical(first)]?.state, .valid)
        XCTAssertEqual(results[EnginePaths.canonical(second)]?.state, .unknown)
    }


    func testCompletedInspectionTracksOldestQualifiedTimestamp() {
        let older = DocumentSignatureInfo(
            id: "older",
            signerDisplayName: "Older",
            signingTime: Date(timeIntervalSince1970: 100),
            hasQualifiedTimestamp: true,
            state: .valid)
        let newer = DocumentSignatureInfo(
            id: "newer",
            signerDisplayName: "Newer",
            signingTime: Date(timeIntervalSince1970: 200),
            hasQualifiedTimestamp: true,
            state: .valid)

        let result = InputSignatureInspectionResult.completed(signatures: [newer, older])

        XCTAssertEqual(result.oldestQualifiedTimestamp, Date(timeIntervalSince1970: 100))
    }

    func testUnavailableProviderReturnsUnavailable() async throws {
        let inputURL = try temporaryInputFile()
        let provider = DefaultInspectionProvider()

        let result = await InputSignatureVerificationService(provider: provider).inspect(inputURL: inputURL)

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertFalse(result.detail.isEmpty)
    }

    func testDefaultInspectionAllowsUnsignedPDF() async throws {
        let inputURL = try temporaryInputFile(contents: Data("%PDF-1.7\n%%EOF\n".utf8))
        let result = await InputSignatureVerificationService(
            provider: DefaultInspectionProvider()).inspect(inputURL: inputURL)

        XCTAssertEqual(result.state, .valid)
        XCTAssertTrue(result.signatures.isEmpty)
    }

    func testDefaultInspectionBlocksStructurallySignedPDFAsUnknown() async throws {
        let pdf = "%PDF-1.7\n1 0 obj\n<< /T#79pe\t/\0\tS#69g /ByteR#61nge\t[\t0 1 2 3] >>\nendobj\n%%EOF\n"
        let inputURL = try temporaryInputFile(contents: Data(pdf.utf8))
        let result = await InputSignatureVerificationService(
            provider: DefaultInspectionProvider()).inspect(inputURL: inputURL)

        XCTAssertEqual(result.state, .unknown)
        XCTAssertTrue(result.signatures.first?.detail?.contains("kryptografické overenie") == true)
    }

    func testDefaultInspectionBlocksCompressedObjectStreamPDF() async throws {
        let pdf = "%PDF-1.7\n1 0 obj\n<< /Type /ObjStm /N 1 /First 0 >>\nstream\ncompressed\nendstream\nendobj\n%%EOF\n"
        let inputURL = try temporaryInputFile(contents: Data(pdf.utf8))
        let result = await InputSignatureVerificationService(
            provider: DefaultInspectionProvider()).inspect(inputURL: inputURL)

        XCTAssertEqual(result.state, .unavailable)
    }

    /// Without the engine (Demo, no bundled helper) an ordinary PDF with object streams
    /// showed an orange "could not check" banner. Its own bytes say it carries no
    /// signature (every signature's /ByteRange sits outside object streams), so its tree
    /// is empty and no banner shows.
    func testDefaultTreeOfAnUnsignedObjectStreamPDFIsEmpty() async throws {
        let pdf = "%PDF-1.7\n1 0 obj\n<< /Type /ObjStm /N 1 /First 0 >>\nstream\ncompressed\nendstream\nendobj\n%%EOF\n"
        let inputURL = try temporaryInputFile(contents: Data(pdf.utf8))

        let result = await DefaultInspectionProvider().inspectSignatureTree(in: inputURL)

        XCTAssertEqual(result, .tree(SignatureTree()))
    }

    /// A signed PDF the structural pass cannot read still says so.
    func testDefaultTreeOfASignedObjectStreamPDFStillFails() async throws {
        let pdf = "%PDF-1.7\n1 0 obj\n<< /Type /ObjStm /N 1 /First 0 >>\nstream\ncompressed\nendstream\nendobj\n"
            + "2 0 obj\n<< /Type /Sig /ByteRange [0 10 20 30] >>\nendobj\n%%EOF\n"
        let inputURL = try temporaryInputFile(contents: Data(pdf.utf8))

        let result = await DefaultInspectionProvider().inspectSignatureTree(in: inputURL)

        guard case .failed = result else { return XCTFail("expected a failure, got \(result)") }
    }


    func testMissingInputReturnsUnavailableWithoutCallingProvider() async {
        let provider = CountingInspectionProvider()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-")
            .appendingPathExtension("pdf")

        let result = await InputSignatureVerificationService(provider: provider).inspect(inputURL: missingURL)

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(provider.calls, 0)
    }

    func testPreflightBlocksEveryNonValidInputSignatureState() {
        for state in [InputSignatureInspectionResult.State.invalid, .unknown, .unavailable] {
            let inspection = InputSignatureInspectionResult(
                state: state,
                signatures: [],
                oldestQualifiedTimestamp: nil,
                detail: "blocked")
            let result = AttestationPreflight.evaluate(
                validAttestationData(),
                securityElements: [confirmedElement()],
                hasSelectedIdentity: true,
                mandateRequirementSatisfied: true,
                inputSignatureInspection: inspection)

            XCTAssertTrue(result.errors.contains { error in
                if case .inputSignatureVerificationRequired(let actual) = error {
                    return actual == state
                }
                return false
            })
            XCTAssertFalse(result.isComplete)
        }
    }

    func testPreflightAllowsValidInputSignatureInspection() {
        let result = AttestationPreflight.evaluate(
            validAttestationData(),
            securityElements: [confirmedElement()],
            hasSelectedIdentity: true,
            mandateRequirementSatisfied: true,
            inputSignatureInspection: .completed(signatures: []))

        XCTAssertFalse(result.errors.contains { error in
            if case .inputSignatureVerificationRequired = error { return true }
            return false
        })
    }

    func testSessionResultGuardRejectsStaleAndCancelledResults() {
        let current = UUID()
        let stale = UUID()

        XCTAssertFalse(SessionResultGuard.accepts(
            resultFor: stale, currentRecordID: current, taskIsCancelled: false))
        XCTAssertTrue(SessionResultGuard.accepts(
            resultFor: current, currentRecordID: current, taskIsCancelled: false))
        XCTAssertFalse(SessionResultGuard.accepts(
            resultFor: current, currentRecordID: current, taskIsCancelled: true))
    }

    private func validAttestationData() -> AttestationData {
        AttestationData(
            originalDocumentName: "Pôvodný dokument",
            originalDocumentTypeLabel: "Zmluva",
            originConfirmed: true,
            numberOfSheets: 1,
            nonEmptyPageCount: 1,
            newDocumentName: "Dokument.pdf",
            evidenceNumber: "2026/000001",
            performingPerson: AdvocateProfile(
                fullName: "JUDr. Test",
                registrationNumber: "1234"))
    }

    private func confirmedElement() -> SecurityElement {
        SecurityElement(
            kind: .handwrittenSignature,
            pageIndex: 0,
            boundingBox: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2),
            confidence: 1,
            verbalDescription: "Podpis",

            detectedByAI: false,
            reviewState: .confirmed)
    }

    private func temporaryInputFile(contents: Data = Data("test".utf8)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("input-signature-")
            .appendingPathExtension("pdf")
        try contents.write(to: url)
        return url
    }
}
private struct BulkInspectionProbeProvider: QualifiedSigningProviding {
    func availableIdentities() async -> [SigningIdentityInfo] { [] }
    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.identityUnavailable
    }
    func inspectSignatures(in fileURL: URL) async -> [DocumentSignatureInfo] { [] }
    func inspectInputSignatures(in fileURL: URL) async -> InputSignatureInspectionResult {
        if fileURL.lastPathComponent.hasPrefix("bulk-first-") {
            return .completed(signatures: [])
        }
        return .completed(signatures: [
            DocumentSignatureInfo(
                id: "unknown",
                signerDisplayName: "Unknown",
                state: .indeterminate)
        ])
    }
}

private struct DefaultInspectionProvider: QualifiedSigningProviding {
    func availableIdentities() async -> [SigningIdentityInfo] { [] }
    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.identityUnavailable
    }
    func inspectSignatures(in fileURL: URL) async -> [DocumentSignatureInfo] { [] }
}

private final class CountingInspectionProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func availableIdentities() async -> [SigningIdentityInfo] { [] }
    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.identityUnavailable
    }
    func inspectSignatures(in fileURL: URL) async -> [DocumentSignatureInfo] { [] }
}
