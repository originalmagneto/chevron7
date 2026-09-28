// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import CoreGraphics
import Observation

/// One document, one portal QR code, one phone signature. Same state shape as
/// `AVMSigningSession` so the QR sheet stays identical; only the backend
/// differs (Autogram Portal bundle instead of the AVM relay).
@MainActor
@Observable
public final class EidentitaSigningSession {
    public enum State: Equatable {
        case idle
        case uploading
        case waitingForScan(qrURL: URL)
        case signed(AGPSignedFile)
        case failed(String)
        case cancelled
    }

    public private(set) var state: State = .idle
    public private(set) var qrImage: CGImage?
    public private(set) var deadline: Date?

    private let client: AGPClient
    private let pollInterval: Duration
    private let timeout: Duration
    private let qrSide: Int
    private var runTask: Task<AGPSignedFile, Error>?

    public init(client: AGPClient,
                pollInterval: Duration = .seconds(10),
                timeout: Duration = .seconds(600),
                qrSide: Int = 512) {
        self.client = client
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.qrSide = qrSide
    }

    public var isActive: Bool {
        switch state {
        case .uploading, .waitingForScan: return true
        case .idle, .signed, .failed, .cancelled: return false
        }
    }

    public func run(_ request: AGPSigningRequest) async throws -> AGPSignedFile {
        let task = Task<AGPSignedFile, Error> { [weak self] in
            guard let self else { throw AGPError.cancelled }
            return try await self.execute(request)
        }
        runTask = task
        defer { runTask = nil }
        return try await task.value
    }

    public func cancel() {
        runTask?.cancel()
    }

    private func execute(_ request: AGPSigningRequest) async throws -> AGPSignedFile {
        state = .uploading
        qrImage = nil
        deadline = nil
        var bundleID: String?
        do {
            bundleID = try await client.createBundle(filename: request.filename,
                                                     data: request.data,
                                                     mimeType: request.mimeType,
                                                     format: request.format,
                                                     level: request.level)
            try Task.checkCancellation()
            let contractID = try await client.contractID(bundleID: bundleID!)
            // Snapshot before the phone can answer: an already-signed upload
            // completes the bundle on its own and must not end the wait.
            let baseline = try await client.baselineSignedAt(contractID: contractID)
            try Task.checkCancellation()

            let html = try await client.eidentitaPage(contractID: contractID)
            guard let qrURL = EidentitaQR.url(fromHTML: html) else {
                throw AGPError.invalidResponse
            }
            try Task.checkCancellation()

            qrImage = QRCodeRenderer.image(for: qrURL.absoluteString, side: qrSide)
            let start = ContinuousClock.now
            deadline = Date().addingTimeInterval(Self.seconds(timeout))
            state = .waitingForScan(qrURL: qrURL)

            while true {
                try Task.checkCancellation()
                if ContinuousClock.now - start >= timeout { throw AGPError.timeout }
                switch try await client.fetchSigned(contractID: contractID, baselineSignedAt: baseline) {
                case .pending:
                    try await Task.sleep(for: pollInterval)
                case .signed(let file):
                    // The portal asynchronously copies an already-signed upload
                    // into `signed_document`. Bytes identical to the upload are
                    // that echo, not the phone's signature: keep waiting.
                    if file.data == request.data {
                        try await Task.sleep(for: pollInterval)
                        continue
                    }
                    state = .signed(file)
                    return file
                }
            }
        } catch is CancellationError {
            state = .cancelled
            await cleanup(bundleID: bundleID)
            throw AGPError.cancelled
        } catch let error as AGPError {
            if error == .cancelled {
                state = .cancelled
            } else {
                state = .failed(error.localizedDescription)
            }
            await cleanup(bundleID: bundleID)
            throw error
        } catch {
            state = .failed(error.localizedDescription)
            await cleanup(bundleID: bundleID)
            throw error
        }
    }

    /// Best-effort cleanup of an unused bundle. A completed bundle is kept as
    /// the user's portal history, so a signed run deletes nothing.
    private func cleanup(bundleID: String?) async {
        guard let bundleID, !matchesSigned else { return }
        try? await client.deleteBundle(bundleID: bundleID)
    }

    private var matchesSigned: Bool {
        if case .signed = state { return true }
        return false
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// What the portal needs to accept one document for a `qes` signature.
public struct AGPSigningRequest: Sendable, Equatable {
    public var filename: String
    public var data: Data
    public var mimeType: String
    public var format: AGPSignatureFormat
    public var level: AGPSignatureLevel

    public init(filename: String, data: Data, mimeType: String,
                format: AGPSignatureFormat,
                level: AGPSignatureLevel) {
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
        self.format = format
        self.level = level
    }
}
