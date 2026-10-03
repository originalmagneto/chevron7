// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

/// Signing used to leave zero-byte hidden files such as
/// `.dokument_signed.pdf.<UUID>.<random>` next to the user's document: every
/// input signature check reserved an output it never finalized nor removed.
/// Each test runs a fake signing helper in a temporary directory and checks
/// that nothing but the source (and a finalized output) is left there.
final class OutputReservationCleanupTests: XCTestCase {
    private var directory: URL!
    private var engines: [AutogramCLIEngine] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "OutputReservationCleanupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for engine in engines { await engine.cancel() }
        engines = []
        try? FileManager.default.removeItem(at: directory)
    }

    func testInspectLeavesNothingNextToTheSource() async throws {
        let source = try makeSource()
        let engine = try makeEngine(script: """
            IFS= read -r line
            id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"requestId":"([^"]+)".*/\\1/')
            printf '{"protocolVersion":1,"type":"inspection.completed","sessionId":"%s","emittedAt":"2026-09-24T10:00:00Z","fileId":"inspect-0","payload":{}}\\n' "$id"
            printf '{"protocolVersion":1,"type":"session.completed","sessionId":"%s","emittedAt":"2026-09-24T10:00:00Z","payload":{}}\\n' "$id"
            """)

        let inspections = try await engine.inspect(files: [PDFItemDescriptor(id: "inspect-0", sourceURL: source)])

        XCTAssertEqual(inspections.flatMap(\.files).map(\.isSignable), [true])
        XCTAssertEqual(try directoryContents(), ["dokument.pdf"])
    }

    func testFailedInspectLeavesNothingNextToTheSource() async throws {
        let source = try makeSource()
        let engine = try makeEngine(script: "exit 1")

        do {
            _ = try await engine.inspect(files: [PDFItemDescriptor(id: "inspect-0", sourceURL: source)])
            XCTFail("A helper that exits without a response must fail the inspection.")
        } catch {}

        XCTAssertEqual(try directoryContents(), ["dokument.pdf"])
    }

    func testValidateLeavesNothingNextToTheSource() async throws {
        let source = try makeSource()
        let engine = try makeEngine(script: """
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"requestId":"([^"]+)".*/\\1/')
              printf '{"protocolVersion":2,"requestId":"%s","type":"validation.completed","emittedAt":"2026-09-24T10:00:00Z","fileId":"validate-0","payload":{}}\\n' "$id"
              printf '{"protocolVersion":2,"requestId":"%s","type":"request.completed","emittedAt":"2026-09-24T10:00:00Z","payload":{}}\\n' "$id"
            done
            """)

        let inspections = try await engine.validate(files: [PDFItemDescriptor(id: "validate-0", sourceURL: source)])

        XCTAssertEqual(inspections.flatMap(\.files).map(\.id), ["validate-0"])
        XCTAssertEqual(try directoryContents(), ["dokument.pdf"])
    }

    /// The helper reports the file as signed but writes something that is not a
    /// PDF, so finalizing refuses it. The rejected temporary output must go.
    func testSignWhoseOutputIsRejectedLeavesNothingBehind() async throws {
        let source = try makeSource()
        let engine = try makeEngine(script: """
            IFS= read -r line
            id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"requestId":"([^"]+)".*/\\1/')
            target=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"target":"([^"]+)".*/\\1/')
            printf 'not a pdf' > "$target"
            printf '{"protocolVersion":1,"type":"file.completed","sessionId":"%s","emittedAt":"2026-09-24T10:00:00Z","fileId":"document","payload":{}}\\n' "$id"
            printf '{"protocolVersion":1,"type":"session.completed","sessionId":"%s","emittedAt":"2026-09-24T10:00:00Z","payload":{}}\\n' "$id"
            """)

        let events = try await collect(engine.sign(request: signRequest(source: source)))

        XCTAssertTrue(events.contains { if case .failed("document", _) = $0 { true } else { false } })
        XCTAssertEqual(try directoryContents(), ["dokument.pdf"])
    }

    func testSignThatFinalizesKeepsOnlyTheSignedOutput() async throws {
        let source = try makeSource()
        let engine = try makeEngine(script: """
            IFS= read -r line
            id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"requestId":"([^"]+)".*/\\1/')
            target=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"target":"([^"]+)".*/\\1/')
            printf '%%PDF-1.7\\n%%%%EOF\\n' > "$target"
            printf '{"protocolVersion":1,"type":"file.completed","sessionId":"%s","emittedAt":"2026-09-24T10:00:00Z","fileId":"document","payload":{}}\\n' "$id"
            printf '{"protocolVersion":1,"type":"session.completed","sessionId":"%s","emittedAt":"2026-09-24T10:00:00Z","payload":{}}\\n' "$id"
            """)

        let events = try await collect(engine.sign(request: signRequest(source: source)))

        XCTAssertTrue(events.contains { if case .completed("document", _, _) = $0 { true } else { false } })
        XCTAssertEqual(try directoryContents(), ["dokument.pdf", "dokument_signed.pdf"])
    }

    func testSignThatFailsLeavesNothingBehind() async throws {
        let source = try makeSource()
        let engine = try makeEngine(script: """
            IFS= read -r line
            id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"requestId":"([^"]+)".*/\\1/')
            target=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"target":"([^"]+)".*/\\1/')
            printf 'partial' > "$target"
            printf '{"protocolVersion":1,"type":"session.failed","sessionId":"%s","emittedAt":"2026-09-24T10:00:00Z","payload":{"code":"SIGNING_FAILED"}}\\n' "$id"
            """)

        do {
            _ = try await collect(engine.sign(request: signRequest(source: source)))
            XCTFail("A failed session must fail the signing stream.")
        } catch {}

        XCTAssertEqual(try directoryContents(), ["dokument.pdf"])
    }

    func testDiscardRemovesOnlyTheReservedTemporaryFile() throws {
        let source = try makeSource()
        let service = OutputService()
        let reservation = try service.reserve(for: source)
        let neighbour = directory.appending(path: "dokument_signed.pdf.keep")
        try Data("keep".utf8).write(to: neighbour)

        XCTAssertTrue(FileManager.default.fileExists(atPath: reservation.temporaryURL.path))
        service.discard(reservation)
        service.discard(reservation)

        XCTAssertEqual(try directoryContents(), ["dokument.pdf", "dokument_signed.pdf.keep"])
    }

    /// A reservation whose temporary path was replaced by a symbolic link must
    /// not delete anything: the link is not a file this app created.
    func testDiscardLeavesASymbolicLinkAlone() throws {
        let source = try makeSource()
        let service = OutputService()
        let reservation = try service.reserve(for: source)
        try FileManager.default.removeItem(at: reservation.temporaryURL)
        try FileManager.default.createSymbolicLink(at: reservation.temporaryURL, withDestinationURL: source)

        service.discard(reservation)

        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: reservation.temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - Helpers

    private func makeSource() throws -> URL {
        let url = directory.appending(path: "dokument.pdf")
        try Data("%PDF-1.7\n%%EOF\n".utf8).write(to: url)
        return url
    }

    private func makeEngine(script body: String) throws -> AutogramCLIEngine {
        let helper = directory.deletingLastPathComponent()
            .appending(path: "fake-helper-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: helper) }
        let engine = AutogramCLIEngine(configuration: ProcessConfiguration(executableURL: helper, timeout: .seconds(20)))
        engines.append(engine)
        return engine
    }

    /// Baseline B needs no timestamp, so the app's timestamp preferences are never read.
    private func signRequest(source: URL) -> EngineSigningRequest {
        EngineSigningRequest(sessionID: UUID(), driverID: "secure_store", certificateSerial: "1",
                             pin: Secret("1234"), files: [SigningFile(id: "document", sourceURL: source)],
                             outputFormat: .pades, signatureLevelOverride: "PAdES_BASELINE_B")
    }

    private func collect(_ stream: AsyncThrowingStream<SigningEvent, Error>) async throws -> [SigningEvent] {
        var events: [SigningEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// Everything in the directory, hidden files included.
    private func directoryContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
