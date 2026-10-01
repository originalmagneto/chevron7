// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

/// The machine protocol v2 session runs one helper process for many requests. A request
/// the app cancelled (a validation that timed out) keeps running in the engine, which later
/// emits events for it. Those late events must not fail the other requests on the session.
final class MachineSessionProcessTests: XCTestCase {
    private var directory: URL!
    private var sessions: [MachineSessionProcess] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "MachineSessionProcessTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        sessions = []
        try? FileManager.default.removeItem(at: directory)
    }

    func testLateEventsOfACancelledRequestDoNotFailAnotherRequest() async throws {
        let marker = directory.appending(path: "release")
        let configuration = try makeHelper(script: """
            IFS= read -r first
            IFS= read -r second
            while [ ! -f '\(marker.path)' ]; do /bin/sleep 0.05; done
            printf '{"protocolVersion":2,"requestId":"req-A","type":"request.started","emittedAt":"2026-10-01T10:00:00Z","payload":{}}\\n'
            printf '{"protocolVersion":2,"requestId":"req-A","type":"request.completed","emittedAt":"2026-10-01T10:00:00Z","payload":{}}\\n'
            printf '{"protocolVersion":2,"requestId":"req-B","type":"request.completed","emittedAt":"2026-10-01T10:00:00Z","payload":{}}\\n'
            /bin/sleep 5
            """)
        let session = makeSession()

        let cancelled = Task { try await session.send(Self.validate("req-A"), configuration: configuration) }
        let other = Task { try await session.send(Self.validate("req-B"), configuration: configuration) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("The cancelled request must not complete.")
        } catch let failure as MachineSessionProcessFailure {
            XCTAssertEqual(failure, .cancelled)
        }

        try Data().write(to: marker)
        let events = try await other.value

        XCTAssertEqual(events.map(\.type), [.requestCompleted])
        XCTAssertEqual(events.map(\.requestID), ["req-B"])
    }

    /// An event for a request the app never sent is still a protocol violation.
    func testEventForARequestNeverSentFailsTheSession() async throws {
        let configuration = try makeHelper(script: """
            IFS= read -r first
            printf '{"protocolVersion":2,"requestId":"req-unknown","type":"request.completed","emittedAt":"2026-10-01T10:00:00Z","payload":{}}\\n'
            /bin/sleep 5
            """)
        let session = makeSession()

        do {
            _ = try await session.send(Self.validate("req-B"), configuration: configuration)
            XCTFail("An event for an unknown request must fail the session.")
        } catch let failure as MachineSessionProcessFailure {
            XCTAssertEqual(failure, .malformedOutput)
        }
    }

    /// The engine answers a session's requests one after another. A validation that hangs on
    /// the trusted lists must not hold up another v2 request (a visible signature, a preview).
    func testHungValidationDoesNotBlockOtherV2Requests() async throws {
        executionTimeAllowance = 60
        let source = directory.appending(path: "dokument.pdf")
        try Data("%PDF-1.7\n%%EOF\n".utf8).write(to: source)
        let configuration = try makeHelper(script: """
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"requestId":"([^"]+)".*/\\1/')
              case "$line" in
                *'"operation":"VALIDATE"'*) /bin/sleep 30 ;;
                *)
                  printf '{"protocolVersion":2,"requestId":"%s","type":"preview.completed","emittedAt":"2026-10-01T10:00:00Z","payload":{"name":"a.txt","mediaType":"text/plain","contentBase64":"YQ=="}}\\n' "$id"
                  printf '{"protocolVersion":2,"requestId":"%s","type":"request.completed","emittedAt":"2026-10-01T10:00:00Z","payload":{}}\\n' "$id"
                  ;;
              esac
            done
            """)
        let engine = AutogramCLIEngine(configuration: configuration)
        let validation = Task { try await engine.validate(files: [PDFItemDescriptor(id: "tree", sourceURL: source)]) }
        defer { validation.cancel() }
        // Give the validation a head start, so it reaches the helper first.
        try await Task.sleep(for: .milliseconds(500))

        let started = ContinuousClock.now
        let preview = try await engine.previewEmbeddedDocument(sourceURL: source, named: "a.txt")

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        XCTAssertEqual(preview.displayName, "a.txt")
        try? FileManager.default.removeItem(at: preview.url.deletingLastPathComponent())
        await engine.cancel()
    }

    // MARK: - Helpers

    private static func validate(_ requestID: String) -> MachineV2Request {
        MachineV2Request(protocolVersion: 2, requestID: requestID, operation: .validate, payload: [:])
    }

    private func makeSession() -> MachineSessionProcess {
        let session = MachineSessionProcess()
        sessions.append(session)
        return session
    }

    private func makeHelper(script body: String) throws -> ProcessConfiguration {
        let helper = directory.appending(path: "fake-helper.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return ProcessConfiguration(executableURL: helper, timeout: .seconds(20))
    }
}
