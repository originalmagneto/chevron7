# AVM Mobile Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Autogram macOS sign a document with the Slovak eID over NFC on an iPhone through the Autogram v mobile (AVM) relay server, and continue the existing save, evidence and validation flow with the returned file.

**Architecture:** A pure Swift networking client in `AutogramKit/Signing/AVM/` (key generation, upload, QR link, polling, delete) plus an observable session state machine. The app adds a "Podpísať mobilom" branch to `SigningSessionStore` and `ZakoSessionStore` that reuses all document preparation and swaps only the final signing step for an AVM session shown in a QR sheet. An `avm-probe` executable validates the protocol against the real server before UI work.

**Tech Stack:** Swift 6, SwiftUI, CryptoKit, CoreImage (`CIQRCodeGenerator`), URLSession, XCTest. No new package dependencies.

**Spec:** `docs/superpowers/specs/2026-09-11-avm-mobile-signing-design.md`

## Global Constraints

- Toolchain: Xcode 27. Every build and test command needs `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"`.
- Run tests with `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter <TestClass>` from `Autogram/`.
- Code, comments and this plan in English. End-user strings in Slovak.
- Never use em dashes in any text (code, docs, UI strings). Use hyphens, colons or parentheses.
- Keep `AGENTS.md` and `CLAUDE.md` in the project root in complete sync.
- Public AVM server: `https://autogram.slovensko.digital/api/v1`. Encryption key: 32 random bytes, base64, header `X-Encryption-Key`.
- ZaKo via mobile must refuse a signature that is not a mandate certificate (no files saved, no evidence record).
- No push notifications, no integration registration, no custom server support beyond a configurable base URL.
- Commit after every task with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## File Structure

**AutogramKit (new directory `Autogram/Sources/AutogramKit/Signing/AVM/`)**
- `AVMDocumentKey.swift`: 32-byte symmetric key, base64 and URL-query encodings.
- `AVMModels.swift`: request and response types, signature levels, `AVMError`.
- `AVMClient.swift`: transport protocol, URLSession transport, endpoint calls, QR URL.
- `AVMSigningSession.swift`: observable state machine driving upload, polling, cancel, timeout.
- `QRCodeRenderer.swift`: string to `CGImage` via CoreImage.
- `AVMResultMapper.swift`: `AVMSignedDocument` to `SignedConversionResult`, mandate check.

**Tests (`Autogram/Tests/AutogramKitTests/`)**
- `AVMDocumentKeyTests.swift`, `AVMClientTests.swift`, `AVMSigningSessionTests.swift`, `QRCodeRendererTests.swift`, `AVMResultMapperTests.swift`.

**Probe executable**
- `Autogram/Sources/avm-probe/main.swift`, registered in `Autogram/Package.swift`.

**AutogramApp**
- `Autogram/Sources/AutogramKit/Support/AppSettings.swift`: `mobileSigningEnabled`, `avmBaseURL`.
- `Autogram/Sources/AutogramApp/MobileSigningCoordinator.swift`: owns the session, sheet presentation flag.
- `Autogram/Sources/AutogramApp/SigningSessionStore.swift`: `sign(viaMobile:)` branch.
- `Autogram/Sources/AutogramApp/ZakoSessionStore.swift`: `authorizeAndSign(viaMobile:)` branch with mandate refusal.
- `Autogram/Sources/AutogramApp/Views/MobileSigningSheet.swift`: QR sheet.
- `Autogram/Sources/AutogramApp/Views/SigningFlowViews.swift`, `AuthorizeDoneViews.swift`: buttons and sheet hookup.
- `Autogram/Sources/AutogramApp/Views/SettingsView.swift`: `MobileSigningCard`.
- `AGENTS.md`, `CLAUDE.md`: architecture note.

---

### Task 1: AVMDocumentKey

**Files:**
- Create: `Autogram/Sources/AutogramKit/Signing/AVM/AVMDocumentKey.swift`
- Test: `Autogram/Tests/AutogramKitTests/AVMDocumentKeyTests.swift`

**Interfaces:**
- Produces: `public struct AVMDocumentKey: Sendable, Equatable` with `init(bytes: Data) throws`, `static func generate() -> AVMDocumentKey`, `var bytes: Data`, `var base64: String`, `var queryValue: String`, `enum Failure: Error { case invalidLength(Int) }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AutogramKit

final class AVMDocumentKeyTests: XCTestCase {
    func testGeneratedKeyHas32BytesAndStrictBase64() throws {
        let key = AVMDocumentKey.generate()
        XCTAssertEqual(key.bytes.count, 32)
        let decoded = try XCTUnwrap(Data(base64Encoded: key.base64))
        XCTAssertEqual(decoded, key.bytes)
    }

    func testTwoGeneratedKeysDiffer() {
        XCTAssertNotEqual(AVMDocumentKey.generate(), AVMDocumentKey.generate())
    }

    func testQueryValuePercentEncodesPlusSlashAndEquals() throws {
        let raw = Data((0..<32).map { UInt8($0 * 8 % 256) })
        let key = try AVMDocumentKey(bytes: raw)
        XCTAssertFalse(key.queryValue.contains("+"))
        XCTAssertFalse(key.queryValue.contains("/"))
        XCTAssertFalse(key.queryValue.contains("="))
        XCTAssertEqual(key.queryValue.removingPercentEncoding, key.base64)
    }

    func testRejectsWrongLength() {
        XCTAssertThrowsError(try AVMDocumentKey(bytes: Data(repeating: 1, count: 16))) { error in
            guard case AVMDocumentKey.Failure.invalidLength(let count) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(count, 16)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMDocumentKeyTests`
Expected: compile error, `AVMDocumentKey` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import CryptoKit

/// Symmetric key that encrypts one document on the AVM server.
/// The server never stores it; every call about the document must carry it.
public struct AVMDocumentKey: Sendable, Equatable {
    public enum Failure: Error, Equatable {
        case invalidLength(Int)
    }

    public static let byteCount = 32

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw Failure.invalidLength(bytes.count)
        }
        self.bytes = bytes
    }

    public static func generate() -> AVMDocumentKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        // 256 bits is always 32 bytes, so the throwing initializer cannot fail here.
        return try! AVMDocumentKey(bytes: data)
    }

    /// Strict base64 as sent in the `X-Encryption-Key` header.
    public var base64: String {
        bytes.base64EncodedString()
    }

    /// Base64 percent-encoded for the `key` query parameter of the QR link.
    public var queryValue: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return base64.addingPercentEncoding(withAllowedCharacters: allowed) ?? base64
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMDocumentKeyTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Autogram/Sources/AutogramKit/Signing/AVM/AVMDocumentKey.swift Autogram/Tests/AutogramKitTests/AVMDocumentKeyTests.swift
git commit -m "feat(avm): document encryption key for Autogram v mobile" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: AVM models and errors

**Files:**
- Create: `Autogram/Sources/AutogramKit/Signing/AVM/AVMModels.swift`
- Test: `Autogram/Tests/AutogramKitTests/AVMClientTests.swift` (first test only; the file grows in Task 3)

**Interfaces:**
- Produces:
  - `public enum AVMSignatureLevel: String, Codable, Sendable` with cases `padesB`, `padesT`, `xadesB`, `xadesT`, `cadesB`, `cadesT` and `static func pades(timestamp: Bool)`, `static func xades(timestamp: Bool)`.
  - `public enum AVMContainer: String, Codable, Sendable { case asicE = "ASiC-E", asicS = "ASiC-S" }`.
  - `public struct AVMUploadRequest: Encodable, Sendable` with `init(filename: String, data: Data, mimeType: String, level: AVMSignatureLevel, container: AVMContainer? = nil)` and `static let pdfMimeType`, `static let asicEMimeType`.
  - `public struct AVMDocumentReference: Sendable, Equatable { guid: String, key: AVMDocumentKey, lastModified: String }`.
  - `public struct AVMSigner: Codable, Sendable, Equatable { signedBy: String?, issuedBy: String? }`.
  - `public struct AVMSignedDocument: Decodable, Sendable, Equatable { filename: String?, mimeType: String?, content: String, signers: [AVMSigner]? }` with `var data: Data?`.
  - `public enum AVMPollResult: Sendable, Equatable { case pending, signed(AVMSignedDocument) }`.
  - `public enum AVMError: Error, Equatable, LocalizedError` with `server(status: Int, code: String?, message: String?)`, `invalidResponse`, `timeout`, `cancelled`, `transport(String)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AutogramKit

final class AVMClientTests: XCTestCase {
    func testUploadRequestEncodesDocumentParametersAndMimeType() throws {
        let request = AVMUploadRequest(filename: "zmluva.pdf",
                                       data: Data("PDF".utf8),
                                       mimeType: AVMUploadRequest.pdfMimeType,
                                       level: .pades(timestamp: true),
                                       container: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let document = try XCTUnwrap(json?["document"] as? [String: Any])
        XCTAssertEqual(document["filename"] as? String, "zmluva.pdf")
        XCTAssertEqual(document["content"] as? String, Data("PDF".utf8).base64EncodedString())
        let parameters = try XCTUnwrap(json?["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["level"] as? String, "PAdES_BASELINE_T")
        XCTAssertNil(parameters["container"])
        XCTAssertEqual(json?["payloadMimeType"] as? String, "application/pdf")
    }

    func testSignedDocumentDecodesContentAndSigners() throws {
        let body = #"{"filename":"zmluva.pdf","mimeType":"application/pdf;base64","content":"UERG","signers":[{"signedBy":"Ján Novák","issuedBy":"SVK eID ACA2"}]}"#
        let document = try JSONDecoder().decode(AVMSignedDocument.self, from: Data(body.utf8))
        XCTAssertEqual(document.data, Data("PDF".utf8))
        XCTAssertEqual(document.signers?.first?.signedBy, "Ján Novák")
        XCTAssertEqual(document.signers?.first?.issuedBy, "SVK eID ACA2")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMClientTests`
Expected: compile error, `AVMUploadRequest` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum AVMSignatureLevel: String, Codable, Sendable, CaseIterable {
    case padesB = "PAdES_BASELINE_B"
    case padesT = "PAdES_BASELINE_T"
    case xadesB = "XAdES_BASELINE_B"
    case xadesT = "XAdES_BASELINE_T"
    case cadesB = "CAdES_BASELINE_B"
    case cadesT = "CAdES_BASELINE_T"

    public static func pades(timestamp: Bool) -> AVMSignatureLevel { timestamp ? .padesT : .padesB }
    public static func xades(timestamp: Bool) -> AVMSignatureLevel { timestamp ? .xadesT : .xadesB }
}

public enum AVMContainer: String, Codable, Sendable {
    case asicE = "ASiC-E"
    case asicS = "ASiC-S"
}

/// Body of `POST /documents`.
public struct AVMUploadRequest: Encodable, Sendable, Equatable {
    public static let pdfMimeType = "application/pdf"
    public static let asicEMimeType = "application/vnd.etsi.asic-e+zip"

    public struct Document: Encodable, Sendable, Equatable {
        public var filename: String
        /// Base64 of the raw file bytes.
        public var content: String
    }

    public struct Parameters: Encodable, Sendable, Equatable {
        public var level: AVMSignatureLevel
        public var container: AVMContainer?
    }

    public var document: Document
    public var parameters: Parameters
    public var payloadMimeType: String

    public init(filename: String, data: Data, mimeType: String,
                level: AVMSignatureLevel, container: AVMContainer? = nil) {
        self.document = Document(filename: filename, content: data.base64EncodedString())
        self.parameters = Parameters(level: level, container: container)
        self.payloadMimeType = mimeType
    }
}

/// Everything the client must remember to poll, download or delete one document.
public struct AVMDocumentReference: Sendable, Equatable {
    public var guid: String
    public var key: AVMDocumentKey
    /// HTTP date from the upload response, sent back as `If-Modified-Since`.
    public var lastModified: String

    public init(guid: String, key: AVMDocumentKey, lastModified: String) {
        self.guid = guid
        self.key = key
        self.lastModified = lastModified
    }
}

public struct AVMSigner: Codable, Sendable, Equatable {
    public var signedBy: String?
    public var issuedBy: String?

    public init(signedBy: String?, issuedBy: String?) {
        self.signedBy = signedBy
        self.issuedBy = issuedBy
    }
}

/// Body of `GET /documents/{guid}` once the document is signed.
public struct AVMSignedDocument: Decodable, Sendable, Equatable {
    public var filename: String?
    public var mimeType: String?
    public var content: String
    public var signers: [AVMSigner]?

    public init(filename: String?, mimeType: String?, content: String, signers: [AVMSigner]?) {
        self.filename = filename
        self.mimeType = mimeType
        self.content = content
        self.signers = signers
    }

    public var data: Data? {
        Data(base64Encoded: content) ?? Data(base64Encoded: content, options: .ignoreUnknownCharacters)
    }
}

public enum AVMPollResult: Sendable, Equatable {
    case pending
    case signed(AVMSignedDocument)
}

struct AVMServerErrorBody: Decodable {
    var code: String?
    var message: String?
    var details: String?
}

public enum AVMError: Error, Equatable, LocalizedError {
    case server(status: Int, code: String?, message: String?)
    case invalidResponse
    case timeout
    case cancelled
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .server(let status, let code, let message):
            let detail = [code, message].compactMap { $0 }.joined(separator: ": ")
            return detail.isEmpty
                ? "Server Autogram v mobile odpovedal chybou \(status)."
                : "Server Autogram v mobile odpovedal chybou \(status) (\(detail))."
        case .invalidResponse:
            return "Server Autogram v mobile vrátil neočakávanú odpoveď."
        case .timeout:
            return "Podpis z mobilu neprišiel včas."
        case .cancelled:
            return "Podpisovanie mobilom bolo zrušené."
        case .transport(let detail):
            return "Server Autogram v mobile je nedostupný (\(detail))."
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMClientTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Autogram/Sources/AutogramKit/Signing/AVM/AVMModels.swift Autogram/Tests/AutogramKitTests/AVMClientTests.swift
git commit -m "feat(avm): request, response and error models" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: AVMClient

**Files:**
- Create: `Autogram/Sources/AutogramKit/Signing/AVM/AVMClient.swift`
- Modify: `Autogram/Tests/AutogramKitTests/AVMClientTests.swift`

**Interfaces:**
- Consumes: Task 1 and Task 2 types.
- Produces:
  - `public protocol AVMHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`.
  - `public struct URLSessionAVMTransport: AVMHTTPTransport` with `init(session: URLSession = .shared)`.
  - `public struct AVMClient: Sendable` with `static let publicBaseURL: URL`, `init(baseURL: URL = AVMClient.publicBaseURL, transport: any AVMHTTPTransport = URLSessionAVMTransport())`, `func upload(_ request: AVMUploadRequest, key: AVMDocumentKey) async throws -> AVMDocumentReference`, `func fetchSigned(_ reference: AVMDocumentReference) async throws -> AVMPollResult`, `func delete(_ reference: AVMDocumentReference) async throws`, `func qrCodeURL(for reference: AVMDocumentReference) -> URL`.

- [ ] **Step 1: Write the failing tests**

Append to `AVMClientTests.swift` (inside the class) and add the helper at file bottom:

```swift
    private func key() throws -> AVMDocumentKey {
        try AVMDocumentKey(bytes: Data(repeating: 0xAB, count: 32))
    }

    private func response(status: Int, headers: [String: String] = [:], body: String = "") -> (Data, HTTPURLResponse) {
        let http = HTTPURLResponse(url: URL(string: "https://avm.test/api/v1/documents")!,
                                   statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), http)
    }

    func testUploadSendsKeyHeaderAndReturnsGuidWithLastModified() async throws {
        let transport = RecordingAVMTransport(responses: [
            .success(response(status: 200,
                              headers: ["Last-Modified": "Fri, 11 Sep 2026 10:00:01 GMT"],
                              body: #"{"guid":"abc-123"}"#))
        ])
        let client = AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport)
        let request = AVMUploadRequest(filename: "a.pdf", data: Data("PDF".utf8),
                                       mimeType: AVMUploadRequest.pdfMimeType, level: .padesB)

        let reference = try await client.upload(request, key: try key())

        XCTAssertEqual(reference.guid, "abc-123")
        XCTAssertEqual(reference.lastModified, "Fri, 11 Sep 2026 10:00:01 GMT")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://avm.test/api/v1/documents")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Encryption-Key"), try key().base64)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(sent.httpBody)
    }

    func testUploadWithoutLastModifiedFallsBackToHTTPDateNow() async throws {
        let transport = RecordingAVMTransport(responses: [
            .success(response(status: 200, body: #"{"guid":"abc"}"#))
        ])
        let client = AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport)
        let reference = try await client.upload(
            AVMUploadRequest(filename: "a.pdf", data: Data(), mimeType: "application/pdf", level: .padesB),
            key: try key())
        XCTAssertTrue(reference.lastModified.hasSuffix(" GMT"), reference.lastModified)
    }

    func testFetchSignedReturnsPendingOn304() async throws {
        let transport = RecordingAVMTransport(responses: [.success(response(status: 304))])
        let client = AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport)
        let reference = AVMDocumentReference(guid: "g1", key: try key(), lastModified: "Fri, 11 Sep 2026 10:00:01 GMT")

        let result = try await client.fetchSigned(reference)

        XCTAssertEqual(result, .pending)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.absoluteString, "https://avm.test/api/v1/documents/g1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "If-Modified-Since"), "Fri, 11 Sep 2026 10:00:01 GMT")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Encryption-Key"), try key().base64)
    }

    func testFetchSignedReturnsDocumentOn200() async throws {
        let transport = RecordingAVMTransport(responses: [
            .success(response(status: 200, body: #"{"filename":"a.pdf","mimeType":"application/pdf","content":"UERG","signers":[]}"#))
        ])
        let client = AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport)
        let reference = AVMDocumentReference(guid: "g1", key: try key(), lastModified: "x")

        let result = try await client.fetchSigned(reference)

        guard case .signed(let document) = result else { return XCTFail("expected signed") }
        XCTAssertEqual(document.data, Data("PDF".utf8))
    }

    func testServerErrorBodyBecomesAVMError() async throws {
        let transport = RecordingAVMTransport(responses: [
            .success(response(status: 401, body: #"{"code":"ENCRYPTION_KEY_MISSING","message":"Encryption key not provided."}"#))
        ])
        let client = AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport)
        let reference = AVMDocumentReference(guid: "g1", key: try key(), lastModified: "x")

        do {
            _ = try await client.fetchSigned(reference)
            XCTFail("expected throw")
        } catch let error as AVMError {
            XCTAssertEqual(error, .server(status: 401, code: "ENCRYPTION_KEY_MISSING", message: "Encryption key not provided."))
        }
    }

    func testTransportFailureBecomesAVMTransportError() async throws {
        let transport = RecordingAVMTransport(responses: [.failure(URLError(.notConnectedToInternet))])
        let client = AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport)
        do {
            _ = try await client.fetchSigned(AVMDocumentReference(guid: "g", key: try key(), lastModified: "x"))
            XCTFail("expected throw")
        } catch let error as AVMError {
            guard case .transport = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testDeleteSendsDeleteWithKey() async throws {
        let transport = RecordingAVMTransport(responses: [.success(response(status: 200))])
        let client = AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport)
        try await client.delete(AVMDocumentReference(guid: "g1", key: try key(), lastModified: "x"))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "DELETE")
        XCTAssertEqual(sent.url?.absoluteString, "https://avm.test/api/v1/documents/g1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Encryption-Key"), try key().base64)
    }

    func testQRCodeURLUsesBaseURLGuidAndEncodedKey() throws {
        let client = AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: RecordingAVMTransport(responses: []))
        let reference = AVMDocumentReference(guid: "g1", key: try key(), lastModified: "x")
        let url = client.qrCodeURL(for: reference)
        XCTAssertEqual(url.absoluteString, "https://avm.test/api/v1/qr-code?guid=g1&key=\(try key().queryValue)")
    }
}

private final class RecordingAVMTransport: AVMHTTPTransport, @unchecked Sendable {
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
```

Note: the earlier closing brace of the class must be removed so these methods sit inside `AVMClientTests`, and `RecordingAVMTransport` sits after the class.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMClientTests`
Expected: compile error, `AVMClient` and `AVMHTTPTransport` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public protocol AVMHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionAVMTransport: AVMHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AVMError.invalidResponse }
        return (data, http)
    }
}

/// Client for the Autogram v mobile relay server (`avm-server`).
public struct AVMClient: Sendable {
    public static let publicBaseURL = URL(string: "https://autogram.slovensko.digital/api/v1")!

    public let baseURL: URL
    private let transport: any AVMHTTPTransport

    public init(baseURL: URL = AVMClient.publicBaseURL,
                transport: any AVMHTTPTransport = URLSessionAVMTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    private struct UploadResponse: Decodable {
        var guid: String
    }

    public func upload(_ request: AVMUploadRequest, key: AVMDocumentKey) async throws -> AVMDocumentReference {
        var http = URLRequest(url: baseURL.appendingPathComponent("documents"))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.setValue(key.base64, forHTTPHeaderField: "X-Encryption-Key")
        http.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await send(http)
        guard response.statusCode == 200 else { throw Self.serverError(status: response.statusCode, body: data) }
        let decoded: UploadResponse
        do {
            decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
        } catch {
            throw AVMError.invalidResponse
        }
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? Self.httpDate(Date())
        return AVMDocumentReference(guid: decoded.guid, key: key, lastModified: lastModified)
    }

    public func fetchSigned(_ reference: AVMDocumentReference) async throws -> AVMPollResult {
        var http = URLRequest(url: baseURL.appendingPathComponent("documents/\(reference.guid)"))
        http.httpMethod = "GET"
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.setValue(reference.key.base64, forHTTPHeaderField: "X-Encryption-Key")
        http.setValue(reference.lastModified, forHTTPHeaderField: "If-Modified-Since")
        http.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await send(http)
        switch response.statusCode {
        case 304:
            return .pending
        case 200:
            do {
                return .signed(try JSONDecoder().decode(AVMSignedDocument.self, from: data))
            } catch {
                throw AVMError.invalidResponse
            }
        default:
            throw Self.serverError(status: response.statusCode, body: data)
        }
    }

    public func delete(_ reference: AVMDocumentReference) async throws {
        var http = URLRequest(url: baseURL.appendingPathComponent("documents/\(reference.guid)"))
        http.httpMethod = "DELETE"
        http.setValue(reference.key.base64, forHTTPHeaderField: "X-Encryption-Key")
        let (data, response) = try await send(http)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
            throw Self.serverError(status: response.statusCode, body: data)
        }
    }

    /// Link encoded into the QR code. The AVM app accepts only the public host.
    public func qrCodeURL(for reference: AVMDocumentReference) -> URL {
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        return URL(string: "\(base)/qr-code?guid=\(reference.guid)&key=\(reference.key.queryValue)")!
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as AVMError {
            throw error
        } catch {
            throw AVMError.transport(error.localizedDescription)
        }
    }

    static func serverError(status: Int, body: Data) -> AVMError {
        let parsed = try? JSONDecoder().decode(AVMServerErrorBody.self, from: body)
        return .server(status: status, code: parsed?.code, message: parsed?.message)
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMClientTests`
Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Autogram/Sources/AutogramKit/Signing/AVM/AVMClient.swift Autogram/Tests/AutogramKitTests/AVMClientTests.swift
git commit -m "feat(avm): HTTP client for upload, polling, delete and QR link" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: QRCodeRenderer

**Files:**
- Create: `Autogram/Sources/AutogramKit/Signing/AVM/QRCodeRenderer.swift`
- Test: `Autogram/Tests/AutogramKitTests/QRCodeRendererTests.swift`

**Interfaces:**
- Produces: `public enum QRCodeRenderer { public static func image(for text: String, side: Int) -> CGImage? }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CoreGraphics
@testable import AutogramKit

final class QRCodeRendererTests: XCTestCase {
    func testRendersSquareImageOfRequestedSide() throws {
        let image = try XCTUnwrap(QRCodeRenderer.image(
            for: "https://autogram.slovensko.digital/api/v1/qr-code?guid=abc&key=xyz", side: 320))
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 320)
    }

    func testEmptyStringProducesNoImage() {
        XCTAssertNil(QRCodeRenderer.image(for: "", side: 100))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter QRCodeRendererTests`
Expected: compile error, `QRCodeRenderer` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import CoreImage
import CoreGraphics

public enum QRCodeRenderer {
    /// Renders `text` as a QR code with medium error correction, scaled with
    /// nearest-neighbour sampling so modules stay crisp.
    public static func image(for text: String, side: Int) -> CGImage? {
        guard !text.isEmpty, side > 0,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = CGFloat(side) / output.extent.width
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let target = CGRect(x: 0, y: 0, width: side, height: side)
        return context.createCGImage(scaled, from: target)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter QRCodeRendererTests`
Expected: 2 tests pass. If the width differs by rounding, round `scale` up with `ceil` and crop with `target`; the `createCGImage(_:from:)` call already crops to `target`.

- [ ] **Step 5: Commit**

```bash
git add Autogram/Sources/AutogramKit/Signing/AVM/QRCodeRenderer.swift Autogram/Tests/AutogramKitTests/QRCodeRendererTests.swift
git commit -m "feat(avm): CoreImage QR code renderer" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: AVMResultMapper

**Files:**
- Create: `Autogram/Sources/AutogramKit/Signing/AVM/AVMResultMapper.swift`
- Test: `Autogram/Tests/AutogramKitTests/AVMResultMapperTests.swift`
- Reference: `Autogram/Sources/AutogramKit/Signing/JavaEngine/EngineBridgeSigningProvider.swift:501-522` (`isQualifiedCertificate`, `isMandateCertificate` heuristics, internal static).

**Interfaces:**
- Consumes: `AVMSignedDocument`, `AVMSigner`, `SignedConversionResult`, `SigningOutputFormat`.
- Produces: `public enum AVMResultMapper` with
  - `static func signatureLabel(signers: [AVMSigner]) -> String`
  - `static func isQualified(signers: [AVMSigner]) -> Bool`
  - `static func isMandate(signers: [AVMSigner]) -> Bool`
  - `static func conversionResult(from document: AVMSignedDocument, outputFormat: SigningOutputFormat, uploadedPDF: Data, signedAt: Date = Date()) throws -> SignedConversionResult` (throws `AVMError.invalidResponse` when content is not base64).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AutogramKit

final class AVMResultMapperTests: XCTestCase {
    private let personal = [AVMSigner(signedBy: "Ján Novák", issuedBy: "SVK eID ACA2")]
    private let mandate = [AVMSigner(signedBy: "JUDr. Ján Novák, advokát", issuedBy: "CA Disig QCA3")]

    func testPAdESResultKeepsSignedPDFAndNoContainer() throws {
        let document = AVMSignedDocument(filename: "a.pdf", mimeType: "application/pdf",
                                         content: Data("SIGNED".utf8).base64EncodedString(), signers: personal)
        let result = try AVMResultMapper.conversionResult(from: document, outputFormat: .embeddedPAdES,
                                                          uploadedPDF: Data("ORIG".utf8))
        XCTAssertEqual(result.pdfData, Data("SIGNED".utf8))
        XCTAssertNil(result.asicData)
        XCTAssertEqual(result.signatureLabel, "Ján Novák")
        XCTAssertTrue(result.isLegallyBinding)
        XCTAssertNil(result.timestampGenTime)
    }

    func testASiCResultKeepsUploadedPDFAndContainer() throws {
        let document = AVMSignedDocument(filename: "a.asice", mimeType: "application/vnd.etsi.asic-e+zip",
                                         content: Data("ZIP".utf8).base64EncodedString(), signers: personal)
        let result = try AVMResultMapper.conversionResult(from: document, outputFormat: .attachedASIC,
                                                          uploadedPDF: Data("ORIG".utf8))
        XCTAssertEqual(result.pdfData, Data("ORIG".utf8))
        XCTAssertEqual(result.asicData, Data("ZIP".utf8))
    }

    func testInvalidBase64Throws() {
        let document = AVMSignedDocument(filename: nil, mimeType: nil, content: "***", signers: nil)
        XCTAssertThrowsError(try AVMResultMapper.conversionResult(from: document, outputFormat: .embeddedPAdES, uploadedPDF: Data()))
    }

    func testMandateDetectionUsesSignerStrings() {
        XCTAssertFalse(AVMResultMapper.isMandate(signers: personal))
        XCTAssertTrue(AVMResultMapper.isMandate(signers: mandate))
        XCTAssertFalse(AVMResultMapper.isMandate(signers: []))
    }

    func testLabelJoinsMultipleSigners() {
        let label = AVMResultMapper.signatureLabel(signers: personal + mandate)
        XCTAssertEqual(label, "Ján Novák, JUDr. Ján Novák, advokát")
        XCTAssertEqual(AVMResultMapper.signatureLabel(signers: []), "Podpis z Autogram v mobile")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMResultMapperTests`
Expected: compile error, `AVMResultMapper` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Turns the AVM server answer into the fork's `SignedConversionResult` and
/// classifies the signer using the same string heuristics the engine bridge uses.
public enum AVMResultMapper {
    public static let fallbackLabel = "Podpis z Autogram v mobile"

    public static func signatureLabel(signers: [AVMSigner]) -> String {
        let names = signers.compactMap { $0.signedBy?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? fallbackLabel : names.joined(separator: ", ")
    }

    public static func isQualified(signers: [AVMSigner]) -> Bool {
        signers.contains { signer in
            EngineBridgeSigningProvider.isQualifiedCertificate(
                issuer: signer.issuedBy ?? "", displayName: signer.signedBy ?? "", qualification: nil)
        }
    }

    public static func isMandate(signers: [AVMSigner]) -> Bool {
        signers.contains { signer in
            EngineBridgeSigningProvider.isMandateCertificate(
                issuer: signer.issuedBy ?? "", displayName: signer.signedBy ?? "")
        }
    }

    public static func conversionResult(from document: AVMSignedDocument,
                                        outputFormat: SigningOutputFormat,
                                        uploadedPDF: Data,
                                        signedAt: Date = Date()) throws -> SignedConversionResult {
        guard let payload = document.data else { throw AVMError.invalidResponse }
        let signers = document.signers ?? []
        switch outputFormat {
        case .embeddedPAdES:
            return SignedConversionResult(pdfData: payload, asicData: nil, signedAt: signedAt,
                                          signatureLabel: signatureLabel(signers: signers),
                                          isLegallyBinding: isQualified(signers: signers))
        case .attachedASIC:
            return SignedConversionResult(pdfData: uploadedPDF, asicData: payload, signedAt: signedAt,
                                          signatureLabel: signatureLabel(signers: signers),
                                          isLegallyBinding: isQualified(signers: signers))
        }
    }
}
```

If `isMandateCertificate` does not recognise the sample `mandate` signer strings used in the test, read the heuristic at `EngineBridgeSigningProvider.swift:513` and adjust the test fixture strings to ones it accepts (for example a display name containing "advokát" or an issuer containing "mandát"). Do not weaken the heuristic.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMResultMapperTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Autogram/Sources/AutogramKit/Signing/AVM/AVMResultMapper.swift Autogram/Tests/AutogramKitTests/AVMResultMapperTests.swift
git commit -m "feat(avm): map signed documents to SignedConversionResult" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: AVMSigningSession

**Files:**
- Create: `Autogram/Sources/AutogramKit/Signing/AVM/AVMSigningSession.swift`
- Test: `Autogram/Tests/AutogramKitTests/AVMSigningSessionTests.swift`

**Interfaces:**
- Consumes: `AVMClient`, `AVMUploadRequest`, `AVMDocumentReference`, `AVMPollResult`, `AVMSignedDocument`, `AVMError`, `QRCodeRenderer`.
- Produces: `@MainActor @Observable public final class AVMSigningSession` with
  - `public enum State: Equatable { idle, uploading, waitingForScan(qrURL: URL), downloading, signed(AVMSignedDocument), failed(String), cancelled }`
  - `public private(set) var state: State`, `public private(set) var qrImage: CGImage?`, `public private(set) var deadline: Date?`
  - `public init(client: AVMClient, pollInterval: Duration = .seconds(1), timeout: Duration = .seconds(900), qrSide: Int = 512)`
  - `public func run(_ request: AVMUploadRequest) async throws -> AVMSignedDocument`
  - `public func cancel()`
  - `public var isActive: Bool`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import AutogramKit

@MainActor
final class AVMSigningSessionTests: XCTestCase {
    private func key() throws -> AVMDocumentKey {
        try AVMDocumentKey(bytes: Data(repeating: 7, count: 32))
    }

    private func response(status: Int, headers: [String: String] = [:], body: String = "") -> (Data, HTTPURLResponse) {
        let http = HTTPURLResponse(url: URL(string: "https://avm.test/api/v1/documents")!,
                                   statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), http)
    }

    private func request() -> AVMUploadRequest {
        AVMUploadRequest(filename: "a.pdf", data: Data("PDF".utf8),
                         mimeType: AVMUploadRequest.pdfMimeType, level: .padesB)
    }

    func testRunUploadsPollsAndReturnsSignedDocument() async throws {
        let transport = ScriptedAVMTransport(responses: [
            .success(response(status: 200, headers: ["Last-Modified": "Fri, 11 Sep 2026 10:00:01 GMT"], body: #"{"guid":"g1"}"#)),
            .success(response(status: 304)),
            .success(response(status: 304)),
            .success(response(status: 200, body: #"{"filename":"a.pdf","mimeType":"application/pdf","content":"UERG","signers":[]}"#))
        ])
        let session = AVMSigningSession(client: AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport),
                                        pollInterval: .milliseconds(5), timeout: .seconds(5), qrSide: 64)

        let document = try await session.run(request())

        XCTAssertEqual(document.data, Data("PDF".utf8))
        XCTAssertEqual(session.state, .signed(document))
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(transport.requests[1].httpMethod, "GET")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "If-Modified-Since"), "Fri, 11 Sep 2026 10:00:01 GMT")
    }

    func testStateShowsQRAfterUpload() async throws {
        let transport = ScriptedAVMTransport(responses: [
            .success(response(status: 200, body: #"{"guid":"g1"}"#))
        ], holdAfter: 1)
        let session = AVMSigningSession(client: AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport),
                                        pollInterval: .milliseconds(5), timeout: .seconds(5), qrSide: 64)
        let task = Task { try await session.run(request()) }

        try await waitUntil { if case .waitingForScan = session.state { return true } else { return false } }

        guard case .waitingForScan(let url) = session.state else { return XCTFail("expected waiting") }
        XCTAssertTrue(url.absoluteString.hasPrefix("https://avm.test/api/v1/qr-code?guid=g1&key="))
        XCTAssertNotNil(session.qrImage)
        XCTAssertNotNil(session.deadline)
        XCTAssertTrue(session.isActive)
        session.cancel()
        _ = await task.result
    }

    func testCancelDeletesDocumentAndThrowsCancelled() async throws {
        let transport = ScriptedAVMTransport(responses: [
            .success(response(status: 200, body: #"{"guid":"g1"}"#))
        ], holdAfter: 1, deleteResponse: .success(response(status: 200)))
        let session = AVMSigningSession(client: AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport),
                                        pollInterval: .milliseconds(5), timeout: .seconds(5), qrSide: 64)
        let task = Task { try await session.run(request()) }
        try await waitUntil { if case .waitingForScan = session.state { return true } else { return false } }

        session.cancel()
        let result = await task.result

        guard case .failure(let error as AVMError) = result else { return XCTFail("expected AVMError") }
        XCTAssertEqual(error, .cancelled)
        XCTAssertEqual(session.state, .cancelled)
        try await waitUntil { transport.requests.contains { $0.httpMethod == "DELETE" } }
        XCTAssertFalse(session.isActive)
    }

    func testTimeoutFailsAndDeletes() async throws {
        let transport = ScriptedAVMTransport(responses: [
            .success(response(status: 200, body: #"{"guid":"g1"}"#))
        ], pendingForever: true, deleteResponse: .success(response(status: 200)))
        let session = AVMSigningSession(client: AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport),
                                        pollInterval: .milliseconds(5), timeout: .milliseconds(40), qrSide: 64)

        do {
            _ = try await session.run(request())
            XCTFail("expected timeout")
        } catch let error as AVMError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertEqual(session.state, .failed(AVMError.timeout.localizedDescription))
        try await waitUntil { transport.requests.contains { $0.httpMethod == "DELETE" } }
    }

    func testUploadFailureReportsFailedState() async throws {
        let transport = ScriptedAVMTransport(responses: [
            .success(response(status: 422, body: #"{"code":"INVALID","message":"Document must be a PDF when using PAdES."}"#))
        ])
        let session = AVMSigningSession(client: AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport),
                                        pollInterval: .milliseconds(5), timeout: .seconds(1), qrSide: 64)
        do {
            _ = try await session.run(request())
            XCTFail("expected failure")
        } catch let error as AVMError {
            guard case .server(let status, _, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(status, 422)
        }
        guard case .failed(let message) = session.state else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("422"), message)
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout { throw XCTSkip("condition not met in time") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Serves scripted responses. After `holdAfter` requests it keeps every further GET
/// pending with 304; `pendingForever` does the same from the first poll. DELETE is
/// answered from `deleteResponse`.
private final class ScriptedAVMTransport: AVMHTTPTransport, @unchecked Sendable {
    typealias Response = Result<(Data, HTTPURLResponse), Error>

    private let lock = NSLock()
    private var responses: [Response]
    private let holdAfter: Int?
    private let pendingForever: Bool
    private let deleteResponse: Response?
    private(set) var requests: [URLRequest] = []

    init(responses: [Response], holdAfter: Int? = nil, pendingForever: Bool = false, deleteResponse: Response? = nil) {
        self.responses = responses
        self.holdAfter = holdAfter
        self.pendingForever = pendingForever
        self.deleteResponse = deleteResponse
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let scripted: Response? = lock.withLock {
            requests.append(request)
            if request.httpMethod == "DELETE" { return deleteResponse }
            let served = requests.count - 1
            if let holdAfter, served >= holdAfter { return nil }
            if pendingForever, served >= 1 { return nil }
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        if let scripted { return try scripted.get() }
        let http = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
        return (Data(), http)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMSigningSessionTests`
Expected: compile error, `AVMSigningSession` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import CoreGraphics
import Observation

/// One document, one QR code, one signature. Drives upload, polling, timeout
/// and cancellation and exposes observable state for the QR sheet.
@MainActor
@Observable
public final class AVMSigningSession {
    public enum State: Equatable {
        case idle
        case uploading
        case waitingForScan(qrURL: URL)
        case downloading
        case signed(AVMSignedDocument)
        case failed(String)
        case cancelled
    }

    public private(set) var state: State = .idle
    public private(set) var qrImage: CGImage?
    public private(set) var deadline: Date?

    private let client: AVMClient
    private let pollInterval: Duration
    private let timeout: Duration
    private let qrSide: Int
    private var reference: AVMDocumentReference?
    private var runTask: Task<AVMSignedDocument, Error>?

    public init(client: AVMClient,
                pollInterval: Duration = .seconds(1),
                timeout: Duration = .seconds(900),
                qrSide: Int = 512) {
        self.client = client
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.qrSide = qrSide
    }

    public var isActive: Bool {
        switch state {
        case .uploading, .waitingForScan, .downloading: return true
        case .idle, .signed, .failed, .cancelled: return false
        }
    }

    public func run(_ request: AVMUploadRequest) async throws -> AVMSignedDocument {
        let task = Task<AVMSignedDocument, Error> { [weak self] in
            guard let self else { throw AVMError.cancelled }
            return try await self.execute(request)
        }
        runTask = task
        defer { runTask = nil }
        return try await task.value
    }

    public func cancel() {
        runTask?.cancel()
    }

    private func execute(_ request: AVMUploadRequest) async throws -> AVMSignedDocument {
        state = .uploading
        qrImage = nil
        deadline = nil
        do {
            let key = AVMDocumentKey.generate()
            let reference = try await client.upload(request, key: key)
            self.reference = reference
            try Task.checkCancellation()

            let qrURL = client.qrCodeURL(for: reference)
            qrImage = QRCodeRenderer.image(for: qrURL.absoluteString, side: qrSide)
            let start = ContinuousClock.now
            deadline = Date().addingTimeInterval(Self.seconds(timeout))
            state = .waitingForScan(qrURL: qrURL)

            while true {
                try Task.checkCancellation()
                if ContinuousClock.now - start >= timeout { throw AVMError.timeout }
                let result = try await client.fetchSigned(reference)
                switch result {
                case .pending:
                    try await Task.sleep(for: pollInterval)
                case .signed(let document):
                    state = .signed(document)
                    self.reference = nil
                    return document
                }
            }
        } catch is CancellationError {
            state = .cancelled
            scheduleDelete()
            throw AVMError.cancelled
        } catch let error as AVMError {
            if error == .cancelled {
                state = .cancelled
            } else {
                state = .failed(error.localizedDescription)
            }
            scheduleDelete()
            throw error
        } catch {
            state = .failed(error.localizedDescription)
            scheduleDelete()
            throw error
        }
    }

    /// Best-effort cleanup; the server deletes the document after 24 hours anyway.
    private func scheduleDelete() {
        guard let reference else { return }
        self.reference = nil
        let client = self.client
        Task.detached(priority: .utility) {
            try? await client.delete(reference)
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AVMSigningSessionTests`
Expected: 5 tests pass. If `testCancelDeletesDocumentAndThrowsCancelled` sees `.failed` instead of `.cancelled`, the cancellation surfaced as `AVMError.transport` from the transport layer: in `AVMClient.send` add `catch is CancellationError { throw CancellationError() }` before the generic catch, and in `URLSessionAVMTransport` let `URLError.cancelled` map to `CancellationError()`.

- [ ] **Step 5: Commit**

```bash
git add Autogram/Sources/AutogramKit/Signing/AVM/AVMSigningSession.swift Autogram/Tests/AutogramKitTests/AVMSigningSessionTests.swift Autogram/Sources/AutogramKit/Signing/AVM/AVMClient.swift
git commit -m "feat(avm): observable signing session with polling, timeout and cancel" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: avm-probe executable and real-server checkpoint

**Files:**
- Create: `Autogram/Sources/avm-probe/main.swift`
- Modify: `Autogram/Package.swift` (add target after `vision-eval`)

**Interfaces:**
- Consumes: `AVMClient`, `AVMDocumentKey`, `AVMUploadRequest`, `AVMSignatureLevel`, `AVMContainer`, `QRCodeRenderer`, `AVMResultMapper`.

- [ ] **Step 1: Register the target**

In `Autogram/Package.swift`, after the `vision-eval` target add:

```swift
        .executableTarget(
            name: "avm-probe",
            dependencies: ["AutogramKit"]
        ),
```

- [ ] **Step 2: Write the probe**

```swift
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AutogramKit

// Usage: avm-probe <file.pdf|file.asice> [--level PAdES_BASELINE_B] [--container ASiC-E] [--base-url <url>] [--out <dir>] [--timeout <seconds>]
// Uploads the file to the AVM server, prints the QR link, writes qr.png next to the
// output, polls until the phone signs, then saves the signed file and prints signers.

var args = Array(CommandLine.arguments.dropFirst())
guard let inputPath = args.first else {
    FileHandle.standardError.write(Data("usage: avm-probe <file> [--level L] [--container C] [--base-url U] [--out DIR] [--timeout S]\n".utf8))
    exit(2)
}
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let input = URL(fileURLWithPath: inputPath)
let data = try Data(contentsOf: input)
let ext = input.pathExtension.lowercased()
let isContainer = ext == "asice" || ext == "sce"
let mimeType = isContainer ? AVMUploadRequest.asicEMimeType : AVMUploadRequest.pdfMimeType
let level = AVMSignatureLevel(rawValue: option("--level") ?? (isContainer ? "XAdES_BASELINE_B" : "PAdES_BASELINE_B"))
    ?? (isContainer ? .xadesB : .padesB)
let container = option("--container").flatMap(AVMContainer.init(rawValue:))
let baseURL = option("--base-url").flatMap(URL.init(string:)) ?? AVMClient.publicBaseURL
let outDir = URL(fileURLWithPath: option("--out") ?? FileManager.default.currentDirectoryPath, isDirectory: true)
let timeoutSeconds = Double(option("--timeout") ?? "900") ?? 900

let client = AVMClient(baseURL: baseURL)
let key = AVMDocumentKey.generate()
let request = AVMUploadRequest(filename: input.lastPathComponent, data: data, mimeType: mimeType,
                               level: level, container: container)

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        print("Uploading \(input.lastPathComponent) (\(data.count) bytes) as \(mimeType), level \(level.rawValue), container \(container?.rawValue ?? "none")")
        let reference = try await client.upload(request, key: key)
        let qrURL = client.qrCodeURL(for: reference)
        print("GUID: \(reference.guid)")
        print("QR link: \(qrURL.absoluteString)")
        if let image = QRCodeRenderer.image(for: qrURL.absoluteString, side: 512) {
            let qrPath = outDir.appendingPathComponent("avm-qr.png")
            writePNG(image, to: qrPath)
            print("QR image: \(qrPath.path) (open it and scan with the iPhone camera)")
            NSWorkspace.shared.open(qrPath)
        }
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            let result = try await client.fetchSigned(reference)
            if case .signed(let document) = result {
                guard let payload = document.data else { throw AVMError.invalidResponse }
                let name = document.filename ?? "signed-\(input.lastPathComponent)"
                let target = outDir.appendingPathComponent("avm-signed-\(name)")
                try payload.write(to: target)
                print("Signed file: \(target.path) (\(payload.count) bytes, \(document.mimeType ?? "unknown mime"))")
                for signer in document.signers ?? [] {
                    print("Signer: \(signer.signedBy ?? "?") issued by \(signer.issuedBy ?? "?")")
                }
                print("Qualified: \(AVMResultMapper.isQualified(signers: document.signers ?? []))")
                print("Mandate: \(AVMResultMapper.isMandate(signers: document.signers ?? []))")
                semaphore.signal()
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        print("Timed out, deleting document")
        try? await client.delete(reference)
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
semaphore.wait()
```

- [ ] **Step 3: Build**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build --product avm-probe`
Expected: builds without errors.

- [ ] **Step 4: Commit**

```bash
git add Autogram/Package.swift Autogram/Sources/avm-probe/main.swift
git commit -m "feat(avm): avm-probe CLI for end-to-end checks against the AVM server" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 5: Real-server checkpoint (manual, needs the user's iPhone and eID)**

Run each and record the outcome in `docs/superpowers/specs/2026-09-11-avm-mobile-signing-design.md` under a new "Overené na serveri" section:

```bash
cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift run avm-probe ~/Desktop/test.pdf --level PAdES_BASELINE_T --out /tmp
```
Check: the phone opens the document, signs, the probe saves a PDF. Open the PDF in Autogram macOS and confirm the signature panel shows a qualified timestamp.

```bash
cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift run avm-probe ~/Desktop/test.pdf --level XAdES_BASELINE_B --container ASiC-E --out /tmp
```
Check: the result is an `.asice` and `ASiCEContainerVerifier` accepts it (drop it on the Signing intake).

```bash
cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift run avm-probe /tmp/unsigned-zako.asice --level XAdES_BASELINE_B --out /tmp
```
Build `/tmp/unsigned-zako.asice` once with a throwaway test in `AVMResultMapperTests` or a scratch script calling `ASiCEPackager().package(files: ASiCEPackager().zakoContainer(...))`. Check: both files (PDF and XML) are covered by the signature. If the server rejects unsigned containers or signs only one file, note it: Task 10 then uploads the PDF with `container: .asicE` and the ZaKo branch is marked unsupported until a follow-up.

Also record whether `Mandate:` printed true for the user's eID. If false, the ZaKo mobile button stays but refuses after signing (Task 10 behaviour).

---

### Task 8: Settings for mobile signing

**Files:**
- Modify: `Autogram/Sources/AutogramKit/Support/AppSettings.swift` (fields at line 87, `CodingKeys` at 89-98, `init` at 100-141, `init(from:)` at 143 onward)
- Modify: `Autogram/Sources/AutogramApp/Views/SettingsView.swift` (add card; place it directly after the TSA card whose picker is at line 501)
- Test: `Autogram/Tests/AutogramKitTests/AppSettingsLearningTests.swift` (add one test)

**Interfaces:**
- Produces: `AppSettings.mobileSigningEnabled: Bool` (default `true`), `AppSettings.avmBaseURL: String` (default `AVMClient.publicBaseURL.absoluteString`), `AppSettings.avmBaseURLValue: URL` (parsed, falls back to public URL). View `MobileSigningCard`.

- [ ] **Step 1: Write the failing test**

Append to `AppSettingsLearningTests.swift`:

```swift
    func testMobileSigningDefaultsAndRoundTrip() throws {
        let defaults = AppSettings()
        XCTAssertTrue(defaults.mobileSigningEnabled)
        XCTAssertEqual(defaults.avmBaseURL, "https://autogram.slovensko.digital/api/v1")
        XCTAssertEqual(defaults.avmBaseURLValue, AVMClient.publicBaseURL)

        var custom = defaults
        custom.mobileSigningEnabled = false
        custom.avmBaseURL = "https://avm.test/api/v1"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertFalse(decoded.mobileSigningEnabled)
        XCTAssertEqual(decoded.avmBaseURLValue, URL(string: "https://avm.test/api/v1"))

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.mobileSigningEnabled)

        var broken = defaults
        broken.avmBaseURL = "not a url"
        XCTAssertEqual(broken.avmBaseURLValue, AVMClient.publicBaseURL)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AppSettingsLearningTests`
Expected: compile error, `mobileSigningEnabled` not found.

- [ ] **Step 3: Implement the settings fields**

In `AppSettings`:
- After `public var learnFromReviews: Bool` add:
```swift
    /// Show "Podpísať mobilom" and allow signing through Autogram v mobile.
    public var mobileSigningEnabled: Bool
    /// AVM server base URL. Only the public host works with the App Store app; kept configurable for testing.
    public var avmBaseURL: String

    public var avmBaseURLValue: URL {
        let trimmed = avmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            return AVMClient.publicBaseURL
        }
        return url
    }
```
- Add `case mobileSigningEnabled, avmBaseURL` to `CodingKeys`.
- Add parameters `mobileSigningEnabled: Bool = true, avmBaseURL: String = AVMClient.publicBaseURL.absoluteString` at the end of the memberwise `init` and assign them.
- In `init(from:)` add:
```swift
        self.mobileSigningEnabled = try container.decodeIfPresent(Bool.self, forKey: .mobileSigningEnabled) ?? true
        self.avmBaseURL = try container.decodeIfPresent(String.self, forKey: .avmBaseURL) ?? AVMClient.publicBaseURL.absoluteString
```
- If `AppSettings` has a custom `encode(to:)`, add both keys there too.

- [ ] **Step 4: Add the settings card**

At the end of `SettingsView.swift` add:

```swift
struct MobileSigningCard: View {
    @Bindable var settingsStore: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Podpisovanie mobilom").font(.headline)
            Toggle("Ponúkať podpis cez Autogram v mobile (občiansky preukaz s NFC)",
                   isOn: $settingsStore.settings.mobileSigningEnabled)
            Text("Dokument sa zašifruje kľúčom, ktorý pozná len tento Mac, nahrá sa na server Slovensko.Digital a po naskenovaní QR kódu ho podpíšete v aplikácii Autogram v mobile. Server dokument zmaže do 24 hodín.")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("https://autogram.slovensko.digital/api/v1", text: $settingsStore.settings.avmBaseURL)
                .textFieldStyle(.roundedBorder)
                .disabled(!settingsStore.settings.mobileSigningEnabled)
            Text("Aplikácia Autogram v mobile otvára len odkazy z autogram.slovensko.digital. Iný server je určený len na testovanie.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .liquidGlass()
    }
}
```

Insert `MobileSigningCard(settingsStore: settingsStore)` directly after the closing of the TSA card that contains the `Picker("Aktívna TSA", ...)` at line 501. Follow whatever container modifier the neighbouring cards use if it is not `.liquidGlass()`; open `DesignSystem.swift` to confirm the modifier name.

- [ ] **Step 5: Run tests and build the app**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AppSettingsLearningTests && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build`
Expected: test passes, app builds.

- [ ] **Step 6: Commit**

```bash
git add Autogram/Sources/AutogramKit/Support/AppSettings.swift Autogram/Sources/AutogramApp/Views/SettingsView.swift Autogram/Tests/AutogramKitTests/AppSettingsLearningTests.swift
git commit -m "feat(avm): mobile signing settings and card" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: MobileSigningCoordinator and QR sheet

**Files:**
- Create: `Autogram/Sources/AutogramApp/MobileSigningCoordinator.swift`
- Create: `Autogram/Sources/AutogramApp/Views/MobileSigningSheet.swift`
- Test: `Autogram/Tests/AutogramAppTests/MobileSigningCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AVMSigningSession`, `AVMClient`, `AVMUploadRequest`, `AVMSignedDocument`, `AppSettingsStore`.
- Produces:
  - `@MainActor @Observable final class MobileSigningCoordinator` with `var isPresented: Bool`, `private(set) var session: AVMSigningSession?`, `init(clientFactory: @escaping @MainActor () -> AVMClient)`, `func sign(_ request: AVMUploadRequest) async throws -> AVMSignedDocument`, `func cancel()`.
  - `struct MobileSigningSheet: View` with `init(session: AVMSigningSession, onCancel: @escaping () -> Void)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AutogramKit
@testable import AutogramApp

@MainActor
final class MobileSigningCoordinatorTests: XCTestCase {
    func testSignPresentsSheetAndDismissesOnCompletion() async throws {
        let transport = OneShotAVMTransport(bodies: [
            (200, ["Last-Modified": "Fri, 11 Sep 2026 10:00:01 GMT"], #"{"guid":"g1"}"#),
            (200, [:], #"{"filename":"a.pdf","mimeType":"application/pdf","content":"UERG","signers":[]}"#)
        ])
        let coordinator = MobileSigningCoordinator(clientFactory: {
            AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport)
        }, pollInterval: .milliseconds(5))

        let document = try await coordinator.sign(
            AVMUploadRequest(filename: "a.pdf", data: Data("PDF".utf8), mimeType: AVMUploadRequest.pdfMimeType, level: .padesB))

        XCTAssertEqual(document.data, Data("PDF".utf8))
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertNil(coordinator.session)
    }

    func testCancelDismissesAndThrowsCancelled() async throws {
        let transport = OneShotAVMTransport(bodies: [(200, [:], #"{"guid":"g1"}"#)])
        let coordinator = MobileSigningCoordinator(clientFactory: {
            AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!, transport: transport)
        }, pollInterval: .milliseconds(5))
        let task = Task {
            try await coordinator.sign(AVMUploadRequest(filename: "a.pdf", data: Data(), mimeType: "application/pdf", level: .padesB))
        }
        while !coordinator.isPresented { try await Task.sleep(for: .milliseconds(5)) }

        coordinator.cancel()
        let result = await task.result

        guard case .failure(let error as AVMError) = result else { return XCTFail("expected AVMError") }
        XCTAssertEqual(error, .cancelled)
        XCTAssertFalse(coordinator.isPresented)
    }
}

private final class OneShotAVMTransport: AVMHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [(Int, [String: String], String)]

    init(bodies: [(Int, [String: String], String)]) { self.bodies = bodies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: (Int, [String: String], String)? = lock.withLock { bodies.isEmpty ? nil : bodies.removeFirst() }
        if request.httpMethod == "DELETE" || next == nil {
            let status = request.httpMethod == "DELETE" ? 200 : 304
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let (status, headers, body) = next!
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter MobileSigningCoordinatorTests`
Expected: compile error, `MobileSigningCoordinator` not found.

- [ ] **Step 3: Implement the coordinator**

```swift
import Foundation
import Observation
import AutogramKit

/// Owns one AVM session at a time and the presentation flag of the QR sheet.
@MainActor
@Observable
final class MobileSigningCoordinator {
    var isPresented = false
    private(set) var session: AVMSigningSession?

    private let clientFactory: @MainActor () -> AVMClient
    private let pollInterval: Duration
    private let timeout: Duration

    init(clientFactory: @escaping @MainActor () -> AVMClient,
         pollInterval: Duration = .seconds(1),
         timeout: Duration = .seconds(900)) {
        self.clientFactory = clientFactory
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    convenience init(settingsStore: AppSettingsStore) {
        self.init(clientFactory: { AVMClient(baseURL: settingsStore.settings.avmBaseURLValue) })
    }

    func sign(_ request: AVMUploadRequest) async throws -> AVMSignedDocument {
        if let session, session.isActive { session.cancel() }
        let session = AVMSigningSession(client: clientFactory(), pollInterval: pollInterval, timeout: timeout)
        self.session = session
        isPresented = true
        defer {
            isPresented = false
            self.session = nil
        }
        return try await session.run(request)
    }

    func cancel() {
        session?.cancel()
    }
}
```

- [ ] **Step 4: Implement the sheet**

```swift
import SwiftUI
import AutogramKit

struct MobileSigningSheet: View {
    let session: AVMSigningSession
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Podpísať mobilom")
                .font(.title2.weight(.semibold))

            qrArea
                .frame(width: 260, height: 260)

            Text("Naskenujte QR kód iPhonom a podpíšte dokument v aplikácii Autogram v mobile.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            statusRow

            Button("Zrušiť", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .padding(28)
        .frame(width: 400)
    }

    @ViewBuilder
    private var qrArea: some View {
        if let image = session.qrImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .overlay { ProgressView() }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            switch session.state {
            case .idle, .uploading:
                ProgressView().controlSize(.small)
                Text("Nahrávam dokument na server…")
            case .waitingForScan:
                ProgressView().controlSize(.small)
                if let deadline = session.deadline {
                    Text("Čakám na podpis z mobilu, QR kód platí do \(deadline.formatted(date: .omitted, time: .shortened)).")
                } else {
                    Text("Čakám na podpis z mobilu…")
                }
            case .downloading:
                ProgressView().controlSize(.small)
                Text("Sťahujem podpísaný dokument…")
            case .signed:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Dokument je podpísaný.")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
            case .cancelled:
                Text("Zrušené.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 5: Run tests and build**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter MobileSigningCoordinatorTests && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build`
Expected: 2 tests pass, app builds.

- [ ] **Step 6: Commit**

```bash
git add Autogram/Sources/AutogramApp/MobileSigningCoordinator.swift Autogram/Sources/AutogramApp/Views/MobileSigningSheet.swift Autogram/Tests/AutogramAppTests/MobileSigningCoordinatorTests.swift
git commit -m "feat(avm): mobile signing coordinator and QR sheet" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Mobile branch in SigningSessionStore and SigningPrepareView

**Files:**
- Modify: `Autogram/Sources/AutogramApp/SigningSessionStore.swift` (`sign()` at line 357, signing call at 492-504, `init` at 205)
- Modify: `Autogram/Sources/AutogramApp/Views/SigningFlowViews.swift` (`SigningPrepareView` at 236, sticky bar at 254-267, `signButton` at 691-711)

**Interfaces:**
- Consumes: `MobileSigningCoordinator`, `AVMUploadRequest`, `AVMSignatureLevel`, `AVMResultMapper`.
- Produces: `SigningSessionStore.mobileSigning: MobileSigningCoordinator`, `func sign(viaMobile: Bool = false) async`, `var canSignViaMobile: Bool`, `var isMobileSigningAvailable: Bool`.

- [ ] **Step 1: Add the coordinator and availability to the store**

Near the other stored properties (after `var lastError: String?` at line 42) add:

```swift
    let mobileSigning: MobileSigningCoordinator
    /// Which path the current `sign` run uses; drives the button labels.
    private(set) var isSigningViaMobile = false
```

In `init` (line 205), after `self.settingsStore = settingsStore` (or the equivalent assignment) add:

```swift
        self.mobileSigning = MobileSigningCoordinator(settingsStore: settingsStore)
```

Add computed properties next to `canSign`:

```swift
    var isMobileSigningAvailable: Bool {
        settings.mobileSigningEnabled && !signingProviderIsDemo
    }

    var canSignViaMobile: Bool {
        document != nil && !isSigning && isMobileSigningAvailable
    }
```

- [ ] **Step 2: Branch the signing call**

Change the signature `func sign() async {` to `func sign(viaMobile: Bool = false) async {` and set `isSigningViaMobile = viaMobile` right after `isSigning = true`. Wrap the certificate preload so it only runs for the card path:

```swift
            if !viaMobile, includeVisibleSignature, !signingProviderIsDemo, !hasResolvedCertificate {
```

Replace the identity guard and the `let signed: SignedConversionResult` block (lines 481-504) with:

```swift
            let signed: SignedConversionResult
            if viaMobile {
                statusText = "Čakám na podpis z mobilu…"
                let level: AVMSignatureLevel = outputFormat == .embeddedPAdES
                    ? .pades(timestamp: includeQualifiedTimestamp)
                    : .xades(timestamp: includeQualifiedTimestamp)
                let upload = AVMUploadRequest(filename: pdfName,
                                              data: pdfData,
                                              mimeType: AVMUploadRequest.pdfMimeType,
                                              level: level,
                                              container: outputFormat == .attachedASIC ? .asicE : nil)
                let document = try await mobileSigning.sign(upload)
                signed = try AVMResultMapper.conversionResult(from: document,
                                                              outputFormat: outputFormat,
                                                              uploadedPDF: pdfData)
            } else {
                guard let identityID = selectedIdentityID else {
                    throw SigningError.identityUnavailable
                }
                func makeRequest(with data: Data) -> SigningRequest {
                    SigningRequest(pdfData: data,
                                   identityID: identityID,
                                   includeTimestamp: includeQualifiedTimestamp,
                                   tsaURL: includeQualifiedTimestamp ? selectedTSAURL : nil,
                                   outputFormat: outputFormat,
                                   pin: signingPIN.isEmpty ? nil : signingPIN,
                                   extraFiles: [ASiCEPackager.Entry(path: pdfName, data: data)],
                                   visualStamp: visualStamp)
                }
                do {
                    signed = try await signingProvider.sign(makeRequest(with: pdfData))
                } catch {
                    let text = error.localizedDescription
                    if convertToPDFA, pdfaPrepared,
                       text.contains("SIGNING_UNAVAILABLE") || text.contains("SIGNING_FAILED") {
                        statusText = "PDF/A sa nepodarilo podpísať, skúšam pôvodný dokument…"
                        pdfaPrepared = false
                        signed = try await signingProvider.sign(makeRequest(with: originalPdfData))
                    } else {
                        throw error
                    }
                }
            }
```

The `visualStamp` construction above the block references `identityID`; change those two lookups to use `selectedIdentityID` (`identities.first(where: { $0.id == selectedIdentityID })`) so the stamp compiles for both paths. Keep `let pdfName` where it is.

In the `catch` at the end of `sign()`, map `AVMError.cancelled` to a silent return: before setting `lastError`, add

```swift
            if let avmError = error as? AVMError, avmError == .cancelled {
                statusText = ""
                isSigning = false
                isSigningViaMobile = false
                return
            }
```

and make sure `isSigningViaMobile = false` is reset wherever `isSigning = false` is set at the end of the function.

- [ ] **Step 3: Add the button and the sheet to SigningPrepareView**

In the `StickyActionBar` (line 254) insert `mobileSignButton` before `signButton`:

```swift
                    Spacer()

                    mobileSignButton
                    signButton
```

Add after `signButton`:

```swift
    @ViewBuilder
    private var mobileSignButton: some View {
        if store.isMobileSigningAvailable {
            Button {
                Task { await store.sign(viaMobile: true) }
            } label: {
                HStack(spacing: 8) {
                    if store.isSigning, store.isSigningViaMobile {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    }
                    Text("Podpísať mobilom")
                        .font(.body.weight(.semibold))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!store.canSignViaMobile)
            .help("Podpis občianskym preukazom s NFC cez iPhone a aplikáciu Autogram v mobile")
        }
    }
```

Add the sheet to the outer `HStack` of `SigningPrepareView.body` (after the existing `.task(id:)` modifiers):

```swift
        .sheet(isPresented: Bindable(store.mobileSigning).isPresented) {
            if let session = store.mobileSigning.session {
                MobileSigningSheet(session: session) { store.mobileSigning.cancel() }
                    .interactiveDismissDisabled()
            }
        }
```

`isSigningViaMobile` is `private(set)` in the store; reading it from the view is fine.

- [ ] **Step 4: Build and run existing store tests**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter AutogramAppTests`
Expected: builds; existing app tests still pass.

- [ ] **Step 5: Manual check**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" ./build_app.sh` then open the app, drop a PDF, choose "PAdES podpis v PDF", click "Podpísať mobilom", scan with the iPhone, sign. Expected: the sheet closes on its own, `SigningDoneView` shows the signed file, the file opens in Preview with a valid signature.

- [ ] **Step 6: Commit**

```bash
git add Autogram/Sources/AutogramApp/SigningSessionStore.swift Autogram/Sources/AutogramApp/Views/SigningFlowViews.swift
git commit -m "feat(avm): sign with mobile from the signing flow" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Mobile branch in ZakoSessionStore and AuthorizeView with mandate refusal

**Files:**
- Modify: `Autogram/Sources/AutogramApp/ZakoSessionStore.swift` (`authorizeAndSign()` at 898, identity guard and signing at 985-1045, `init` at 161)
- Modify: `Autogram/Sources/AutogramApp/Views/AuthorizeDoneViews.swift` (sticky bar at 50-61, `authorizeButton` at 259-280)
- Test: `Autogram/Tests/AutogramKitTests/AVMResultMapperTests.swift` (already covers `isMandate`); add a store-level message test only if `ZakoSessionStore` is already unit-tested in `AutogramAppTests` (check with `grep -rn "ZakoSessionStore" Autogram/Tests`); otherwise rely on the manual check.

**Interfaces:**
- Consumes: `MobileSigningCoordinator`, `AVMUploadRequest`, `AVMResultMapper`, `ASiCEPackager.package(files:)`.
- Produces: `ZakoSessionStore.mobileSigning: MobileSigningCoordinator`, `func authorizeAndSign(viaMobile: Bool = false) async`, `var isMobileSigningAvailable: Bool`, `static let mobileMandateRefusalMessage: String`.

- [ ] **Step 1: Add the coordinator and messages**

After `var lastError: String?` (line 87) add:

```swift
    let mobileSigning: MobileSigningCoordinator
    private(set) var isAuthorizingViaMobile = false

    static let mobileMandateRefusalMessage =
        "Podpis z mobilu nebol vytvorený mandátnym certifikátom. Zaručená konverzia vyžaduje mandátny certifikát advokáta, konverzia nebola autorizovaná a do evidencie sa nič nezapísalo."

    var isMobileSigningAvailable: Bool {
        settings.mobileSigningEnabled && !signingProviderIsDemo
    }
```

In `init` (line 161) add `self.mobileSigning = MobileSigningCoordinator(settingsStore: settingsStore)` after the settings store assignment.

- [ ] **Step 2: Branch authorizeAndSign**

Change the signature to `func authorizeAndSign(viaMobile: Bool = false) async` and set `isAuthorizingViaMobile = viaMobile` after `isAuthorizing = true`; reset it in the `defer`.

Wrap the identity resolution, the `guard let identityID`, and the `requiresMandateOverride` check (lines 985-1001) in `if !viaMobile { ... }`. Because `identityID` is then only defined on the card path, restructure the signing call (line 1028) as:

```swift
            let signed: SignedConversionResult
            if viaMobile {
                analysisProgressText = "Čakám na podpis z mobilu…"
                let containerData = try packager.package(files: containerFiles)
                let upload = AVMUploadRequest(filename: ConversionOutputNaming.asicFileName(pdfFileName: docFileName),
                                              data: containerData,
                                              mimeType: AVMUploadRequest.asicEMimeType,
                                              level: .xades(timestamp: includeQualifiedTimestamp))
                let document = try await mobileSigning.sign(upload)
                guard AVMResultMapper.isMandate(signers: document.signers ?? []) else {
                    lastError = Self.mobileMandateRefusalMessage
                    return
                }
                signed = try AVMResultMapper.conversionResult(from: document,
                                                              outputFormat: .attachedASIC,
                                                              uploadedPDF: finalPDF)
            } else {
                guard let identityID = selectedIdentityID else {
                    throw SigningError.identityUnavailable
                }
                signed = try await signingProvider.sign(SigningRequest(
                    pdfData: finalPDF,
                    identityID: identityID,
                    includeTimestamp: includeQualifiedTimestamp,
                    tsaURL: includeQualifiedTimestamp ? settings.selectedTSAURL : nil,
                    pin: signingPIN.isEmpty ? nil : signingPIN,
                    extraFiles: containerFiles))
            }
```

Keep the existing `ASiCEContainerVerifier` check and everything after it unchanged. The `return` on mandate refusal happens before any file is written and before `evidenceStore.upsert`, which satisfies the spec.

In the `catch`, treat `AVMError.cancelled` as a silent return (no `lastError`), mirroring Task 10.

- [ ] **Step 3: Button and sheet in AuthorizeView**

In the `StickyActionBar` (line 50) insert `mobileAuthorizeButton` before `authorizeButton`. Add:

```swift
    @ViewBuilder
    private var mobileAuthorizeButton: some View {
        if store.isMobileSigningAvailable {
            Button {
                Task { await store.authorizeAndSign(viaMobile: true) }
            } label: {
                HStack(spacing: 8) {
                    if store.isAuthorizing, store.isAuthorizingViaMobile {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    }
                    Text("Autorizovať mobilom")
                        .font(.body.weight(.semibold))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(store.isAuthorizing || !store.isPreflightComplete)
            .help("Vyžaduje mandátny certifikát na občianskom preukaze. Bez neho sa konverzia odmietne.")
        }
    }
```

Attach the sheet to the root `VStack` of `AuthorizeView.body`:

```swift
        .sheet(isPresented: Bindable(store.mobileSigning).isPresented) {
            if let session = store.mobileSigning.session {
                MobileSigningSheet(session: session) { store.mobileSigning.cancel() }
                    .interactiveDismissDisabled()
            }
        }
```

`isPreflightComplete` may require a selected identity for the card path; check its definition (`grep -n "isPreflightComplete" ZakoSessionStore.swift`). If it demands `selectedIdentityID != nil`, add a parallel `isMobilePreflightComplete` that skips the identity requirement and use it in the mobile button and inside `authorizeAndSign(viaMobile: true)`.

- [ ] **Step 4: Build and test**

Run: `cd Autogram && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter "AVM|MobileSigning"`
Expected: builds, all AVM tests pass.

- [ ] **Step 5: Manual check**

Run the app, perform a ZaKo conversion up to `AuthorizeView`, click "Autorizovať mobilom", sign with the eID. Expected with a personal certificate: the sheet closes, the red message from `mobileMandateRefusalMessage` appears, no files in the output directory, no new evidence row. Expected with a mandate certificate on the eID: `DoneView` with PDF, XDCF and ASiC-E files and a new evidence row.

- [ ] **Step 6: Commit**

```bash
git add Autogram/Sources/AutogramApp/ZakoSessionStore.swift Autogram/Sources/AutogramApp/Views/AuthorizeDoneViews.swift
git commit -m "feat(avm): authorize conversion with mobile, refuse non-mandate signatures" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Documentation sync

**Files:**
- Modify: `AGENTS.md`, `CLAUDE.md` (identical edits)

- [ ] **Step 1: Add the architecture note**

Under "Architecture & Tech Stack", after the PKCS#11 bullet, add to both files:

```markdown
- Signing with mobile (`Signing/AVM/`): `AVMClient` talks to the Autogram v mobile relay (`https://autogram.slovensko.digital/api/v1`, 32-byte key in `X-Encryption-Key`, `POST /documents`, QR link `/qr-code?guid&key`, polling `GET /documents/{guid}` with `If-Modified-Since`); `AVMSigningSession` drives upload, polling, timeout and cancel; `MobileSigningCoordinator` and `MobileSigningSheet` present the QR code; `SigningSessionStore.sign(viaMobile:)` and `ZakoSessionStore.authorizeAndSign(viaMobile:)` swap only the final signing step; ZaKo refuses a non-mandate signature. `swift run avm-probe <file>` checks the protocol against the real server. The AVM app only opens links for the public host, so a custom server is test-only.
```

Under "Build & Test Instructions" add to both files:

```markdown
- Probe the AVM server end to end: `swift run avm-probe <file.pdf|file.asice> [--level PAdES_BASELINE_T] [--container ASiC-E] [--out <dir>]` (prints the QR link, opens the QR PNG, waits for the phone)
```

- [ ] **Step 2: Verify sync**

Run: `diff AGENTS.md CLAUDE.md && echo in-sync`
Expected: `in-sync`.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md CLAUDE.md
git commit -m "docs: describe signing with Autogram v mobile" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review notes

- Spec coverage: key (T1), models and errors (T2), client with header, 304 and delete (T3), QR (T4), mapper and mandate (T5), session with 1 s polling, 15 min timeout, cancel and delete (T6), probe and real-server checkpoint (T7), settings toggle and base URL (T8), coordinator and sheet with Slovak copy (T9), signing flow button and branch (T10), ZaKo branch with refusal and no evidence write (T11), docs sync (T12). Push and integration registration are deliberately absent.
- Type consistency: `AVMUploadRequest(filename:data:mimeType:level:container:)`, `AVMClient.upload(_:key:)`, `fetchSigned(_:)`, `delete(_:)`, `qrCodeURL(for:)`, `AVMSigningSession.run(_:)`, `MobileSigningCoordinator.sign(_:)` are used with the same names in every task.
- Known judgement points left to the implementer: exact container modifier name in `SettingsView` (T8), whether `isPreflightComplete` needs a mobile variant (T11), and the ZaKo container behaviour of the server (T7 checkpoint decides whether T11 ships as written).
