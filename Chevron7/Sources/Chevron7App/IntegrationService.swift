import Foundation
import CryptoKit
import Observation
import Chevron7Kit
import Chevron7WebBridge
import Chevron7Integration

/// Owns external requests; neither CLI nor MCP owns a card session or the app's stores.
@Observable
@MainActor
final class IntegrationService {
    private let settings: AppSettingsStore
    private let coordinator: WebSigningCoordinator
    private let history: SignedDocumentStore
    private let reads: IntegrationReadService
    private let signing: @MainActor (WebSignRequest) async throws -> WebSignResponse
    private let engineAvailable: @MainActor () -> Bool
    private let directory: URL
    @ObservationIgnored private var store: IntegrationJobStore?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var owners: [String: String] = [:]
    @ObservationIgnored private var scopes: [String: IntegrationFileScope] = [:]
    @ObservationIgnored private var activeReads = 0
    private var activeJob: String?
    @ObservationIgnored private var sessionScopes: [String: IntegrationFileScope] = [:]
    @ObservationIgnored private var closedSessions = Set<String>()
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    var isBusy: Bool { activeJob != nil }

    init(settingsStore: AppSettingsStore, coordinator: WebSigningCoordinator,
         signedDocuments: SignedDocumentStore, directory: URL? = nil,
         engineAvailable: (@MainActor () -> Bool)? = nil,
         signing: (@MainActor (WebSignRequest) async throws -> WebSignResponse)? = nil) {
        settings = settingsStore
        self.coordinator = coordinator
        history = signedDocuments
        self.engineAvailable = engineAvailable ?? { settingsStore.signingProvider is EngineBridgeSigningProvider }
        self.signing = signing ?? { try await coordinator.handle($0, integration: true) }
        reads = IntegrationReadService(settingsStore: settingsStore)
        self.directory = directory ?? settingsStore.storageRoot.appendingPathComponent("IntegrationJobs", isDirectory: true)
        // Clear stale bytes once at app startup, without launching an engine.
        _ = try? jobs()
        cleanup = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.store?.purgeExpired()
            }
        }
        coordinator.signingDidStart = { [weak self] id in
            guard let self, let owner = self.owners[id] else { return }
            _ = try? self.store?.update(id: id, owner: owner, state: .signing)
        }
    }

    deinit { cleanup?.cancel() }

    func execute(_ data: Data) async -> Data {
        var requestID = "invalid-request"
        let response: IntegrationResponse
        do {
            let request = try IntegrationRequest.decode(data)
            requestID = request.requestId
            let result = try await execute(request)
            response = IntegrationResponse(requestId: requestID, result: result)
        } catch let error as IntegrationError {
            response = IntegrationResponse(requestId: requestID, error: error)
        } catch is CancellationError {
            response = IntegrationResponse(requestId: requestID, error: IntegrationError(code: "CANCELLED", message: "Request cancelled."))
        } catch {
            response = IntegrationResponse(requestId: requestID, error: IntegrationError(code: "SERVICE_FAILED", message: error.localizedDescription))
        }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }

    func execute(_ request: IntegrationRequest) async throws -> JSONValue {
        try Task.checkCancellation()
        try request.validate()
        try validateArguments(request)
        store?.purgeExpired()
        for (id, owner) in owners where tasks[id] == nil {
            if (try? store?.get(id: id, owner: owner)) == nil { owners[id] = nil; scopes[id] = nil }
        }
        let args = request.arguments
        guard !closedSessions.contains(request.session) else { throw failure("SESSION_CLOSED", "This integration session has ended.") }
        let scope = try ["inspect", "validate", "sign"].contains(request.method)
            ? fileScope(args, session: request.session) : IntegrationFileScope()
        switch request.method {
        case "status":
            let engine = engineAvailable()
            return .object([
                "apiVersion": .number(1), "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"),
                "ready": .bool(engine), "engineAvailable": .bool(engine), "busy": .bool(isBusy || coordinator.pending != nil || coordinator.otherSigningIsBusy()),
                "formats": .array([.string("pades"), .string("asice")]), "levels": .array([.string("B"), .string("T")]),
                "confirmationRequired": .bool(true), "maximumInputBytes": .number(Double(IntegrationLimits.maximumInputBytes)),
                "maximumOutputBytes": .number(Double(IntegrationLimits.maximumOutputBytes)),
                "maximumRequestBytes": .number(Double(IntegrationLimits.maximumRequestBytes)),
                "maximumJobs": .number(Double(IntegrationLimits.maximumJobs)),
                "maximumRetainedBytes": .number(Double(IntegrationLimits.maximumRetainedBytes)),
                "jobLifetimeSeconds": .number(IntegrationLimits.jobLifetime),
                "registerAccess": .bool(args["allowRegister"]?.bool == true), "ezzkAccess": .bool(args["allowEzzk"]?.bool == true)
            ])
        case "inspect", "validate":
            guard activeReads < 4 else { throw failure("BUSY", "Too many document checks are in progress.") }
            activeReads += 1
            defer { activeReads -= 1 }
            guard !coordinator.isWorking, !coordinator.otherSigningIsBusy() else { throw failure("BUSY", "The signing engine is currently handling a signature.") }
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let snapshot = try scope.snapshot(path: required("file", args), in: folder)
            guard ["pdf", "asice", "sce", "asics", "scs"].contains(URL(fileURLWithPath: snapshot.name).pathExtension.lowercased()) else {
                throw failure("UNSUPPORTED_FORMAT", "Inspect and validate accept PDF or ASiC files.")
            }
            var arguments = args
            arguments["file"] = .string(snapshot.url.path)
            var result = try await reads.execute(method: request.method, arguments: arguments).object ?? [:]
            result["input"] = snapshot.json
            return .object(result)
        case "register.list", "register.get":
            guard args["allowRegister"]?.bool == true else { throw failure("ACCESS_DENIED", "Account-wide register access requires --allow-register.") }
            return try await reads.execute(method: request.method, arguments: args)
        case "ezzk.lookup":
            guard args["allowEzzk"]?.bool == true else { throw failure("ACCESS_DENIED", "Account-wide EZZK lookup requires --allow-ezzk.") }
            return try await reads.execute(method: request.method, arguments: args)
        case "sign": return try begin(request, scope: scope)
        case "jobs.get": return try jobs().get(id: required("jobId", args), owner: request.session).json
        case "jobs.cancel":
            let id = try required("jobId", args)
            let job = try jobs().get(id: id, owner: request.session)
            guard !job.state.isTerminal else { return job.json }
            let mayHaveSigned = job.state == .signing
                || (coordinator.pending?.request.requestID == id && coordinator.isWorking)
            if activeJob == id, coordinator.pending?.request.requestID == id { coordinator.cancel() }
            tasks[id]?.cancel()
            return try jobs().update(id: id, owner: request.session, state: mayHaveSigned ? .outcomeUnknown : .cancelled,
                error: failure(mayHaveSigned ? "OUTCOME_UNKNOWN" : "USER_CANCELLED",
                    mayHaveSigned ? "Cancellation requested during signing. A signature may already exist; do not automatically sign again." : "The signing request was cancelled before signing.")).json
        case "jobs.save": return try save(request)
        case "session.close":
            guard closedSessions.count < 1024 else { throw failure("CAPACITY_EXCEEDED", "Session capacity reached. Restart Chevron7.") }
            closedSessions.insert(request.session)
            for (id, owner) in owners where owner == request.session {
                if activeJob == id, coordinator.pending?.request.requestID == id { coordinator.cancel() }
                tasks[id]?.cancel()
            }
            _ = try jobs().closeSession(owner: request.session)
            return .object(["closed": .bool(true)])
        default: throw failure("UNSUPPORTED_METHOD", "Unsupported operation.")
        }
    }

    private func begin(_ request: IntegrationRequest, scope: IntegrationFileScope) throws -> JSONValue {
        guard engineAvailable() else { throw failure("ENGINE_UNAVAILABLE", "The bundled signing engine is unavailable.") }
        let args = request.arguments
        let format = args["format"]?.string ?? "pades"
        let level = args["level"]?.string ?? "B"
        guard ["pades", "asice"].contains(format), ["B", "T"].contains(level) else { throw failure("UNSUPPORTED_FORMAT", "Supported formats: pades/asice; levels: B/T.") }
        let source = try required("file", args)
        let output = try required("output", args)
        let paths: [String]
        if let attachments = args["attachments"] {
            guard let array = attachments.array, array.allSatisfy({ $0.string != nil }), array.count <= 32 else {
                throw failure("INVALID_ARGUMENTS", "attachments must contain at most 32 local paths.")
            }
            paths = array.compactMap(\.string)
        } else { paths = [] }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var snapshots = [try scope.snapshot(path: source, in: folder)]
        var remaining = IntegrationLimits.maximumInputBytes - snapshots[0].byteCount
        for path in paths {
            let snapshot = try scope.snapshot(path: path, in: folder, maxBytes: remaining)
            snapshots.append(snapshot)
            remaining -= snapshot.byteCount
        }
        let main = snapshots[0]
        let ext = URL(fileURLWithPath: main.name).pathExtension.lowercased()
        guard ext == "pdf" || (ext == "xdcf" && format == "asice" && paths.isEmpty), paths.isEmpty || (ext == "pdf" && format == "asice") else {
            throw failure("UNSUPPORTED_FORMAT", "Sign accepts a PDF, PDF with ASiC-E attachments, or one finished XDCF as ASiC-E.")
        }
        let bytes = try IntegrationFileScope().read(path: main.url.path)
        if ext == "pdf", !bytes.starts(with: Data("%PDF-".utf8)) { throw failure("UNSUPPORTED_FORMAT", "The input is not a PDF.") }
        let attributes: EFormSigningAttributes? = ext == "xdcf" ? EFormSigningAttributes(embedUsedSchemas: true, packaging: "ENVELOPING") : nil
        let mime = ext == "xdcf" ? "application/vnd.gov.sk.xmldatacontainer+xml;base64" : "application/pdf;base64"
        let attachments = try snapshots.dropFirst().map { snapshot in
            WebSignAttachment(filename: snapshot.name, content: try IntegrationFileScope().read(path: snapshot.url.path).base64EncodedString(), payloadMimeType: "application/octet-stream;base64")
        }
        var fingerprintArguments = args
        fingerprintArguments.removeValue(forKey: "requestKey")
        fingerprintArguments["inputs"] = .array(snapshots.map(\.json))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let fingerprint = SHA256.hash(data: try encoder.encode(fingerprintArguments)).map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        let store = try jobs()
        // Idempotency is checked before output reservation and busy rejection.
        let begun = try store.begin(owner: request.session, key: args["requestKey"]?.string,
                                    fingerprint: fingerprint, reservedBytes: IntegrationLimits.maximumOutputBytes + IntegrationLimits.maximumInputBytes)
        if !begun.isNew { return begun.job.json }
        let id = begun.job.id
        do {
            guard activeJob == nil, coordinator.pending == nil, !coordinator.isWorking, !coordinator.otherSigningIsBusy() else { throw failure("BUSY", "Chevron7 is already handling another signing request.") }
            let reservation = try scope.reserveOutput(path: output)
            let webRequest = WebSignRequest(requestID: id, filename: main.name, content: bytes.base64EncodedString(),
                                            payloadMimeType: mime, signatureLevel: "\(format == "pades" ? "PAdES" : "XAdES")_BASELINE_\(level)",
                                            container: format == "asice" ? "ASiC-E" : nil, eform: attributes,
                                            attachments: attachments.isEmpty ? nil : attachments)
            guard try JSONEncoder().encode(webRequest).count <= IntegrationLimits.maximumRequestBytes else { reservation.discard(); throw failure("PAYLOAD_TOO_LARGE", "Encoded signing request exceeds 32 MiB.") }
            try Task.checkCancellation()
            activeJob = id
            owners[id] = request.session
            scopes[id] = scope
            let inputValues = snapshots.map(\.json)
            tasks[id] = Task { [weak self] in
                guard let self else { reservation.discard(); return }
                defer { self.activeJob = nil; self.tasks[id] = nil; reservation.discard() }
                var signatureCreated = false
                do {
                    try Task.checkCancellation()
                    let response = try await self.signing(webRequest)
                    signatureCreated = true
                    try Task.checkCancellation()
                    guard let payload = Data(base64Encoded: response.content), payload.count <= IntegrationLimits.maximumOutputBytes else {
                        throw self.failure("PAYLOAD_TOO_LARGE", "Signed output exceeds the supported limit.")
                    }
                    let retained = try store.directory(for: id, owner: request.session).appendingPathComponent("signed-output")
                    try payload.write(to: retained, options: [.atomic])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: retained.path)
                    var result: [String: JSONValue] = ["jobId": .string(id), "format": .string(format),
                        "signatureLevel": .string(response.signatureLevel ?? webRequest.signatureLevel), "signedBy": .string(response.signedBy),
                        "issuedBy": .string(response.issuedBy), "method": .string(response.method ?? "card"),
                        "inputs": .array(inputValues), "validation": .string("notValidated"), "signed": .bool(true)]
                    do {
                        try reservation.write(payload)
                        let delivered = try reservation.publish()
                        result["output"] = delivered.json
                        _ = try store.update(id: id, owner: request.session, state: .completed, result: .object(result))
                        self.history.record(displayName: main.name, origin: .integration,
                            method: response.method == "mobile" ? .mobile : .card,
                            signatureLevel: response.signatureLevel ?? webRequest.signatureLevel, signedBy: response.signedBy, url: delivered.url)
                    } catch {
                        _ = try store.update(id: id, owner: request.session, state: .failed, result: .object(result),
                            error: self.failure("OUTPUT_DELIVERY_FAILED", "Signature created but output could not be saved. Use jobs save with this job ID; do not sign again."))
                    }
                } catch {
                    let cancelled = error is CancellationError || (error as? WebSigningCoordinator.Failure).map { if case .cancelled = $0 { true } else { false } } == true
                    // Closing the native panel after the engine started is as
                    // uncertain as jobs.cancel: the card may already have signed
                    // before cancellation suppressed its reply.
                    let cancelledDuringSigning = cancelled && (try? store.get(id: id, owner: request.session).state) == .signing
                    if signatureCreated || cancelledDuringSigning {
                        _ = try? store.update(id: id, owner: request.session, state: .outcomeUnknown,
                            error: self.failure("OUTCOME_UNKNOWN", signatureCreated
                                ? "The signature completed but its output could not be retained. Do not automatically sign again."
                                : "Signing was cancelled after execution started. A signature may already exist; do not automatically sign again."))
                    } else {
                        _ = try? store.update(id: id, owner: request.session, state: cancelled ? .cancelled : .failed,
                            error: (error as? IntegrationError) ?? self.failure(cancelled ? "USER_CANCELLED" : "SIGNING_FAILED", error.localizedDescription))
                    }
                }
            }
            return begun.job.json
        } catch {
            try? store.remove(id: id, owner: request.session)
            throw error
        }
    }

    private func save(_ request: IntegrationRequest) throws -> JSONValue {
        let id = try required("jobId", request.arguments)
        let store = try jobs()
        let job = try store.get(id: id, owner: request.session)
        guard job.result?["signed"]?.bool == true, let scope = scopes[id] else { throw failure("JOB_UNKNOWN", "No retained signed output is available for this job.") }
        let reservation = try scope.reserveOutput(path: required("output", request.arguments))
        defer { reservation.discard() }
        let retained = try store.directory(for: id, owner: request.session).appendingPathComponent("signed-output")
        try reservation.write(IntegrationFileScope().read(path: retained.path, maxBytes: IntegrationLimits.maximumOutputBytes))
        let output = try reservation.publish()
        var result = job.result?.object ?? [:]
        result["output"] = output.json
        return try store.recordDelivery(id: id, owner: request.session, result: .object(result)).json
    }

    private func jobs() throws -> IntegrationJobStore {
        if let store { return store }
        let created = try IntegrationJobStore(directory: directory)
        store = created
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if url.lastPathComponent.hasPrefix("request-"), UUID(uuidString: String(url.lastPathComponent.dropFirst(8))) != nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return created
    }

    private func temporaryDirectory() throws -> URL {
        _ = try jobs()
        let folder = directory.appendingPathComponent("request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    private func fileScope(_ arguments: [String: JSONValue], session: String) throws -> IntegrationFileScope {
        if let existing = sessionScopes[session] {
            if arguments["roots"] == nil { return existing }
            let supplied = arguments["roots"]?.array?.compactMap(\.string)
            guard supplied == existing.roots?.map(\.path) else { throw failure("ACCESS_DENIED", "Session roots cannot change. Start a new session for another client.") }
            return existing
        }
        guard sessionScopes.count < 1024 else { throw failure("CAPACITY_EXCEEDED", "Too many integration sessions. Restart the application.") }
        guard let value = arguments["roots"] else {
            let scope = try IntegrationFileScope()
            sessionScopes[session] = scope
            return scope
        }
        guard let values = value.array, values.allSatisfy({ $0.string?.hasPrefix("/") == true }), !values.isEmpty else {
            throw failure("SCOPE_REQUIRED", "At least one absolute permitted root is required.")
        }
        let scope = try IntegrationFileScope(roots: values.compactMap(\.string).map { URL(fileURLWithPath: $0, isDirectory: true) })
        sessionScopes[session] = scope
        return scope
    }

    private func required(_ key: String, _ arguments: [String: JSONValue]) throws -> String {
        guard let value = arguments[key]?.string, !value.isEmpty else { throw failure("INVALID_ARGUMENTS", "Missing or invalid \(key).") }
        return value
    }

    private func validateArguments(_ request: IntegrationRequest) throws {
        let common: Set<String> = ["roots", "allowRegister", "allowEzzk"]
        let fields: [String: Set<String>] = ["status": [], "inspect": ["file"], "validate": ["file"],
            "sign": ["file", "output", "format", "level", "attachments", "requestKey"],
            "jobs.get": ["jobId"], "jobs.cancel": ["jobId"], "jobs.save": ["jobId", "output"],
            "register.list": ["limit", "cursor"], "register.get": ["recordId"], "ezzk.lookup": ["recordId"], "session.close": []]
        guard Set(request.arguments.keys).isSubset(of: common.union(fields[request.method] ?? [])) else {
            throw failure("INVALID_ARGUMENTS", "Unknown argument for \(request.method).")
        }
        for key in ["file", "output", "format", "level", "requestKey", "jobId", "recordId", "cursor"] where request.arguments[key] != nil {
            guard let value = request.arguments[key]?.string, !value.isEmpty, !value.utf8.contains(0), value.utf8.count <= 4096 else {
                throw failure("INVALID_ARGUMENTS", "\(key) must be a nonempty string of at most 4096 bytes.")
            }
            if ["file", "output"].contains(key), !value.hasPrefix("/") { throw failure("INVALID_ARGUMENTS", "\(key) must be an absolute path.") }
        }
        for key in ["allowRegister", "allowEzzk"] where request.arguments[key] != nil {
            guard request.arguments[key]?.bool != nil else { throw failure("INVALID_ARGUMENTS", "\(key) must be boolean.") }
        }
    }
    private func failure(_ code: String, _ message: String) -> IntegrationError { IntegrationError(code: code, message: message) }
}
