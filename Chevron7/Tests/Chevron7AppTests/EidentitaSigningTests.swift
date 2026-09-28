// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class EidentitaSigningTests: XCTestCase {
    private func request() -> AGPSigningRequest {
        AGPSigningRequest(filename: "zmluva.pdf", data: Data("PDF".utf8),
                          mimeType: "application/pdf;base64",
                          format: .pades, level: .baselineB)
    }

    func testSignViaEidentitaPresentsSheetAndReturnsFile() async throws {
        let info = #"{"download_url":"https://agp.test/f/s.pdf","content_type":"application/pdf","filename":"s.pdf","signed_at":"2026-09-28T12:00:00Z"}"#
        let transport = QueueAGPTransport(bodies: [
            (201, #"{"id":"bundle-1"}"#),
            (200, #"{"id":"bundle-1","contracts":[{"id":"contract-1"}]}"#),
            (200, #"{"id":"contract-1"}"#),
            (200, #"<html><a href="sk.minv.sca://sign?qr=true&amp;linkUrl=https://agp.test/p?t=1">qr</a></html>"#),
            (404, #"{"error":"No signed document available"}"#),
            (200, info),
            (200, "SIGNED-BYTES"),
        ])
        let coordinator = MobileSigningCoordinator(
            clientFactory: { AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!) },
            agpBaseURL: URL(string: "https://agp.test")!,
            agpTransport: transport,
            tokenStore: StubAGPTokenStore(token: "jwt"),
            eidentitaPollInterval: .milliseconds(5))

        let file = try await coordinator.signViaEidentita(request())

        XCTAssertEqual(file.data, Data("SIGNED-BYTES".utf8))
        XCTAssertFalse(coordinator.isEidentitaPresented)
        XCTAssertNil(coordinator.eidentitaSession)
        XCTAssertTrue(transport.requests.contains {
            $0.url?.absoluteString == "https://agp.test/contracts/contract-1/sessions/eidentita"
                && $0.value(forHTTPHeaderField: "Authorization") == nil
        })
    }

    func testSignViaEidentitaWithoutTokenThrowsMissingToken() async throws {
        let transport = QueueAGPTransport(bodies: [])
        let coordinator = MobileSigningCoordinator(

            clientFactory: { AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!) },
            agpBaseURL: URL(string: "https://agp.test")!,
            agpTransport: transport,
            tokenStore: StubAGPTokenStore(token: nil),
            eidentitaPollInterval: .milliseconds(5))
        do {
            _ = try await coordinator.signViaEidentita(request())
            XCTFail("expected throw")
        } catch let error as AGPError {
            XCTAssertEqual(error, .missingToken)
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(coordinator.isEidentitaPresented)
    }
    func testIgnoresEchoedUploadBytesAndAcceptsPhoneSignature() async throws {
        // Baseline 404 (the portal's async copy job not finished yet), then a
        // signed version identical to the upload, then the phone's signature.
        let echo = #"{"download_url":"https://agp.test/f/e.pdf","content_type":"application/pdf","filename":"e.pdf","signed_at":"2026-09-28T12:00:00Z"}"#
        let signed = #"{"download_url":"https://agp.test/f/s.pdf","content_type":"application/pdf","filename":"s.pdf","signed_at":"2026-09-28T12:05:00Z"}"#
        let transport = QueueAGPTransport(bodies: [
            (201, #"{"id":"bundle-1"}"#),
            (200, #"{"id":"bundle-1","contracts":[{"id":"contract-1"}]}"#),
            (200, #"{"id":"contract-1"}"#),
            (200, #"<html><a href="sk.minv.sca://sign?qr=true&amp;linkUrl=https://agp.test/p?t=1">qr</a></html>"#),
            (404, #"{"error":"No signed document available"}"#),
            (200, echo),
            (200, "PDF"),
            (200, signed),
            (200, "SIGNED"),
        ])
        let client = AGPClient(baseURL: URL(string: "https://agp.test")!, token: "jwt", transport: transport)
        let session = EidentitaSigningSession(client: client, pollInterval: .milliseconds(5))
        let file = try await session.run(AGPSigningRequest(filename: "zmluva.pdf", data: Data("PDF".utf8),
                                                           mimeType: "application/pdf;base64",
                                                           format: .pades, level: .baselineB))
        XCTAssertEqual(file.data, Data("SIGNED".utf8))
    }

    func testCancelEidentitaDismissesAndThrowsCancelled() async throws {
        let transport = QueueAGPTransport(bodies: [
            (201, #"{"id":"bundle-1"}"#),
            (200, #"{"id":"bundle-1","contracts":[{"id":"contract-1"}]}"#),
            (200, #"{"id":"contract-1"}"#),
            (200, #"<html><a href="sk.minv.sca://sign?qr=true&amp;linkUrl=https://agp.test/p?t=1">qr</a></html>"#),
        ])
        let coordinator = MobileSigningCoordinator(
            clientFactory: { AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!) },
            agpBaseURL: URL(string: "https://agp.test")!,
            agpTransport: transport,
            tokenStore: StubAGPTokenStore(token: "jwt"),
            eidentitaPollInterval: .milliseconds(5))
        let task = Task { try await coordinator.signViaEidentita(request()) }
        while !coordinator.isEidentitaPresented { try await Task.sleep(for: .milliseconds(5)) }

        coordinator.cancelEidentita()
        let result = await task.result

        guard case .failure(let error as AGPError) = result else { return XCTFail("expected AGPError, got \(result)") }
        XCTAssertEqual(error, .cancelled)
        XCTAssertFalse(coordinator.isEidentitaPresented)
    }
}

private final class StubAGPTokenStore: AGPTokenStoring, @unchecked Sendable {
    private let token: String?
    init(token: String?) { self.token = token }
    func load() throws -> String? { token }
    func save(_ token: String) throws {}
    func delete() throws {}
}

private final class QueueAGPTransport: AVMHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(bodies: [(Int, String)]) { self.bodies = bodies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: (Int, String)? = lock.withLock {
            requests.append(request)
            return bodies.isEmpty ? nil : bodies.removeFirst()
        }
        // DELETE cleanup and polls past the script: succeed quietly.
        if request.httpMethod == "DELETE" {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard let (status, body) = next else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
