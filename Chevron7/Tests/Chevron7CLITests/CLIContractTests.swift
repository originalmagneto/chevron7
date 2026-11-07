import XCTest
@testable import chevron7
import Chevron7Integration

final class CLIContractTests: XCTestCase {
    func testNoSecretsUnknownOptionsAndInvalidFormats() {
        for arguments in [["sign", "/tmp/a.pdf", "--output", "/tmp/b.pdf", "--pin", "1234"], ["sign", "/tmp/a.pdf", "--output", "/tmp/b.pdf", "--format", "exe"], ["jobs", "get"], ["status", "--output", "/tmp/a"], ["validate", "/tmp/a", "extra"]] {
            XCTAssertThrowsError(try CLIOptions(arguments)) { XCTAssertEqual(($0 as? IntegrationError)?.exitCode, 2) }
        }
    }

    func testSessionPathsAndExplicitPrivileges() throws {
        XCTAssertThrowsError(try CLIOptions(["status", "--session", "../escape"]))
        XCTAssertThrowsError(try CLIOptions(["mcp"]))
        XCTAssertThrowsError(try CLIOptions(["register", "list"]))
        XCTAssertThrowsError(try CLIOptions(["ezzk", "lookup", "x"]))
        let options = try CLIOptions(["--session", "lawoss-client-1", "sign", "zmluva č. 1.pdf", "--output", "podpísané.pdf", "--format", "asice", "--attach", "príloha.txt", "--no-wait", "--json"])
        XCTAssertTrue(options.json)
        XCTAssertTrue(options.noWait)
        XCTAssertTrue(options.arguments["file"]?.string?.hasPrefix("/") == true)
        XCTAssertEqual(options.arguments["format"], .string("asice"))
        XCTAssertEqual(options.arguments["attachments"]?.array?.count, 1)
    }

    func testFixedMCPToolPrivilegesAndStrictSchemas() throws {
        let options = try CLIOptions(["mcp", "--root", "/tmp"])
        let tools = IntegrationTool.available(options: options)
        XCTAssertFalse(tools.contains { $0.method.hasPrefix("register.") || $0.method == "ezzk.lookup" })
        let inspect = try XCTUnwrap(tools.first { $0.method == "inspect" })
        XCTAssertThrowsError(try inspect.validated(["file": .string("/tmp/a.pdf"), "roots": .array([.string("/")])]))
        XCTAssertThrowsError(try inspect.validated(["file": .string("relative.pdf")]))
        XCTAssertThrowsError(try inspect.validated(["file": .number(1)]))
        XCTAssertEqual(try inspect.validated(["file": .string("/tmp/a.pdf")])["file"], .string("/tmp/a.pdf"))
    }

    func testPrivateProfilesArePersistentAndIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try SessionProfile.capability(name: "first", directory: root)
        XCTAssertEqual(first, try SessionProfile.capability(name: "first", directory: root))
        XCTAssertNotEqual(first, try SessionProfile.capability(name: "second", directory: root))
        let alias = root.appendingPathComponent("alias.session")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("first.session"))
        XCTAssertThrowsError(try SessionProfile.capability(name: "alias", directory: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try SessionProfile.capability(name: "first", directory: root))
    }

    func testValidationExitNeverEquatesRPCSuccessWithValidity() {
        for state in ["unsigned", "invalid", "indeterminate", "notValidated"] {
            XCTAssertEqual(Chevron7CLI.exitCode(IntegrationResponse(requestId: "x", result: .object(["validationState": .string(state)])), method: "validate"), 10)
        }
        XCTAssertEqual(Chevron7CLI.exitCode(IntegrationResponse(requestId: "x", result: .object(["validationState": .string("valid")])), method: "validate"), 0)
    }
}

private actor BeginReplyFixture {
    var continuation: CheckedContinuation<IntegrationResponse, Never>?
    var calls: [IntegrationRequest] = []
    let admitted: XCTestExpectation
    init(admitted: XCTestExpectation) { self.admitted = admitted }
    func execute(_ request: IntegrationRequest) async -> IntegrationResponse {
        calls.append(request)
        if request.method == "sign" {
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                admitted.fulfill()
            }
        }
        return IntegrationResponse(requestId: request.requestId, result: .object(["jobId": .string("owned-job"), "state": .string("cancelled")]))
    }
    func reply() {
        continuation?.resume(returning: IntegrationResponse(requestId: "begin", result: .object(["jobId": .string("owned-job"), "state": .string("awaitingConfirmation")])))
        continuation = nil
    }
}

extension CLIContractTests {
    func testMCPCancelledBeginAwaitsHandleThenCancelsOnlyThatJob() async throws {
        let admitted = expectation(description: "sign begin dispatched")
        let fixture = BeginReplyFixture(admitted: admitted)
        let task = Task {
            try await MCPAdapter.confirmedBegin(IntegrationRequest(session: "private-session", method: "sign", arguments: ["roots": .array([.string("/permitted")])]), execute: { request, _ in await fixture.execute(request) })
        }
        await fulfillment(of: [admitted], timeout: 2)
        task.cancel()
        await fixture.reply()
        do { _ = try await task.value; XCTFail("Cancelled MCP request must not return a normal tool response") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let calls = await fixture.calls
        XCTAssertEqual(calls.map(\.method), ["sign", "jobs.cancel"])
        XCTAssertEqual(calls.last?.session, "private-session")
        XCTAssertEqual(calls.last?.arguments["jobId"], .string("owned-job"))
        XCTAssertEqual(calls.last?.arguments["roots"], .array([.string("/permitted")]))
    }

    func testMCPShutdownDrainsAdmittedBeginAndRefusesLaterAdmission() async throws {
        let gate = MCPSigningAdmissions()
        try gate.enter()
        let closing = Task { await gate.closeAndWait() }
        while !gate.isClosing { await Task.yield() }
        XCTAssertThrowsError(try gate.enter())
        gate.leave()
        await closing.value
    }
}
