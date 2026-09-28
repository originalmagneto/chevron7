// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class AGPClientTests: XCTestCase {
    private func response(status: Int, headers: [String: String] = [:], body: String = "") -> (Data, HTTPURLResponse) {
        let http = HTTPURLResponse(url: URL(string: "https://agp.test/")!,
                                   statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), http)
    }

    private func minter() -> AGPTokenMinter {
        AGPTokenMinter(userID: "123") { AGPTokenMinter.generateKey() }
    }

    private func client(_ transport: RecordingAGPTransport) -> AGPClient {
        AGPClient(baseURL: URL(string: "https://agp.test")!, minter: minter(), transport: transport)
    }

    func testCreateBundleSendsQESContractWithBase64Document() async throws {
        let transport = RecordingAGPTransport(responses: [
            .success(response(status: 201, body: #"{"id":"bundle-1"}"#)),
        ])
        let id = try await client(transport).createBundle(
            filename: "zmluva.pdf", data: Data("PDF".utf8),
            mimeType: "application/pdf",
            format: .pades, level: .baselineB)

        XCTAssertEqual(id, "bundle-1")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://agp.test/api/v1/bundles")
        let auth = try XCTUnwrap(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix(#"Token token=""#), auth)
        // Fresh ES256 JWT per request: three dot-separated segments.
        XCTAssertEqual(auth.dropFirst(#"Token token=""#.count).dropLast().split(separator: ".").count, 3)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])
        let contract = try XCTUnwrap((json["contracts"] as? [[String: Any]])?.first)
        XCTAssertEqual(contract["allowedMethods"] as? [String], ["qes"])
        let document = try XCTUnwrap((contract["documents"] as? [[String: Any]])?.first)
        XCTAssertEqual(document["filename"] as? String, "zmluva.pdf")
        XCTAssertEqual(document["content"] as? String, Data("PDF".utf8).base64EncodedString())
        // The portal decodes `content` only with the `;base64` suffix; the client adds it.
        XCTAssertEqual(document["contentType"] as? String, "application/pdf;base64")
        let params = try XCTUnwrap(contract["signatureParameters"] as? [String: Any])
        XCTAssertEqual(params["format"] as? String, "PAdES")
        XCTAssertEqual(params["level"] as? String, "BASELINE_B")
        // The portal sets the container itself and rejects one on PAdES: never sent.
        XCTAssertNil(params["container"])
    }

    func testCreateBundleOmitsContainerForXAdES() async throws {
        let transport = RecordingAGPTransport(responses: [
            .success(response(status: 201, body: #"{"id":"b"}"#)),
        ])
        _ = try await client(transport).createBundle(
            filename: "a.pdf", data: Data(), mimeType: "application/pdf;base64",
            format: .xades, level: .baselineT)
        let sent = try XCTUnwrap(transport.requests.first)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])
        let params = try XCTUnwrap(((json["contracts"] as? [[String: Any]])?.first?["signatureParameters"] as? [String: Any]))
        XCTAssertNil(params["container"])
        XCTAssertEqual(params["level"] as? String, "BASELINE_T")
    }
    func testUnauthorizedBecomesUnauthorizedError() async throws {
        let transport = RecordingAGPTransport(responses: [.success(response(status: 401, body: "{}"))])
        do {
            _ = try await client(transport).createBundle(
                filename: "a.pdf", data: Data(), mimeType: "application/pdf;base64",
                format: .pades, level: .baselineB)
            XCTFail("expected throw")
        } catch let error as AGPError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testFetchSignedPendingOn404() async throws {
        let transport = RecordingAGPTransport(responses: [.success(response(status: 404, body: #"{"error":"No signed document"}"#))])
        let result = try await client(transport).fetchSigned(contractID: "c1", baselineSignedAt: nil)
        XCTAssertEqual(result, .pending)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://agp.test/api/v1/contracts/c1/signed_document")
    }

    func testFetchSignedIgnoresPreExistingVersion() async throws {
        let body = #"{"download_url":"https://agp.test/f/signed.pdf","content_type":"application/pdf","filename":"s.pdf","signed_at":"2026-09-28T10:00:00Z"}"#
        let transport = RecordingAGPTransport(responses: [.success(response(status: 200, body: body))])
        let result = try await client(transport).fetchSigned(contractID: "c1",
                                                             baselineSignedAt: "2026-09-28T10:00:00Z")
        XCTAssertEqual(result, .pending)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testFetchSignedDownloadsNewerVersion() async throws {
        let info = #"{"download_url":"https://agp.test/f/signed.pdf","content_type":"application/pdf","filename":"s.pdf","signed_at":"2026-09-28T12:00:00Z"}"#
        let transport = RecordingAGPTransport(responses: [
            .success(response(status: 200, body: info)),
            .success(response(status: 200, body: "SIGNED-BYTES")),
        ])
        let result = try await client(transport).fetchSigned(contractID: "c1",
                                                             baselineSignedAt: "2026-09-28T10:00:00Z")
        guard case .signed(let file) = result else { return XCTFail("expected signed") }
        XCTAssertEqual(file.data, Data("SIGNED-BYTES".utf8))
        XCTAssertEqual(file.filename, "s.pdf")
        XCTAssertEqual(transport.requests.last?.url?.absoluteString, "https://agp.test/f/signed.pdf")
    }

    func testEidentitaPageReturnsHTML() async throws {
        let html = "<html><a href=\"sk.minv.sca://sign?qr=true\">qr</a></html>"
        let transport = RecordingAGPTransport(responses: [.success(response(status: 200, body: html))])
        let page = try await client(transport).eidentitaPage(contractID: "c1")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://agp.test/contracts/c1/sessions/eidentita")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(page.contains("sk.minv.sca://"))
    }
}

private final class RecordingAGPTransport: AVMHTTPTransport, @unchecked Sendable {
    typealias Response = Result<(Data, HTTPURLResponse), Error>

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response: Response? = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard let response else { throw URLError(.badServerResponse) }
        return try response.get()
    }
}
