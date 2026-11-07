import XCTest
import Foundation
import Observation
import Chevron7Integration
import Chevron7Kit
import Chevron7WebBridge
import Chevron7TestSupport
@testable import Chevron7App

@MainActor
final class IntegrationServiceTests: XCTestCase {
    private var folder: URL!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: folder) }

    private func service(signing: @escaping @MainActor (WebSignRequest) async throws -> WebSignResponse) -> (IntegrationService, SignedDocumentStore) {
        let settings = makeSettingsStore()
        let history = SignedDocumentStore(defaults: MemoryUserDefaults(), trash: { try FileManager.default.removeItem(at: $0) })
        let coordinator = WebSigningCoordinator(settingsStore: settings, signedDocumentStore: history)
        return (IntegrationService(settingsStore: settings, coordinator: coordinator, signedDocuments: history,
            directory: folder.appendingPathComponent("jobs"), engineAvailable: { true }, signing: signing), history)
    }
    private func input() throws -> URL {
        let url = folder.appendingPathComponent("test.pdf")
        try Data("%PDF-1.7\nsynthetic test data".utf8).write(to: url)
        return url
    }
    private func request(_ method: String, _ args: [String: JSONValue], owner: String = "test-owner") -> IntegrationRequest {
        var values = args
        values["roots"] = .array([.string(folder.path)])
        return IntegrationRequest(session: owner, method: method, arguments: values)
    }
    private func terminal(_ service: IntegrationService, _ id: String) async throws -> JSONValue {
        for _ in 0..<200 {
            let value = try await service.execute(request("jobs.get", ["jobId": .string(id)]))
            if value["done"]?.bool == true { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Job did not reach terminal state")
        throw IntegrationError(code: "TIMEOUT", message: "Test deadline")
    }
    func testSigningReturnsActualOutputAndRepeatedKeyDoesNotSignTwice() async throws {
        var calls = 0
        let (service, history) = service { request in
            calls += 1
            return WebSignResponse(requestID: request.requestID, content: Data("synthetic signed output".utf8).base64EncodedString(), signedBy: "Synthetic signer", issuedBy: "Test", method: "mobile", signatureLevel: request.signatureLevel)
        }
        let source = try input(), output = folder.appendingPathComponent("signed.pdf")
        let args: [String: JSONValue] = ["file": .string(source.path), "output": .string(output.path), "requestKey": .string("once")]
        let started = try await service.execute(request("sign", args))
        let id = try XCTUnwrap(started["jobId"]?.string)
        let result = try await terminal(service, id)
        XCTAssertEqual(result["state"]?.string, "completed")
        XCTAssertEqual(result["result"]?["output"]?["path"]?.string, output.path)
        XCTAssertEqual(result["result"]?["validation"]?.string, "notValidated")
        XCTAssertEqual(try Data(contentsOf: output), Data("synthetic signed output".utf8))
        XCTAssertEqual(history.entries.first?.origin, .integration)
        XCTAssertEqual(history.entries.first?.method, .mobile)
        history.clear(trashingFiles: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let repeated = try await service.execute(request("sign", args))
        XCTAssertEqual(repeated["jobId"]?.string, id)
        XCTAssertEqual(calls, 1)
        let again = try await service.execute(request("jobs.get", ["jobId": .string(id)]))
        XCTAssertEqual(again, result)
    }

    func testBusyAdmissionAndReleaseNotifyObservedControls() async throws {
        let (completion, release) = AsyncStream<Void>.makeStream()
        let (service, _) = service { request in
            for await _ in completion { break }
            return WebSignResponse(requestID: request.requestID,
                content: Data("synthetic signed output".utf8).base64EncodedString(), signedBy: "Test", issuedBy: "Test")
        }
        let admitted = expectation(description: "Busy admission observed")
        let finished = expectation(description: "Busy release observed")
        withObservationTracking {
            XCTAssertFalse(service.isBusy)
        } onChange: {
            admitted.fulfill()
        }
        let source = try input()
        let begun = try await service.execute(request("sign", ["file": .string(source.path),
            "output": .string(folder.appendingPathComponent("observed.pdf").path)]))
        withObservationTracking {
            XCTAssertTrue(service.isBusy)
        } onChange: {
            finished.fulfill()
        }
        release.yield(())
        release.finish()
        _ = try await terminal(service, XCTUnwrap(begun["jobId"]?.string))
        await fulfillment(of: [admitted, finished], timeout: 2)
        XCTAssertFalse(service.isBusy)
    }
    func testDeliveryFailureCanBeRecoveredWithoutSigningAgain() async throws {
        let output = folder.appendingPathComponent("collision.pdf")
        var calls = 0
        let (service, _) = service { request in
            calls += 1
            try Data("do not overwrite".utf8).write(to: output)
            return WebSignResponse(requestID: request.requestID, content: Data("signed bytes".utf8).base64EncodedString(), signedBy: "Test", issuedBy: "Test")
        }
        let source = try input()
        let started = try await service.execute(request("sign", ["file": .string(source.path), "output": .string(output.path)]))
        let id = try XCTUnwrap(started["jobId"]?.string)
        let failed = try await terminal(service, id)
        XCTAssertEqual(failed["error"]?["code"]?.string, "OUTPUT_DELIVERY_FAILED")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "do not overwrite")
        let recovered = folder.appendingPathComponent("recovered.pdf")
        let saved = try await service.execute(request("jobs.save", ["jobId": .string(id), "output": .string(recovered.path)]))
        XCTAssertEqual(saved["state"]?.string, "completed")
        XCTAssertEqual(try String(contentsOf: recovered, encoding: .utf8), "signed bytes")
        XCTAssertEqual(calls, 1)
    }
    func testOtherSessionCannotReadOrCancelJob() async throws {
        let (service, _) = service { _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        let source = try input()
        let started = try await service.execute(request("sign", ["file": .string(source.path), "output": .string(folder.appendingPathComponent("signed.pdf").path)]))
        let id = try XCTUnwrap(started["jobId"]?.string)
        for method in ["jobs.get", "jobs.cancel"] {
            do { _ = try await service.execute(request(method, ["jobId": .string(id)], owner: "other")); XCTFail("Access must be denied") }
            catch { XCTAssertNotNil(error as? IntegrationError) }
        }
        let cancelled = try await service.execute(request("jobs.cancel", ["jobId": .string(id)]))
        XCTAssertEqual(cancelled["state"]?.string, "cancelled")
        for _ in 0..<100 where service.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(service.isBusy)
    }
    func testCancellationDuringSigningIsOutcomeUnknownNotProofOfNoSignature() async throws {
        let settings = makeSettingsStore()
        let history = SignedDocumentStore(defaults: MemoryUserDefaults(), trash: { _ in })
        let coordinator = WebSigningCoordinator(settingsStore: settings, signedDocumentStore: history)
        let service = IntegrationService(settingsStore: settings, coordinator: coordinator, signedDocuments: history,
            directory: folder.appendingPathComponent("jobs"), engineAvailable: { true }) { request in
                coordinator.signingDidStart?(request.requestID)
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
        let source = try input()
        let started = try await service.execute(request("sign", ["file": .string(source.path), "output": .string(folder.appendingPathComponent("signed.pdf").path)]))
        let id = try XCTUnwrap(started["jobId"]?.string)
        for _ in 0..<100 {
            let state = try await service.execute(request("jobs.get", ["jobId": .string(id)]))
            if state["state"]?.string == "signing" { break }
            await Task.yield()
        }
        let cancelled = try await service.execute(request("jobs.cancel", ["jobId": .string(id)]))
        XCTAssertEqual(cancelled["state"]?.string, "outcomeUnknown")
        for _ in 0..<100 where service.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        let final = try await service.execute(request("jobs.get", ["jobId": .string(id)]))
        XCTAssertEqual(final["state"]?.string, "outcomeUnknown")
    }

    func testFinishedXDCFUsesExistingFormContainerPath() async throws {
        let source = folder.appendingPathComponent("form.xdcf")
        try Data("<test-container/>".utf8).write(to: source)
        var captured: WebSignRequest?
        let (service, _) = service { request in
            captured = request
            return WebSignResponse(requestID: request.requestID, content: Data("test result".utf8).base64EncodedString(), signedBy: "Test", issuedBy: "Test")
        }
        let started = try await service.execute(request("sign", ["file": .string(source.path), "output": .string(folder.appendingPathComponent("signed.asice").path), "format": .string("asice")]))
        _ = try await terminal(service, XCTUnwrap(started["jobId"]?.string))
        XCTAssertEqual(captured?.eform?.embedUsedSchemas, true)
        XCTAssertEqual(captured?.eform?.packaging, "ENVELOPING")
        XCTAssertEqual(captured?.isXMLDataContainer, true)
        XCTAssertEqual(captured?.filename, "form.xdcf")
    }

    func testNativePanelCancellationOnlyProvesNoSignatureBeforeExecutionStarted() async throws {
        let source = try input()
        for startedSigning in [false, true] {
            let settings = makeSettingsStore()
            let history = SignedDocumentStore(defaults: MemoryUserDefaults(), trash: { _ in })
            let coordinator = WebSigningCoordinator(settingsStore: settings, signedDocumentStore: history)
            let service = IntegrationService(settingsStore: settings, coordinator: coordinator, signedDocuments: history,
                directory: folder.appendingPathComponent(UUID().uuidString), engineAvailable: { true }) { request in
                    if startedSigning { coordinator.signingDidStart?(request.requestID) }
                    throw WebSigningCoordinator.Failure.cancelled
                }
            let output = folder.appendingPathComponent(UUID().uuidString + ".pdf")
            let begun = try await service.execute(request("sign", ["file": .string(source.path), "output": .string(output.path)]))
            let result = try await terminal(service, XCTUnwrap(begun["jobId"]?.string))
            XCTAssertEqual(result["state"]?.string, startedSigning ? "outcomeUnknown" : "cancelled")
            XCTAssertEqual(result["error"]?["code"]?.string, startedSigning ? "OUTCOME_UNKNOWN" : "USER_CANCELLED")
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testClosedSessionCannotSubmitLateSigningRequest() async throws {
        var calls = 0
        let (service, _) = service { _ in calls += 1; throw CancellationError() }
        _ = try await service.execute(request("session.close", [:]))
        let source = try input()
        do {
            _ = try await service.execute(request("sign", ["file": .string(source.path), "output": .string(folder.appendingPathComponent("signed.pdf").path)]))
            XCTFail("Closed session must be refused")
        } catch let error as IntegrationError { XCTAssertEqual(error.code, "SESSION_CLOSED") }
        XCTAssertEqual(calls, 0)
    }

    func testUnknownArgumentsAndAccountReadsAreRefused() async throws {
        let (service, _) = service { _ in throw CancellationError() }
        for call in [request("status", ["pin": .string("never accepted")]), request("register.list", [:]), request("ezzk.lookup", ["recordId": .string(UUID().uuidString)])] {
            do { _ = try await service.execute(call); XCTFail("Expected refusal") }
            catch { XCTAssertNotNil(error as? IntegrationError) }
        }
    }
}
