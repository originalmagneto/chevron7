// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Darwin
import Foundation

enum MachineSessionProcessFailure: Error, Sendable, Equatable {
    case launchFailed
    case malformedOutput
    case helperExited(status: Int32)
    case requestFailed(code: String)
    case cancelled
}

actor MachineSessionProcess {
    private struct ActiveProcess {
        let id: UUID
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let error: FileHandle
        var outputBuffer = Data()
    }

    private struct PendingRequest {
        var events: [MachineV2Event]
        let continuation: CheckedContinuation<[MachineV2Event], Error>
    }

    private var activeProcess: ActiveProcess?
    private var pendingRequests: [String: PendingRequest] = [:]
    /// Requests the app cancelled while the engine still runs them. Their late events are
    /// dropped until the request's terminal event, instead of failing the whole session.
    private var cancelledRequestIDs: Set<String> = []
    private var tokenOperationHeld = false
    private var tokenOperationWaiters: [CheckedContinuation<Void, Error>] = []

    func send(
        _ request: MachineV2Request,
        configuration: ProcessConfiguration
    ) async throws -> [MachineV2Event] {
        try await send(SecureMachineV2Request(envelope: request), configuration: configuration)
    }

    func send(
        _ request: SecureMachineV2Request,
        configuration: ProcessConfiguration
    ) async throws -> [MachineV2Event] {
        defer { request.discardSecrets() }
        if request.envelope.operation.requiresToken {
            try await acquireTokenOperationPermit()
            do {
                defer { releaseTokenOperationPermit() }
                return try await sendNow(request, configuration: configuration)
            }
        }
        return try await sendNow(request, configuration: configuration)
    }

    func stop() {
        guard let activeProcess else { return }
        self.activeProcess = nil
        activeProcess.output.readabilityHandler = nil
        activeProcess.error.readabilityHandler = nil
        activeProcess.process.terminate()
        finishPending(with: .cancelled)
    }

    private func sendNow(
        _ request: SecureMachineV2Request,
        configuration: ProcessConfiguration
    ) async throws -> [MachineV2Event] {
        guard request.envelope.protocolVersion == 2,
              !request.envelope.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MachineSessionProcessFailure.malformedOutput
        }
        try startIfNeeded(configuration: configuration)
        guard let activeProcess else {
            throw MachineSessionProcessFailure.launchFailed
        }
        guard pendingRequests[request.envelope.requestID] == nil else {
            throw MachineSessionProcessFailure.malformedOutput
        }

        var encoded = MachineV2RequestEncoder.encode(request)
        defer { encoded.resetBytes(in: encoded.startIndex..<encoded.endIndex) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[request.envelope.requestID] = PendingRequest(events: [], continuation: continuation)
                activeProcess.input.write(encoded)
                activeProcess.input.write(Data([10]))
            }
        } onCancel: {
            Task { await self.cancelRequest(id: request.envelope.requestID) }
        }
    }

    private func startIfNeeded(configuration: ProcessConfiguration) throws {
        guard activeProcess == nil else { return }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let stderr = Pipe()
        let id = UUID()
        process.executableURL = configuration.executableURL
        process.arguments = ["--cli", "--machine-readable", "--protocol-version", "2"]
        process.environment = configuration.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderr
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { await self?.processExited(id: id, status: terminatedProcess.terminationStatus) }
        }

        activeProcess = ActiveProcess(
            id: id,
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            error: stderr.fileHandleForReading
        )
        beginReading(id: id, output: output.fileHandleForReading, error: stderr.fileHandleForReading)
        do {
            try process.run()
        } catch {
            activeProcess = nil
            output.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw MachineSessionProcessFailure.launchFailed
        }
    }

    private func beginReading(id: UUID, output: FileHandle, error: FileHandle) {
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.consumeOutput(data, processID: id) }
        }
        error.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    private func consumeOutput(_ data: Data, processID: UUID) {
        guard var activeProcess, activeProcess.id == processID else { return }
        activeProcess.outputBuffer.append(data)
        while let newline = activeProcess.outputBuffer.firstIndex(of: 10) {
            let line = activeProcess.outputBuffer[..<newline]
            activeProcess.outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else {
                failProcess(processID: processID, failure: .malformedOutput)
                return
            }
            do {
                let event = try MachineV2ProtocolDecoder.decode(Data(line))
                route(event, processID: processID)
                guard self.activeProcess?.id == processID else { return }
            } catch {
                failProcess(processID: processID, failure: .malformedOutput)
                return
            }
        }
        self.activeProcess = activeProcess
    }

    private func route(_ event: MachineV2Event, processID: UUID) {
        guard activeProcess?.id == processID else { return }
        if cancelledRequestIDs.contains(event.requestID) {
            if event.type.isTerminal {
                cancelledRequestIDs.remove(event.requestID)
            }
            return
        }
        guard var pending = pendingRequests[event.requestID] else {
            failProcess(processID: processID, failure: .malformedOutput)
            return
        }
        pending.events.append(event)
        guard event.type.isTerminal else {
            pendingRequests[event.requestID] = pending
            return
        }
        pendingRequests.removeValue(forKey: event.requestID)
        if event.type == .requestCompleted {
            pending.continuation.resume(returning: pending.events)
        } else {
            let code: String
            if case .string(let value)? = event.payload["code"] {
                code = value
            } else {
                code = "INTERNAL_ERROR"
            }
            pending.continuation.resume(throwing: MachineSessionProcessFailure.requestFailed(code: code))
        }
    }

    private func processExited(id: UUID, status: Int32) {
        guard let activeProcess, activeProcess.id == id else { return }
        activeProcess.output.readabilityHandler = nil
        activeProcess.error.readabilityHandler = nil
        self.activeProcess = nil
        finishPending(with: .helperExited(status: status))
    }

    private func failProcess(processID: UUID, failure: MachineSessionProcessFailure) {
        guard let activeProcess, activeProcess.id == processID else { return }
        self.activeProcess = nil
        activeProcess.output.readabilityHandler = nil
        activeProcess.error.readabilityHandler = nil
        activeProcess.process.terminate()
        finishPending(with: failure)
    }

    private func cancelRequest(id: String) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        cancelledRequestIDs.insert(id)
        pending.continuation.resume(throwing: MachineSessionProcessFailure.cancelled)
    }

    /// Ends every request of the current helper process; a new process never emits events
    /// for a request cancelled on the old one.
    private func finishPending(with failure: MachineSessionProcessFailure) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        cancelledRequestIDs.removeAll()
        for request in pending.values {
            request.continuation.resume(throwing: failure)
        }
    }

    private func acquireTokenOperationPermit() async throws {
        guard tokenOperationHeld else {
            tokenOperationHeld = true
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            tokenOperationWaiters.append(continuation)
        }
    }

    private func releaseTokenOperationPermit() {
        guard !tokenOperationWaiters.isEmpty else {
            tokenOperationHeld = false
            return
        }
        tokenOperationWaiters.removeFirst().resume()
    }
}
