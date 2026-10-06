// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import Foundation

/// Client for the Autogram Portal bundle API (`POST/GET api/v1/bundles`,
/// `GET api/v1/contracts/:id/signed_document`) plus the unauthenticated
/// eIdentita session page the phone's QR code comes from.
///
/// Flow: create bundle -> read contract id from bundle show -> GET the
/// eIdentita session page and parse the `sk.minv.sca://` href -> poll
/// `signed_document` until a version newer than the session appears.
/// The portal owns `sourceUrl`/`destinationUrl`; a localhost linkUrl could
/// never be fetched by the phone, so this feature cannot work offline.
public struct AGPClient: Sendable {
    /// Production portal. Override (e.g. staging) in settings and tests.
    public static let productionBaseURL = URL(string: "https://agp.slovensko.digital")!
    public static let stagingBaseURL = URL(string: "https://agp.dev.slovensko.digital")!

    public let baseURL: URL
    public let minter: AGPTokenMinter
    private let transport: any AVMHTTPTransport

    public init(baseURL: URL = AGPClient.productionBaseURL,
                minter: AGPTokenMinter,
                transport: any AVMHTTPTransport = URLSessionAVMTransport()) {
        self.baseURL = baseURL
        self.minter = minter
        self.transport = transport
    }
    /// Client from settings pieces: portal URL, organization (tenant) id and the Keychain key.
    /// Missing pieces are a settings error (`.missingToken`), not a transport one.
    public static func configured(userID: String, baseURL: URL,
                                  keyStore: any AGPKeyStoring,
                                  transport: any AVMHTTPTransport = URLSessionAVMTransport()) throws -> AGPClient {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AGPError.missingToken }
        let minter = AGPTokenMinter(userID: trimmed) {
            guard let raw = try keyStore.loadPrivateKey(),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) else {
                throw AGPError.missingToken
            }
            return key
        }
        return AGPClient(baseURL: baseURL, minter: minter, transport: transport)
    }

    // MARK: - Bundle API (authenticated)

    /// Creates a one-document `qes` bundle. Returns the bundle UUID.
    /// `data` is always sent base64: the `;base64` suffix is appended to
    /// `mimeType` here, because the portal base64-decodes `content` only then.
    /// Without it the portal would store the base64 text as the file.
    public func createBundle(filename: String, data: Data, mimeType: String,
                             format: AGPSignatureFormat,
                             level: AGPSignatureLevel) async throws -> String {
        let resolvedMimeType = mimeType.contains("base64") ? mimeType : mimeType + ";base64"
        let body: [String: Any] = [
            "contracts": [[
                "allowedMethods": ["qes"],
                "documents": [[
                    "filename": filename,
                    "content": data.base64EncodedString(),
                    "contentType": resolvedMimeType,
                ]],
                // No `container`: the portal sets `ASiC_E` itself for XAdES/CAdES
                // and rejects any container on PAdES.
                "signatureParameters": ["format": format.rawValue, "level": level.rawValue],
            ]]
        ]
        var http = URLRequest(url: baseURL.appendingPathComponent("api/v1/bundles"))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        try authorize(&http)
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (payload, response) = try await send(http)
        guard response.statusCode == 201 else { throw Self.serverError(status: response.statusCode, body: payload) }
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            throw AGPError.invalidResponse
        }
        return id
    }

    /// Reads the first contract UUID of a bundle. Bundle show embeds
    /// `contracts[].signed_document` unless the contract still awaits a signature.
    public func contractID(bundleID: String) async throws -> String {
        let show = try await bundleShow(bundleID: bundleID)
        guard let id = show.contracts.first?.id, !id.isEmpty else { throw AGPError.invalidResponse }
        return id
    }

    /// `signed_at` of the currently stored signed version, if any. Snapshot
    /// this before opening the eIdentita session: an already-signed upload
    /// completes the bundle before the phone answers, and only a newer
    /// version counts as the phone's signature.
    public func baselineSignedAt(contractID: String) async throws -> String? {
        try await bundleShow(bundleID: nil, contractID: contractID).contracts.first?.signedDocument?.signedAt
    }

    /// The signed file once a version newer than `baselineSignedAt` exists,
    /// otherwise `.pending`. Never returns the unsigned upload: `show` omits
    /// `signed_document` while the contract awaits a signature.
    public func fetchSigned(contractID: String, baselineSignedAt: String?) async throws -> AGPPollResult {
        let (payload, response) = try await get(path: "api/v1/contracts/\(contractID)/signed_document")
        switch response.statusCode {
        case 404:
            return .pending
        case 200:
            break
        default:
            throw Self.serverError(status: response.statusCode, body: payload)
        }
        let info: AGPSignedDocumentInfo
        do {
            info = try JSONDecoder().decode(AGPSignedDocumentInfo.self, from: payload)
        } catch {
            throw AGPError.invalidResponse
        }
        if let baseline = baselineSignedAt {
            guard let signedAt = info.signedAt, signedAt > baseline else { return .pending }
        }
        guard let fileURL = URL(string: info.downloadURL), fileURL.scheme != nil else {
            throw AGPError.invalidResponse
        }
        var http = URLRequest(url: fileURL)
        http.httpMethod = "GET"
        http.cachePolicy = .reloadIgnoringLocalCacheData
        let (fileData, fileResponse) = try await send(http)
        guard (200..<300).contains(fileResponse.statusCode) else {
            throw Self.serverError(status: fileResponse.statusCode, body: fileData)
        }
        return .signed(AGPSignedFile(data: fileData, filename: info.filename,
                                     contentType: info.contentType, signedAt: info.signedAt))
    }

    /// Best-effort cleanup of an unused bundle (cancelled or failed run).
    /// A completed bundle is kept: it is the user's portal history.
    public func deleteBundle(bundleID: String) async throws {
        var http = URLRequest(url: baseURL.appendingPathComponent("api/v1/bundles/\(bundleID)"))
        http.httpMethod = "DELETE"
        try authorize(&http)
        let (payload, response) = try await send(http)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
            throw Self.serverError(status: response.statusCode, body: payload)
        }
    }

    // MARK: - Token check (authenticated)

    /// `true` when the portal accepts the token. The token is saved only after this passes.
    public func verifyToken() async throws -> Bool {
        let (payload, response) = try await get(path: "api/v1/hello_auth")
        switch response.statusCode {
        case 200:
            return true
        case 401, 403:
            throw AGPError.unauthorized
        default:
            throw Self.serverError(status: response.statusCode, body: payload)
        }
    }

    // MARK: - eIdentita session page (no auth)

    /// Raw HTML of the eIdentita session page. `sessions#create` needs no
    /// login: with no recipient the portal signs an anonymous signer in.
    /// The caller parses the `sk.minv.sca://` href out of it.
    public func eidentitaPage(contractID: String) async throws -> String {
        var http = URLRequest(url: baseURL.appendingPathComponent("contracts/\(contractID)/sessions/eidentita"))
        http.httpMethod = "GET"
        http.setValue("text/html", forHTTPHeaderField: "Accept")
        let (payload, response) = try await send(http)
        guard (200..<300).contains(response.statusCode),
              let html = String(data: payload, encoding: .utf8) else {
            throw Self.serverError(status: response.statusCode, body: payload)
        }
        return html
    }

    // MARK: - Private

    private struct AGPBundleShow: Decodable {
        var contracts: [AGPContract]
    }

    private struct AGPContract: Decodable {
        var id: String
        var signedDocument: AGPSignedDocumentInfo?
        enum CodingKeys: String, CodingKey {
            case id
            case signedDocument = "signed_document"
        }
    }

    private func bundleShow(bundleID: String? = nil, contractID: String? = nil) async throws -> AGPBundleShow {
        let path: String
        if let bundleID {
            path = "api/v1/bundles/\(bundleID)"
        } else {
            path = "api/v1/contracts/\(contractID ?? "")"
        }
        let (payload, response) = try await get(path: path)
        guard response.statusCode == 200 else {
            throw Self.serverError(status: response.statusCode, body: payload)
        }
        // Contract show is a single object, bundle show wraps it in `contracts`.
        if bundleID == nil,
           let contract = try? JSONDecoder().decode(AGPContract.self, from: payload) {
            return AGPBundleShow(contracts: [contract])
        }
        guard let show = try? JSONDecoder().decode(AGPBundleShow.self, from: payload) else {
            throw AGPError.invalidResponse
        }
        return show
    }

    private func get(path: String) async throws -> (Data, HTTPURLResponse) {
        var http = URLRequest(url: baseURL.appendingPathComponent(path))
        http.httpMethod = "GET"
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.cachePolicy = .reloadIgnoringLocalCacheData
        try authorize(&http)
        return try await send(http)
    }

    // Fresh token per request: `jti` must stay unique and `exp` short-lived.
    // The `Token` scheme is what the portal's Rails parser reads; `Bearer` would not match it.
    private func authorize(_ http: inout URLRequest) throws {
        http.setValue("Token token=\"\(try minter.mint())\"", forHTTPHeaderField: "Authorization")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as AGPError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AGPError.transport(error.localizedDescription)
        }
    }

    static func serverError(status: Int, body: Data) -> AGPError {
        let parsed = try? JSONDecoder().decode(AGPServerErrorBody.self, from: body)
        if status == 401 || status == 403 {
            return .unauthorized
        }
        return .server(status: status, code: parsed?.code, message: parsed?.message)
    }
}

/// Portal signature form. The portal sets `ASiC_E` itself for XAdES/CAdES and
/// rejects any container on PAdES, so no container is ever sent.
public enum AGPSignatureFormat: String, Sendable {
    case xades = "XAdES"
    case cades = "CAdES"
    case pades = "PAdES"
}
public enum AGPSignatureLevel: String, Sendable {
    case baselineB = "BASELINE_B"
    case baselineT = "BASELINE_T"
}

public struct AGPSignedDocumentInfo: Decodable, Sendable, Equatable {
    public var downloadURL: String
    public var contentType: String?
    public var filename: String?
    public var signedAt: String?

    enum CodingKeys: String, CodingKey {
        case downloadURL = "download_url"
        case contentType = "content_type"
        case filename
        case signedAt = "signed_at"
    }
}

/// Raw bytes of the phone-signed file plus what `show` reported about it.
public struct AGPSignedFile: Sendable, Equatable {
    public var data: Data
    public var filename: String?
    public var contentType: String?
    public var signedAt: String?

    public init(data: Data, filename: String?, contentType: String?, signedAt: String?) {
        self.data = data
        self.filename = filename
        self.contentType = contentType
        self.signedAt = signedAt
    }
}

public enum AGPPollResult: Sendable, Equatable {
    case pending
    case signed(AGPSignedFile)
}

struct AGPServerErrorBody: Decodable {
    var code: String?
    var message: String?
}

public enum AGPError: Error, Equatable, LocalizedError {
    case server(status: Int, code: String?, message: String?)
    case invalidResponse
    case missingToken
    case timeout
    case cancelled
    case transport(String)
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .server(let status, let code, let message):
            let detail = [code, message].compactMap { $0 }.joined(separator: ": ")
            return detail.isEmpty
                ? "Portál Autogram odpovedal chybou \(status)."
                : "Portál Autogram odpovedal chybou \(status) (\(detail))."
        case .invalidResponse:
            return "Portál Autogram vrátil neočakávanú odpoveď."
        case .missingToken:
            return "Chýba kľúč alebo ID organizácie na portáli Autogram. Nastavte ich v Nastaveniach."
        case .timeout:
            return "Podpis z mobilu neprišiel včas."
        case .cancelled:
            return "Podpisovanie mobilom bolo zrušené."
        case .transport(let detail):
            return "Portál Autogram je nedostupný (\(detail))."
        case .unauthorized:
            return "Portál podpis odmietol. Skontrolujte kľúč a ID organizácie v Nastaveniach a či má organizácia na portáli zapnutý API prístup."
        }
    }
}
