// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

/// The protocol v1 runner keeps one helper process at a time. The Safari panel drops its
/// signature inspection the moment the person confirms, so the signature that follows must
/// neither be refused because the inspection's helper is still ending nor be stopped by it.
final class CLIProcessRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CLIProcessRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCancelledInspectionNeitherBlocksNorStopsTheNextRun() async throws {
        executionTimeAllowance = 60
        let started = directory.appending(path: "inspect-started")
        // INSPECT hangs (as on a large container) until it is ended; SIGN answers at once.
        let configuration = try makeHelper(script: """
            IFS= read -r request
            if [ "$6" = "INSPECT" ]; then
                : > '\(started.path)'
                exec /bin/sleep 30
            fi
            printf '{"protocolVersion":1,"type":"session.completed","sessionId":"sign-1","emittedAt":"2026-10-07T10:00:00Z","payload":{}}\\n'
            """)
        let runner = CLIProcessRunner()

        let inspection = Task {
            for try await _ in await runner.run(request: Self.request("inspect-1", .inspect),
                                                configuration: configuration) {}
        }
        while !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        inspection.cancel()
        _ = await inspection.result

        var events: [MachineEvent] = []
        for try await event in await runner.run(request: Self.request("sign-1", .sign),
                                                configuration: configuration) {
            events.append(event)
        }
        XCTAssertEqual(events.map(\.type), [.sessionCompleted])
    }

    private static func request(_ id: String, _ operation: MachineOperation) -> MachineRequest {
        MachineRequest(protocolVersion: 1, requestID: id, operation: operation, payload: [:])
    }

    private func makeHelper(script body: String) throws -> ProcessConfiguration {
        let helper = directory.appending(path: "fake-helper.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return ProcessConfiguration(executableURL: helper, timeout: .seconds(20))
    }
}
