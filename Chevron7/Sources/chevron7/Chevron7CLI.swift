// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Darwin
import Chevron7Integration

@main
struct Chevron7CLI {
    static let help = """
    Chevron7 integration CLI (API v1)
    Usage: chevron7 [--session NAME] COMMAND [--json] [--root DIR ...]
      version                        Print helper and API version without starting the app
      status                         Check the installed app and bridge
      inspect FILE                   Inspect signatures, without a trusted validation claim
      validate FILE                  Validate signatures (exit 10 unless fully valid)
      sign FILE --output FILE [--format pades|asice] [--level B|T]
                [--attach FILE ...] [--request-key KEY] [--timeout SECONDS] [--no-wait]
      jobs get ID                    Read retained job state/result
      jobs cancel ID                 Cancel this session's pending job
      jobs save ID --output FILE     Save retained signature without signing again
      register list [--limit 1..100] [--cursor TOKEN] --allow-register
      register get ID --allow-register
      ezzk lookup RECORD_ID --allow-ezzk
      mcp --root DIR [--root DIR ...] [--allow-register] [--allow-ezzk]

    Signing always needs confirmation in Chevron7. No PIN is accepted by this interface.
    --root limits local input/output directories. MCP requires at least one root.
    Register/EZZK grants expose account-wide metadata, regardless of roots.
    CLI session profiles isolate cooperating applications; use a different profile per client.
    Output files must not exist. Results expire after 30 minutes or an app restart.
    Exit codes: 0 completed; 2 arguments; 3 unavailable; 4 busy; 5 cancelled;
                6 timeout; 7 file/delivery; 8 service; 9 unknown outcome; 10 validation.
    """

    static var version: String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist), let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "development" }
        return values["CFBundleShortVersionString"] as? String ?? "development"
    }

    static func main() async {
        let tokens = Array(CommandLine.arguments.dropFirst())
        let id = UUID().uuidString
        do {
            let options = try CLIOptions(tokens)
            if options.method == "help" { print(help); return }
            if options.method == "version" {
                let response = IntegrationResponse(requestId: id, result: .object(["version": .string(version), "apiVersion": .number(1)]))
                try emit(response, json: options.json); return
            }
            if options.method == "mcp" { try await MCPAdapter.run(options: options, version: version); return }
            let session = try SessionProfile.capability(name: options.session)
            let client = IntegrationClient()
            var arguments = options.arguments
            if options.method == "sign", arguments["requestKey"] == nil { arguments["requestKey"] = .string(id) }
            let cancelled = CancellationFlag()
            let monitor = options.method == "sign" ? SignalMonitor { cancelled.set() } : nil
            defer { monitor?.stop() }
            let response = try await client.execute(IntegrationRequest(requestId: id, session: session, method: options.method, arguments: options.scoped(arguments)))
            if options.method == "sign", (!options.noWait || cancelled.isSet), response.ok, let job = response.result?["jobId"]?.string {
                let final = await waitForJob(job, session: session, options: options, client: client, cancelled: cancelled)
                try emit(final, json: options.json)
                exit(exitCode(final, method: "sign"))
            }
            try emit(response, json: options.json)
            exit(exitCode(response, method: options.method))
        } catch {
            let failure = error as? IntegrationError ?? IntegrationError(code: "SERVICE_ERROR", message: error.localizedDescription)
            try? emit(IntegrationResponse(requestId: id, error: failure), json: tokens.contains("--json") && !tokens.contains("mcp"))
            exit(failure.exitCode)
        }
    }

    static func waitForJob(_ id: String, session: String, options: CLIOptions, client: IntegrationClient, cancelled: CancellationFlag) async -> IntegrationResponse {
        let deadline = Date().addingTimeInterval(options.timeout)
        while true {
            let timedOut = Date() >= deadline
            let method = cancelled.isSet || timedOut ? "jobs.cancel" : "jobs.get"
            do {
                let response = try await client.execute(IntegrationRequest(session: session, method: method, arguments: options.scoped(["jobId": .string(id)])), timeout: 30)
                let state = response.result?["state"]?.string ?? ""
                if timedOut && state == "cancelled" { return IntegrationResponse(requestId: response.requestId, error: IntegrationError(code: "TIMEOUT", message: "Signing deadline elapsed; pending job \(id) was cancelled.")) }
                if !response.ok || ["completed", "cancelled", "failed", "outcomeUnknown"].contains(state) { return response }
                if cancelled.isSet || timedOut { return IntegrationResponse(requestId: UUID().uuidString, error: IntegrationError(code: "OUTCOME_UNKNOWN", message: "Cancellation was not acknowledged as a terminal result. Check job \(id) before retrying.")) }
                try await Task.sleep(for: .seconds(1))
            } catch {
                return IntegrationResponse(requestId: UUID().uuidString, error: IntegrationError(code: "OUTCOME_UNKNOWN", message: "Lost contact with job \(id). Query it with the same --session before retrying."))
            }
        }
    }

    static func exitCode(_ response: IntegrationResponse, method: String) -> Int32 {
        if let error = response.error { return error.exitCode }
        if let code = response.result?["error"]?["code"]?.string { return IntegrationError(code: code, message: "").exitCode }
        let state = response.result?["state"]?.string
        if state == "cancelled" { return 5 }
        if state == "outcomeUnknown" { return 9 }
        if state == "failed" { return 8 }
        if method == "validate", response.result?["validationState"]?.string != "valid" { return 10 }
        return 0
    }

    static func emit(_ response: IntegrationResponse, json: Bool) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if json { FileHandle.standardOutput.write(try encoder.encode(response)); FileHandle.standardOutput.write(Data([10])) }
        else if let error = response.error { FileHandle.standardError.write(Data("\(error.code): \(error.message)\n".utf8)) }
        else { encoder.outputFormatting.insert(.prettyPrinted); print(String(decoding: try encoder.encode(response.result), as: UTF8.self)) }
    }
}

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

final class SignalMonitor {
    private let sources: [DispatchSourceSignal]
    init(action: @escaping @Sendable () -> Void) {
        sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: action); source.resume(); return source
        }
    }
    func stop() { sources.forEach { $0.cancel() } }
}
