// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Darwin

enum CLIProcessFailure: Error, Sendable, Equatable, LocalizedError {
    case launchFailed
    case malformedOutput
    case helperExited(status: Int32, diagnostic: String?)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed: return "The signing helper could not be started."
        case .malformedOutput: return "The signing helper returned invalid machine output."
        case .helperExited(let status, let diagnostic):
            let reason = "The signing helper exited unexpectedly. [HELPER_EXIT_\(status)]"
            return diagnostic.map { "\(reason) \($0)" } ?? reason
        case .timedOut: return "The signing helper did not finish in time."
        case .cancelled: return "The signing operation was cancelled."
        }
    }
}

actor CLIProcessRunner {
    private static let safeDiagnosticCodes: Set<String> = ["[TIMESTAMP_UNAVAILABLE]"]

    private struct ActiveRun {
        let id: UUID
        let process: Process
        let stdout: FileHandle
        let stderr: FileHandle
        let continuation: AsyncThrowingStream<MachineEvent, Error>.Continuation
        var stdoutBuffer: JSONLineBuffer
        let maxStderrBytes: Int
        var capturedStderr = Data()
        var terminationStatus: Int32?
        var stdoutFinished = false
        var stderrFinished = false
        var terminalEventReceived = false
        var requestedFailure: CLIProcessFailure?
        var timeoutTask: Task<Void, Never>?
    }

    private var activeRun: ActiveRun?
    /// Runs asked for but not started yet, and those of them whose consumer gave up.
    private var pendingRunIDs: Set<UUID> = []
    private var cancelledRunIDs: Set<UUID> = []
    /// Runs waiting for the helper of the run before them to end.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func run(
        request: MachineRequest,
        configuration: ProcessConfiguration
    ) -> AsyncThrowingStream<MachineEvent, Error> {
        run(request: SecureMachineRequest(envelope: request), configuration: configuration)
    }

    func run(
        request: SecureMachineRequest,
        configuration: ProcessConfiguration
    ) -> AsyncThrowingStream<MachineEvent, Error> {
        let id = UUID()
        pendingRunIDs.insert(id)
        return AsyncThrowingStream { continuation in
            // A consumer that is cancelled ends exactly its own run. Stopping whatever runs
            // when the cancellation arrives could hit the next request instead.
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                Task { await self.cancel(runID: id) }
            }
            Task {
                await self.start(
                    id: id,
                    request: request,
                    configuration: configuration,
                    continuation: continuation
                )
            }
        }
    }

    func cancel() async {
        guard let activeRun else { return }
        stop(runID: activeRun.id, failure: .cancelled)
    }

    private func cancel(runID: UUID) {
        if activeRun?.id == runID {
            stop(runID: runID, failure: .cancelled)
        } else if pendingRunIDs.contains(runID) {
            cancelledRunIDs.insert(runID)
            wakeIdleWaiters()
        }
    }

    private func wakeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// A run starts only once the helper before it has ended: a consumer that gave up
    /// returns at once, while its helper still takes a moment to stop.
    private func start(
        id: UUID,
        request: SecureMachineRequest,
        configuration: ProcessConfiguration,
        continuation: AsyncThrowingStream<MachineEvent, Error>.Continuation
    ) async {
        while activeRun != nil, !cancelledRunIDs.contains(id) {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        pendingRunIDs.remove(id)
        if cancelledRunIDs.remove(id) != nil {
            request.discardSecrets()
            continuation.finish(throwing: CLIProcessFailure.cancelled)
            return
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = [
            "--cli",
            "--machine-readable",
            "--protocol-version",
            "1",
            "--operation",
            request.envelope.operation.rawValue
        ]
        process.environment = configuration.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task {
                await self?.processTerminated(runID: id, status: status)
            }
        }

        activeRun = ActiveRun(
            id: id,
            process: process,
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading,
            continuation: continuation,
            stdoutBuffer: JSONLineBuffer(maxLineBytes: configuration.maxStdoutLineBytes),
            maxStderrBytes: configuration.maxStderrBytes
        )
        startReaders(for: id, stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)

        var encodedRequest = Data()
        defer {
            encodedRequest.resetBytes(in: encodedRequest.startIndex..<encodedRequest.endIndex)
            request.discardSecrets()
        }

        do {
            try process.run()
            encodedRequest = MachineRequestEncoder.encode(request)
            stdin.fileHandleForWriting.write(encodedRequest)
            stdin.fileHandleForWriting.write(Data([10]))
            try stdin.fileHandleForWriting.close()
            scheduleTimeout(for: id, duration: configuration.timeout)
        } catch {
            try? stdin.fileHandleForWriting.close()
            finish(runID: id, throwing: .launchFailed)
        }
    }

    private func startReaders(for runID: UUID, stdout: FileHandle, stderr: FileHandle) {
        let stdoutChunks = Self.chunks(from: stdout)
        Task { [weak self] in
            for await chunk in stdoutChunks {
                await self?.consumeStdout(chunk, runID: runID)
            }
            await self?.stdoutDidFinish(runID: runID)
        }

        let stderrChunks = Self.chunks(from: stderr)
        Task { [weak self] in
            for await chunk in stderrChunks {
                await self?.consumeStderr(chunk, runID: runID)
            }
            await self?.stderrDidFinish(runID: runID)
        }
    }

    private static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { readableHandle in
                let data = readableHandle.availableData
                guard !data.isEmpty else {
                    readableHandle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }

    private func consumeStdout(_ data: Data, runID: UUID) {
        guard var activeRun, activeRun.id == runID else { return }
        do {
            let events = try activeRun.stdoutBuffer.append(data)
            let receivedTerminalEvent = events.contains {
                $0.type == .sessionCompleted || $0.type == .sessionFailed
            }
            if receivedTerminalEvent {
                activeRun.terminalEventReceived = true
                activeRun.timeoutTask?.cancel()
            }
            self.activeRun = activeRun
            for event in events {
                activeRun.continuation.yield(event)
            }
            if receivedTerminalEvent, activeRun.process.isRunning {
                kill(activeRun.process.processIdentifier, SIGKILL)
            }
        } catch {
            self.activeRun = activeRun
            stop(runID: runID, failure: .malformedOutput)
        }
    }

    private func consumeStderr(_ data: Data, runID: UUID) {
        guard var activeRun, activeRun.id == runID else { return }
        let remaining = max(0, activeRun.maxStderrBytes - activeRun.capturedStderr.count)
        if remaining > 0 {
            activeRun.capturedStderr.append(data.prefix(remaining))
        }
        self.activeRun = activeRun
    }

    private func stdoutDidFinish(runID: UUID) {
        guard var activeRun, activeRun.id == runID else { return }
        activeRun.stdoutFinished = true
        self.activeRun = activeRun
        finishIfReady(runID: runID)
    }

    private func stderrDidFinish(runID: UUID) {
        guard var activeRun, activeRun.id == runID else { return }
        activeRun.stderrFinished = true
        self.activeRun = activeRun
        finishIfReady(runID: runID)
    }

    private func processTerminated(runID: UUID, status: Int32) {
        guard var activeRun, activeRun.id == runID else { return }
        activeRun.terminationStatus = status
        self.activeRun = activeRun
        finishIfReady(runID: runID)
    }

    private func scheduleTimeout(for runID: UUID, duration: Duration?) {
        guard let duration, var activeRun, activeRun.id == runID else { return }
        activeRun.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await self?.stop(runID: runID, failure: .timedOut)
        }
        self.activeRun = activeRun
    }

    private func stop(runID: UUID, failure: CLIProcessFailure) {
        guard var activeRun, activeRun.id == runID, activeRun.requestedFailure == nil else { return }
        activeRun.requestedFailure = failure
        self.activeRun = activeRun
        activeRun.process.terminate()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.interruptIfNeeded(runID: runID)
        }
    }

    private func interruptIfNeeded(runID: UUID) {
        guard let activeRun, activeRun.id == runID, activeRun.process.isRunning else { return }
        kill(activeRun.process.processIdentifier, SIGKILL)
    }

    private func finishIfReady(runID: UUID) {
        guard let activeRun,
              activeRun.id == runID,
              activeRun.terminationStatus != nil,
              activeRun.stdoutFinished,
              activeRun.stderrFinished else {
            return
        }

        if activeRun.terminalEventReceived {
            finish(runID: runID, throwing: nil)
        } else if let failure = activeRun.requestedFailure {
            finish(runID: runID, throwing: failure)
        } else if activeRun.terminationStatus != 0 {
            finish(
                runID: runID,
                throwing: .helperExited(
                    status: activeRun.terminationStatus ?? 0,
                    diagnostic: Self.sanitizedDiagnostic(from: activeRun.capturedStderr)
                )
            )
        } else {
            finish(runID: runID, throwing: nil)
        }
    }

    private func finish(runID: UUID, throwing failure: CLIProcessFailure?) {
        guard let activeRun, activeRun.id == runID else { return }
        activeRun.timeoutTask?.cancel()
        activeRun.stdout.readabilityHandler = nil
        activeRun.stderr.readabilityHandler = nil
        self.activeRun = nil
        if let failure {
            activeRun.continuation.finish(throwing: failure)
        } else {
            activeRun.continuation.finish()
        }
        wakeIdleWaiters()
    }

    private static func sanitizedDiagnostic(from stderr: Data) -> String? {
        guard let text = String(data: stderr, encoding: .utf8) else { return nil }

        return text
            .split(whereSeparator: { $0.isWhitespace })
            .first(where: { safeDiagnosticCodes.contains(String($0)) })
            .map(String.init)
    }
}
