// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

final class AutogramCLIEngine: SigningEngine, @unchecked Sendable {
    private let runner: CLIProcessRunner
    private let machineSession: MachineSessionProcess
    /// VALIDATE only. The engine handles a session's requests one after another, so a slow
    /// trusted-list validation on the signing session would hold up a v2 signature.
    private let validationSession: MachineSessionProcess
    private let configuration: ProcessConfiguration
    private let driverResolver: DriverResolver
    private let outputService: OutputService
    private let timestampSourceProvider: any TimestampSourceProviding
    private let helperOperationGate = CLIHelperOperationGate()
    private let lock = NSLock()
    private var reservations: [String: OutputReservation] = [:]

    init(
        configuration: ProcessConfiguration = .production,
        runner: CLIProcessRunner = .init(),
        machineSession: MachineSessionProcess = .init(),
        validationSession: MachineSessionProcess = .init(),
        driverResolver: DriverResolver = .init(),
        outputService: OutputService = .init(),
        timestampSourceProvider: any TimestampSourceProviding = TimestampSourcePreferencesStore()
    ) {
        self.configuration = configuration
        self.runner = runner
        self.machineSession = machineSession
        self.validationSession = validationSession
        self.driverResolver = driverResolver
        self.outputService = outputService
        self.timestampSourceProvider = timestampSourceProvider
    }

    func capabilities() async throws -> EngineCapabilities {
        let events = try await run(.capabilities(requestID: UUID().uuidString))
        let payload = try completedPayload(from: events)
        guard let protocolVersion = events.first?.protocolVersion else {
            throw SigningFailure.engine("The signing helper returned no capability response.")
        }
        let signatureLevels = strings(in: payload["signatureLevels"])
        let timestampPolicy = object(in: payload["timestampPolicy"])
        guard signatureLevels.contains("PAdES_BASELINE_T"),
              signatureLevels.contains("XAdES_BASELINE_T"),
              timestampPolicy?["required"] == .bool(true),
              timestampPolicy?["qualified"] == .bool(true) else {
            throw SigningFailure.engine("The signing helper does not require qualified timestamps.")
        }
        return EngineCapabilities(protocolVersion: protocolVersion, supportsQualifiedTimestamp: true)
    }

    func drivers() async throws -> [SigningDriver] {
        let events = try await run(MachineRequest(protocolVersion: 1, requestID: UUID().uuidString, operation: .drivers, payload: [:]))
        return try signingDrivers(in: payload(for: .driverDetected, in: events))
    }

    /// The helper without an arm64 slice is fatal; a driver without one stays listed with
    /// its `unavailableReason`, so the other cards remain usable.
    func signingDrivers(in payload: [String: JSONValue]) throws -> [SigningDriver] {
        try driverResolver.requireNativeHelper(at: configuration.executableURL)
        let candidates = array(in: payload["drivers"]) ?? []
        return candidates.compactMap { candidate in
            guard let id = string(in: candidate["id"]), let name = string(in: candidate["name"]),
                  let path = string(in: candidate["path"]) else { return nil }
            return SigningDriver(
                id: id,
                displayName: name,
                tokenPresent: bool(in: candidate["tokenPresent"]),
                unavailableReason: driverResolver.unavailableReason(driverURL: URL(fileURLWithPath: path),
                                                                    displayName: name)
            )
        }
    }

    func certificates(driverID: String, pin: Secret?) async throws -> [SigningCertificate] {
        try await certificateDiscovery(driverID: driverID, pin: pin).certificates
    }

    func certificateDiscovery(driverID: String, pin: Secret?) async throws -> CertificateDiscovery {
        let request = MachineRequest(
            protocolVersion: 1,
            requestID: UUID().uuidString,
            operation: .certificates,
            payload: ["driver": .string(driverID)]
        )
        let events = try await run(SecureMachineRequest(envelope: request, pin: pin))
        let payload = try payload(for: .certificatesAvailable, in: events)
        guard let tokenKey = string(in: payload["tokenKey"]),
              let providerName = string(in: payload["providerName"]) else {
            throw SigningFailure.engine("The signing helper returned incomplete certificate discovery metadata.")
        }
        let certificates: [SigningCertificate] = (array(in: payload["certificates"]) ?? []).compactMap { certificate in
            guard let serial = string(in: certificate["serial"]),
                  let name = string(in: certificate["commonName"]),
                  let issuer = string(in: certificate["issuer"]),
                  let validFrom = date(in: certificate["validFrom"]),
                  let validUntil = date(in: certificate["validUntil"]),
                  let certificateKey = string(in: certificate["certificateKey"]),
                  let holderKey = string(in: certificate["holderKey"]) else {
                return nil
            }
            return SigningCertificate(
                serialNumber: serial,
                displayName: name,
                issuer: issuer,
                validFrom: validFrom,
                validUntil: validUntil,
                certificateKey: certificateKey,
                holderKey: holderKey,
                certificateQualification: string(in: certificate["qualification"])
            )
        }
        return CertificateDiscovery(
            token: SigningToken(tokenKey: tokenKey, providerName: providerName),
            certificates: certificates
        )
    }

    func inspect(files: [PDFItemDescriptor]) async throws -> [PDFInspection] {
        let machineFiles = files.map { file in
            machineFile(id: file.id, sourceURL: file.sourceURL, targetURL: Self.unusedTarget(for: file.sourceURL))
        }
        let request = MachineRequest(
            protocolVersion: 1,
            requestID: UUID().uuidString,
            operation: .inspect,
            payload: ["files": .array(machineFiles)]
        )
        let events = try await run(request)
        return [PDFInspection(files: files.map { file in
            guard let event = events.last(where: { $0.type == .inspectionCompleted && $0.fileID == file.id }) else {
                return InspectedPDF(id: file.id, isSignable: false)
            }
            return InspectedPDF(
                id: file.id,
                isSignable: true,
                signatures: signatures(in: event.payload["signatures"]),
                documents: documents(in: event.payload["documents"]),
                tree: SignatureTreeDecoder.tree(from: event.payload)
            )
        })]
    }

    func previewEmbeddedDocument(sourceURL: URL, named: String) async throws -> EmbeddedDocumentPreview {
        let requestID = UUID().uuidString
        let request = MachineV2Request(protocolVersion: 2, requestID: requestID, operation: .preview, payload: [
            "source": .string(sourceURL.resolvingSymlinksInPath().path),
            "document": .string(named)
        ])
        let events = try await runV2(SecureMachineV2Request(envelope: request))
        guard let event = events.last(where: { $0.type == .previewCompleted && $0.requestID == requestID }),
              let name = string(in: event.payload["name"]),
              let mediaType = string(in: event.payload["mediaType"]),
              let contentBase64 = string(in: event.payload["contentBase64"]),
              let content = Data(base64Encoded: contentBase64) else {
            throw SigningFailure.engine("The signing helper returned an incomplete embedded document preview.")
        }
        let displayName = URL(fileURLWithPath: name).lastPathComponent
        guard !displayName.isEmpty else {
            throw SigningFailure.engine("The signing helper returned an invalid embedded document name.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Chevron7-EmbeddedPreviews", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: displayName)
            try content.write(to: url, options: .atomic)
            return EmbeddedDocumentPreview(displayName: displayName, mediaType: mediaType, url: url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw SigningFailure.engine("The embedded document preview could not be saved.")
        }
    }

    func validate(files: [PDFItemDescriptor]) async throws -> [PDFInspection] {
        let machineFiles = files.map { file in
            machineFile(id: file.id, sourceURL: file.sourceURL, targetURL: Self.unusedTarget(for: file.sourceURL))
        }
        let requestID = UUID().uuidString
        let request = MachineV2Request(protocolVersion: 2, requestID: requestID, operation: .validate, payload: [
            "files": .array(machineFiles)
        ])
        let events = try await validationSession.send(SecureMachineV2Request(envelope: request),
                                                      configuration: configuration)
        return [PDFInspection(files: files.compactMap { file in
            guard let event = events.last(where: {
                $0.type == .validationCompleted && $0.requestID == requestID && $0.fileID == file.id
            }) else {
                return nil
            }
            return InspectedPDF(
                id: file.id,
                isSignable: true,
                signatures: signatures(in: event.payload["signatures"]),
                documents: documents(in: event.payload["documents"]),
                tree: SignatureTreeDecoder.tree(from: event.payload)
            )
        })]
    }

    /// The helper keeps running a validation the app gave up on and answers the session's
    /// requests one after another, so the timed-out helper is ended and the next validation
    /// starts a fresh one. Other validations still waiting on it fail as cancelled.
    func stopValidation() async {
        await validationSession.stop()
    }

    func sign(request: EngineSigningRequest) -> AsyncThrowingStream<SigningEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let renderedImages = request.files.compactMap(\.visibleAppearance?.renderedPNGURL)
                defer { discardRenderedImages(renderedImages) }
                do {
                    try await helperOperationGate.withPermit {
                        try await withTaskCancellationHandler {
                            let usesMachineV2 = request.eform != nil
                                || request.files.contains(where: { $0.visibleAppearance != nil })
                            // Baseline-B asks for no timestamp, so no TSA needs configuring.
                            let wantsTimestamp = (request.signatureLevelOverride ?? request.outputFormat.signatureLevel)
                                .hasSuffix("_T")
                            let timestamp = try resolvedTimestamp(wantsTimestamp: wantsTimestamp,
                                override: request.timestampServersOverride)
                            if usesMachineV2 {
                                try await signWithMachineV2(request: request, timestamp: timestamp,
                                    continuation: continuation)
                                discardTemporaryOutputs(for: request.files.map(\.id))
                                continuation.finish()
                                return
                            }
                            let files = try request.files.map { file in
                                let reservation = try reservation(
                                    for: file.id,
                                    sourceURL: file.sourceURL,
                                    outputExtension: request.outputFormat.outputExtension(for: file.sourceURL)
                                )
                                do {
                                    try FileManager.default.removeItem(at: reservation.temporaryURL)
                                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                                }
                                return machineFile(id: file.id, sourceURL: file.sourceURL, targetURL: reservation.temporaryURL,
                                    attachmentURLs: file.attachmentURLs)
                            }
                            let levelAndTimestamp = Self.levelAndTimestamp(for: request, endpoints: timestamp.endpoints)
                            let machineRequest = MachineRequest(
                                protocolVersion: 1,
                                requestID: request.sessionID.uuidString,
                                operation: .sign,
                                payload: [
                                    "driver": .string(request.driverID),
                                    "certificateSerial": .string(request.certificateSerial),
                                    "signatureLevel": .string(levelAndTimestamp.level),
                                    "timestamp": levelAndTimestamp.timestamp,
                                    "files": .array(files)
                                ]
                            )
                            let secureRequest = SecureMachineRequest(
                                envelope: machineRequest,
                                pin: request.pin,
                                timestampAuthentication: timestamp.authentication
                            )
                            let stream = await runner.run(request: secureRequest, configuration: configuration)
                            var machineEvents: [MachineEvent] = []
                            var completedFileIDs: [String] = []
                            continuation.yield(.started)
                            for try await event in stream {
                                guard event.sessionID == machineRequest.requestID else {
                                    throw SigningFailure.engine("The signing helper returned an invalid session.")
                                }
                                machineEvents.append(event)
                                switch event.type {
                                case .fileProgress:
                                    guard let phase = string(in: event.payload["phase"]),
                                          let activity = SigningActivityPhase(machinePhase: phase) else {
                                        continue
                                    }
                                    continuation.yield(.activity(activity))
                                case .fileSigningStarted:
                                    if let fileID = event.fileID { continuation.yield(.fileSigning(fileID)) }
                                case .fileCompleted:
                                    guard let fileID = event.fileID else { continue }
                                    completedFileIDs.append(fileID)
                                case .fileFailed:
                                    if let fileID = event.fileID {
                                        let code = string(in: event.payload["code"]) ?? "SIGNING_FAILED"
                                        continuation.yield(.failed(fileID, .engine(Self.fileFailureMessage(code: code))))
                                    }
                                default:
                                    break
                                }
                            }
                            try validateTerminalEvent(in: machineEvents)
                            for fileID in completedFileIDs {
                                do {
                                    let outputURL = try finalizeOutput(for: fileID)
                                    continuation.yield(.completed(fileID, outputURL: outputURL))
                                } catch {
                                    continuation.yield(.failed(fileID, .fileFailed(fileID)))
                                }
                            }
                            // Files the engine failed on were never finalized.
                            discardTemporaryOutputs(for: request.files.map(\.id))
                            continuation.finish()
                        } onCancel: {
                            Task { await self.runner.cancel() }
                        }
                    }
                } catch {
                    discardTemporaryOutputs(for: request.files.map(\.id))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Signature level and timestamp block for both protocol versions. The level a
    /// portal asks for wins over the output format, and only a Baseline T level
    /// requires a timestamp, so a portal's Baseline B carries none.
    static func levelAndTimestamp(for request: EngineSigningRequest,
                                  endpoints: [String]) -> (level: String, timestamp: JSONValue) {
        let level = request.signatureLevelOverride ?? request.outputFormat.signatureLevel
        let wantsTimestamp = level.hasSuffix("_T")
        return (level, .object([
            "required": .bool(wantsTimestamp),
            "servers": .array(wantsTimestamp ? endpoints.map(JSONValue.string) : [])
        ]))
    }

    func cancel() async {
        await runner.cancel()
        await machineSession.stop()
        await validationSession.stop()
    }

    /// Machine protocol v2 signing. Carries the visible PAdES appearance and the
    /// eForm attributes, neither of which protocol v1 can express.
    private func signWithMachineV2(
        request: EngineSigningRequest,
        timestamp: (endpoints: [String], authentication: TimestampAuthenticationSecret?),
        continuation: AsyncThrowingStream<SigningEvent, Error>.Continuation
    ) async throws {
        let hasAppearance = request.files.contains { $0.visibleAppearance != nil }
        guard request.outputFormat != .asiceXAdES || !hasAppearance else {
            throw SigningFailure.engine("Visible appearance requires PAdES Baseline T.")
        }
        let outputExtension = request.eform != nil ? "asice" : "pdf"
        let files = try request.files.map { file -> JSONValue in
            let reservation = try reservation(for: file.id, sourceURL: file.sourceURL,
                outputExtension: outputExtension)
            try? FileManager.default.removeItem(at: reservation.temporaryURL)
            return machineV2File(id: file.id, sourceURL: file.sourceURL, targetURL: reservation.temporaryURL,
                appearance: file.visibleAppearance)
        }
        let requestID = request.sessionID.uuidString
        let levelAndTimestamp = Self.levelAndTimestamp(for: request, endpoints: timestamp.endpoints)
        var signPayload: [String: JSONValue] = [
            "driver": .string(request.driverID),
            "certificateSerial": .string(request.certificateSerial),
            "signatureLevel": .string(levelAndTimestamp.level),
            "timestamp": levelAndTimestamp.timestamp,
            "files": .array(files)
        ]
        if let eform = request.eform {
            signPayload["eform"] = eformPayload(eform)
        }
        let machineRequest = MachineV2Request(protocolVersion: 2, requestID: requestID, operation: .sign,
            payload: signPayload)
        let events = try await runV2(SecureMachineV2Request(envelope: machineRequest, pin: request.pin,
            timestampAuthentication: timestamp.authentication))
        var completedFileIDs: [String] = []
        continuation.yield(.started)
        for event in events {
            guard event.requestID == requestID else {
                throw SigningFailure.engine("The signing helper returned an invalid session.")
            }
            switch event.type {
            case .fileProgress:
                if let phase = string(in: event.payload["phase"]), let activity = SigningActivityPhase(machinePhase: phase) {
                    continuation.yield(.activity(activity))
                }
            case .fileSigningStarted:
                if let fileID = event.fileID { continuation.yield(.fileSigning(fileID)) }
            case .fileCompleted:
                if let fileID = event.fileID { completedFileIDs.append(fileID) }
            case .fileFailed:
                if let fileID = event.fileID {
                    let code = string(in: event.payload["code"]) ?? "SIGNING_FAILED"
                    continuation.yield(.failed(fileID, .engine(Self.fileFailureMessage(code: code))))
                }
            case .requestStarted, .certificatesAvailable, .inspectionCompleted, .previewCompleted,
                    .validationCompleted, .requestCompleted, .requestFailed:
                break
            }
        }
        guard !events.contains(where: { $0.type == .requestFailed }) else {
            let code = events.last(where: { $0.type == .requestFailed }).flatMap { string(in: $0.payload["code"]) }
                ?? "SIGNING_FAILED"
            throw SigningFailure.engine(Self.fileFailureMessage(code: code))
        }
        guard events.contains(where: { $0.type == .requestCompleted }) else {
            throw SigningFailure.engine("The signing helper did not confirm completion.")
        }
        for fileID in completedFileIDs {
            do {
                continuation.yield(.completed(fileID, outputURL: try finalizeOutput(for: fileID)))
            } catch {
                continuation.yield(.failed(fileID, .fileFailed(fileID)))
            }
        }
    }

    private func reservation(
        for fileID: String,
        sourceURL: URL,
        outputExtension: String? = nil
    ) throws -> OutputReservation {
        lock.lock()
        defer { lock.unlock() }
        if let reservation = reservations[fileID] {
            let expectedExtension = outputExtension ?? sourceURL.pathExtension
            if reservation.finalURL.pathExtension.caseInsensitiveCompare(expectedExtension) == .orderedSame {
                return reservation
            }
            outputService.discard(reservation)
            reservations.removeValue(forKey: fileID)
        }
        let reservation = try outputService.reserve(for: sourceURL, outputExtension: outputExtension)
        reservations[fileID] = reservation
        return reservation
    }

    private func finalizeOutput(for fileID: String) throws -> URL {
        lock.lock()
        let reservation = reservations.removeValue(forKey: fileID)
        lock.unlock()
        guard let reservation else { throw OutputServiceError.unableToFinalize }
        do {
            try outputService.finalize(reservation)
        } catch {
            outputService.discard(reservation)
            throw error
        }
        return reservation.finalURL
    }

    private func discardTemporaryOutputs(for fileIDs: [String]) {
        lock.lock()
        let outputReservations = fileIDs.compactMap { reservations.removeValue(forKey: $0) }
        lock.unlock()
        for reservation in outputReservations {
            outputService.discard(reservation)
        }
    }

    /// INSPECT and VALIDATE read only `source`, yet the protocol still requires a
    /// `target`. They get a path inside a folder that is never created, so a
    /// read-only check writes nothing next to the user's document. Reserving a real
    /// output here used to leave a hidden zero-byte `.<name>_signed.pdf.<UUID>.XXXXXX`
    /// beside every inspected document.
    private static func unusedTarget(for sourceURL: URL) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "Chevron7-UnusedTargets", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: sourceURL.lastPathComponent)
    }

    private func run(_ request: MachineRequest) async throws -> [MachineEvent] {
        try await run(SecureMachineRequest(envelope: request))
    }

    private func runV2(_ request: SecureMachineV2Request) async throws -> [MachineV2Event] {
        try await machineSession.send(request, configuration: configuration)
    }

    private func run(_ request: SecureMachineRequest) async throws -> [MachineEvent] {
        try await helperOperationGate.withPermit {
            try await withTaskCancellationHandler {
                let stream = await runner.run(request: request, configuration: configuration)
                var events: [MachineEvent] = []
                for try await event in stream {
                    guard event.sessionID == request.envelope.requestID else {
                        throw SigningFailure.engine("The signing helper returned an invalid session.")
                    }
                    events.append(event)
                }
                try validateTerminalEvent(in: events)
                return events
            } onCancel: {
                Task { await self.runner.cancel() }
            }
        }
    }

    private func validateTerminalEvent(in events: [MachineEvent]) throws {
        if let failure = events.last(where: { $0.type == .sessionFailed }) {
            let code = string(in: failure.payload["code"]) ?? "INTERNAL_ERROR"
            let fallback = string(in: failure.payload["fallbackMessage"])
                ?? "The signing helper rejected the request."
            throw SigningFailure.engine("\(fallback) [\(code)]")
        }
        _ = try completedPayload(from: events)
    }

    private func completedPayload(from events: [MachineEvent]) throws -> [String: JSONValue] {
        guard let event = events.last(where: { $0.type == .sessionCompleted }) else {
            throw SigningFailure.engine("The signing helper did not confirm completion.")
        }
        return event.payload
    }

    private func payload(for type: MachineEventType, in events: [MachineEvent]) throws -> [String: JSONValue] {
        guard let payload = events.last(where: { $0.type == type })?.payload else {
            throw SigningFailure.engine("The signing helper returned an incomplete response.")
        }
        return payload
    }

    // Not private: MachineRequestEncodingTests asserts the encoded shape directly,
    // the same way it already asserts `levelAndTimestamp`.
    func machineFile(id: String, sourceURL: URL, targetURL: URL, attachmentURLs: [URL] = []) -> JSONValue {
        // Java validátor vyžaduje reálny canonical path (realpath, /var → /private/var)
        let source = EnginePaths.canonical(sourceURL).path
        let target = EnginePaths.canonical(targetURL).path
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "source": .string(source),
            "target": .string(target)
        ]
        if !attachmentURLs.isEmpty {
            fields["attachments"] = .array(attachmentURLs.map { .string(EnginePaths.canonical($0).path) })
        }
        return .object(fields)
    }

    /// Encodes eForm attributes for the machine protocol. Schema and transformation
    /// travel base64, matching what the engine's own HTTP server expects.
    private func eformPayload(_ attributes: EFormSigningAttributes) -> JSONValue {
        var fields: [String: JSONValue] = [
            "embedUsedSchemas": .bool(attributes.embedUsedSchemas),
            "autoLoadEform": .bool(attributes.autoLoadEform)
        ]
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields[key] = .string(value)
        }
        func putBase64(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields[key] = .string(Data(value.utf8).base64EncodedString())
        }
        put("containerXmlns", attributes.containerXmlns)
        putBase64("schema", attributes.schema)
        putBase64("transformation", attributes.transformation)
        put("identifier", attributes.identifier)
        put("schemaIdentifier", attributes.schemaIdentifier)
        put("transformationIdentifier", attributes.transformationIdentifier)
        put("transformationLanguage", attributes.transformationLanguage)
        put("transformationMediaDestinationTypeDescription",
            attributes.transformationMediaDestinationTypeDescription)
        put("transformationTargetEnvironment", attributes.transformationTargetEnvironment)
        put("fsFormId", attributes.fsFormID)
        put("packaging", attributes.packaging)
        return .object(fields)
    }

    private func machineV2File(id: String, sourceURL: URL, targetURL: URL,
        appearance: VisibleSignatureRequest?) -> JSONValue {
        var file: [String: JSONValue] = [
            "id": .string(id),
            "source": .string(EnginePaths.canonical(sourceURL).path),
            "target": .string(EnginePaths.canonical(targetURL).path)
        ]
        if let appearance {
            file["visibleAppearance"] = .object([
                "renderedPngPath": .string(EnginePaths.canonical(appearance.renderedPNGURL).path),
                "page": .number(Double(appearance.page)),
                "originX": .number(appearance.originX),
                "originY": .number(appearance.originY),
                "width": .number(appearance.width),
                "height": .number(appearance.height),
                "signingTime": .string(ISO8601DateFormatter().string(from: appearance.signingTime))
            ])
        }
        return .object(file)
    }

    private func discardRenderedImages(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Endpoints and authentication for a Baseline T signature. An explicit override (the
    /// authority chosen in the app, or ZaKo's qualified list) is used exactly as given; it
    /// carries the custom provider's credential only when it names that provider's URL, and
    /// timestamp preferences that are not configured never stop it. Without an override the
    /// engine's own timestamp preferences decide.
    func resolvedTimestamp(wantsTimestamp: Bool, override: [String]?) throws
        -> (endpoints: [String], authentication: TimestampAuthenticationSecret?) {
        guard wantsTimestamp else { return (endpoints: [], authentication: nil) }
        if let override, !override.isEmpty {
            let configuration = timestampSourceProvider.load()
            guard configuration.source == .custom, let provider = configuration.customProvider,
                  override.contains(where: { endpoint in
                      provider.urls.contains {
                          $0.trimmingCharacters(in: .whitespacesAndNewlines)
                              .caseInsensitiveCompare(endpoint) == .orderedSame
                      }
                  }) else {
                return (endpoints: override, authentication: nil)
            }
            return (endpoints: override, authentication: try authentication(for: provider))
        }
        return try qualifiedTimestampRequest()
    }

    private func qualifiedTimestampRequest() throws -> (endpoints: [String], authentication: TimestampAuthenticationSecret?) {
        let configuration = timestampSourceProvider.load()
        let endpoints = configuration.endpoints
        guard !endpoints.isEmpty else {
            throw SigningFailure.engine("Configure at least one custom timestamp URL before signing.")
        }
        guard configuration.source == .custom, let provider = configuration.customProvider else {
            return (endpoints, nil)
        }
        return (endpoints, try authentication(for: provider))
    }

    private func authentication(for provider: CustomTimestampProviderConfiguration) throws
        -> TimestampAuthenticationSecret? {
        let secret: Secret?
        do {
            secret = try timestampSourceProvider.credential(for: provider)
        } catch {
            throw SigningFailure.engine("The custom timestamp credential could not be read from Keychain.")
        }
        switch provider.authentication.kind {
        case .none:
            return nil
        case .basic:
            guard let username = provider.authentication.username?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !username.isEmpty, let secret else {
                throw SigningFailure.engine("Configure custom timestamp Basic authentication before signing.")
            }
            return .basic(username: username, password: secret)
        case .bearer:
            guard let secret else {
                throw SigningFailure.engine("Configure a custom timestamp bearer token before signing.")
            }
            return .bearer(token: secret)
        }
    }

    private static func fileFailureMessage(code: String) -> String {
        switch code {
        case "TIMESTAMP_FAILED":
            "A qualified timestamp could not be obtained. [TIMESTAMP_FAILED]"
        default:
            "Signing failed. [\(code)]"
        }
    }

    private func object(in value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private func array(in value: JSONValue?) -> [[String: JSONValue]]? {
        guard case .array(let values)? = value else { return nil }
        return values.compactMap { object(in: $0) }
    }

    private func strings(in value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { string(in: $0) }
    }

    private func signatures(in value: JSONValue?) -> [ExistingPDFSignature] {
        (array(in: value) ?? []).compactMap { signature in
            guard let id = string(in: signature["id"]) else { return nil }
            let indication = string(in: signature["indication"])
            let validationState: SignatureValidationState
            if indication?.uppercased().contains("INDETERMINATE") == true {
                validationState = .indeterminate
            } else if bool(in: signature["valid"]) == true {
                validationState = .valid
            } else {
                validationState = .invalid
            }
            return ExistingPDFSignature(
                id: id,
                signerDisplayName: string(in: signature["signerDisplayName"]),
                validationState: validationState,
                signingTime: date(in: signature["signingTime"]),
                format: string(in: signature["format"]),
                hasQualifiedTimestamp: bool(in: signature["qualifiedTimestampValid"]) == true,
                subIndication: string(in: signature["subIndication"]),
                validationReason: string(in: signature["validationReason"]),
                documents: strings(in: signature["documents"])
            )
        }
    }

    private func documents(in value: JSONValue?) -> [String] {
        (array(in: value) ?? []).compactMap { string(in: $0["name"]) }
    }

    private func string(in value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private func bool(in value: JSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    private func date(in value: JSONValue?) -> Date? {
        guard let value = string(in: value) else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

private actor CLIHelperOperationGate {
    private var isHeld = false
    private var waitingIDs: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func withPermit<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard isHeld else {
            isHeld = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                waitingIDs.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func release() {
        while !waitingIDs.isEmpty {
            let id = waitingIDs.removeFirst()
            guard let continuation = waiters.removeValue(forKey: id) else { continue }
            continuation.resume()
            return
        }
        isHeld = false
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waitingIDs.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}

private extension ProcessConfiguration {
    static var production: ProcessConfiguration {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["CHEVRON7_CLI_HELPER"],
           !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(Bundle.main.bundleURL.appending(path: "Contents/Helpers/AutogramCLI-arm64").path)
        let executableURL = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: candidates[0])
        return ProcessConfiguration(
            executableURL: executableURL,
            timeout: .seconds(90),
            environment: ProcessConfiguration.signingHelperEnvironment()
        )
    }
}
