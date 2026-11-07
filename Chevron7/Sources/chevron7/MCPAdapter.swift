// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import MCP
import Chevron7Integration

struct IntegrationTool: Sendable {
    let name: String
    let method: String
    let description: String
    let fields: [String: String]
    let required: Set<String>
    var readOnly = true

    var tool: Tool {
        var properties: [String: MCP.Value] = [:]
        for (name, type) in fields {
            var property: [String: MCP.Value] = ["type": .string(type)]
            if type == "array" { property["items"] = .object(["type": .string("string")]) }
            if name == "format" { property["enum"] = .array([.string("pades"), .string("asice")]) }
            if name == "level" { property["enum"] = .array([.string("B"), .string("T")]) }
            if name == "limit" { property["minimum"] = .int(1); property["maximum"] = .int(100) }
            properties[name] = .object(property)
        }
        return Tool(name: name, description: description, inputSchema: .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.sorted().map(MCP.Value.string)), "additionalProperties": .bool(false)
        ]), annotations: .init(readOnlyHint: readOnly, destructiveHint: false, idempotentHint: readOnly, openWorldHint: method == "validate" || method == "sign" || method == "ezzk.lookup"))
    }

    func validated(_ input: [String: JSONValue]) throws -> [String: JSONValue] {
        guard Set(input.keys).isSubset(of: Set(fields.keys)), required.isSubset(of: Set(input.keys)) else { throw CLIOptions.invalid("Unknown or missing tool arguments.") }
        for (key, value) in input {
            switch fields[key] {
            case "string": guard let text = value.string, !text.isEmpty else { throw CLIOptions.invalid("\(key) must be a nonempty string.") }
            case "integer": guard let number = value.number, number.rounded() == number, (1...100).contains(number) else { throw CLIOptions.invalid("\(key) must be an integer from 1 to 100.") }
            case "array": guard let array = value.array, array.allSatisfy({ $0.string?.isEmpty == false }) else { throw CLIOptions.invalid("\(key) must contain paths as strings.") }
            default: throw CLIOptions.invalid("Unknown field \(key).")
            }
        }
        for key in ["file", "output"] {
            if let value = input[key]?.string, !value.hasPrefix("/") { throw CLIOptions.invalid("\(key) must be an absolute local path.") }
        }
        if let array = input["attachments"]?.array, array.contains(where: { !($0.string ?? "").hasPrefix("/") }) { throw CLIOptions.invalid("Attachment paths must be absolute.") }
        if let format = input["format"]?.string, !["pades", "asice"].contains(format) { throw CLIOptions.invalid("Unsupported format.") }
        if let level = input["level"]?.string, !["B", "T"].contains(level) { throw CLIOptions.invalid("Unsupported level.") }
        return input
    }

    static func available(options: CLIOptions) -> [IntegrationTool] {
        var tools = [
            IntegrationTool(name: "chevron7_status", method: "status", description: "Read Chevron7 readiness, API version and supported capabilities. Does not log in to a card.", fields: [:], required: []),
            IntegrationTool(name: "chevron7_inspect", method: "inspect", description: "Inspect a local PDF or ASiC-E signature tree. Structural inspection is not trusted validation.", fields: ["file": "string"], required: ["file"]),
            IntegrationTool(name: "chevron7_validate", method: "validate", description: "Validate signatures of a local PDF or ASiC-E; report unsigned, invalid and indeterminate outcomes explicitly. May fetch trust lists and revocation data.", fields: ["file": "string"], required: ["file"]),
            IntegrationTool(name: "chevron7_sign", method: "sign", description: "Request a signature and return a job handle immediately. The person must confirm in Chevron7 and choose card or mobile. Never supply a PIN. Use a stable requestKey to recover an uncertain request without repeating the signature. Poll chevron7_job_get. Output must not exist.", fields: ["file": "string", "output": "string", "format": "string", "level": "string", "attachments": "array", "requestKey": "string"], required: ["file", "output", "format", "level", "requestKey"], readOnly: false),
            IntegrationTool(name: "chevron7_job_get", method: "jobs.get", description: "Read this session's job. Completed results remain available for 30 minutes. A job ID does not grant access to another session.", fields: ["jobId": "string"], required: ["jobId"]),
            IntegrationTool(name: "chevron7_job_cancel", method: "jobs.cancel", description: "Cancel this session's pending signing job. Cannot revoke an already created signature.", fields: ["jobId": "string"], required: ["jobId"], readOnly: false),
            IntegrationTool(name: "chevron7_job_save", method: "jobs.save", description: "Save retained signed bytes to a new permitted output without signing again. Output must not exist.", fields: ["jobId": "string", "output": "string"], required: ["jobId", "output"], readOnly: false)
        ]
        if options.allowRegister {
            tools += [
                IntegrationTool(name: "chevron7_register_list", method: "register.list", description: "Read minimal conversion register metadata with pagination. Account-wide access, not scoped to the selected matter.", fields: ["limit": "integer", "cursor": "string"], required: []),
                IntegrationTool(name: "chevron7_register_get", method: "register.get", description: "Read one existing register record. Account-wide access; excludes document bytes and full clause XML.", fields: ["recordId": "string"], required: ["recordId"])
            ]
        }
        if options.allowEzzk { tools.append(IntegrationTool(name: "chevron7_ezzk_lookup", method: "ezzk.lookup", description: "Read the EZZK state of an existing record in its saved environment through the read-only public lookup. Account-wide grant. Does not submit, resend, allocate or consume numbers, or update the register.", fields: ["recordId": "string"], required: ["recordId"])) }
        return tools
    }
}

enum MCPAdapter {
    static func confirmedBegin(_ request: IntegrationRequest,
                               execute: @escaping @Sendable (IntegrationRequest, TimeInterval) async throws -> IntegrationResponse,
                               isClosing: @escaping @Sendable () -> Bool = { false }) async throws -> IntegrationResponse {
        let response = try await Task { try await execute(request, 30) }.value
        if Task.isCancelled || isClosing() {
            if let jobId = response.result?["jobId"]?.string {
                var arguments = request.arguments.filter { ["roots", "allowRegister", "allowEzzk"].contains($0.key) }
                arguments["jobId"] = .string(jobId)
                let cancellation = IntegrationRequest(session: request.session, method: "jobs.cancel", arguments: arguments)
                _ = try? await Task { try await execute(cancellation, 5) }.value
            }
            throw CancellationError()
        }
        return response
    }

    static func run(options: CLIOptions, version: String) async throws {
        // Roots are host-selected fixed launch configuration. MCP roots notifications are not authority.
        for path in options.roots {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw CLIOptions.invalid("Every --root must be an existing directory.") }
        }
        let session = UUID().uuidString
        let client = IntegrationClient()
        let available = IntegrationTool.available(options: options)
        let sessionOpened = CancellationFlag()
        let admissions = MCPSigningAdmissions()
        let server = Server(name: "chevron7", version: version, capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: available.map(\.tool)) }
        await server.withMethodHandler(CallTool.self) { params in
            let id = UUID().uuidString
            let response: IntegrationResponse
            do {
                guard let tool = available.first(where: { $0.name == params.name }) else { throw CLIOptions.invalid("Unknown or disabled tool.") }
                let input = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(params.arguments ?? [:]))
                let arguments = try tool.validated(input)
                let request = IntegrationRequest(requestId: id, session: session, method: tool.method, arguments: options.scoped(arguments))
                if tool.method == "sign" {
                    try admissions.enter()
                    defer { admissions.leave() }
                    sessionOpened.set()
                    // Preserve the begin reply if MCP cancels while XPC admits the job. Only that
                    // handle may be cancelled; closing the session would affect unrelated jobs.
                    response = try await confirmedBegin(request, execute: { try await client.execute($0, timeout: $1) }, isClosing: { admissions.isClosing })
                } else {
                    response = try await client.execute(request)
                    sessionOpened.set()
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as IntegrationError {
                if Task.isCancelled { throw CancellationError() }
                response = IntegrationResponse(requestId: id, error: error)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                response = IntegrationResponse(requestId: id, error: IntegrationError(code: "INVALID_ARGUMENTS", message: "The request could not be processed."))
            }
            let data = try JSONEncoder().encode(response)
            return try .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: response, isError: !response.ok || ["failed", "cancelled", "outcomeUnknown"].contains(response.result?["state"]?.string ?? ""))
        }
        try await server.start(transport: StdioTransport())
        let shutdown = SignalMonitor {
            Task { await server.stop() }
        }
        await server.waitUntilCompleted()
        shutdown.stop()
        await admissions.closeAndWait()
        if sessionOpened.isSet {
            _ = try? await client.execute(IntegrationRequest(session: session, method: "session.close", arguments: options.scoped([:])), timeout: 5)
        }
    }
}

/// EOF stops new signing admissions and drains admitted begin replies before session teardown.
final class MCPSigningAdmissions: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var closing = false
    private var waiter: CheckedContinuation<Void, Never>?
    var isClosing: Bool { lock.lock(); defer { lock.unlock() }; return closing }
    func enter() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { throw CancellationError() }
        pending += 1
    }
    func leave() {
        lock.lock()
        pending -= 1
        let ready = pending == 0 ? waiter : nil
        if ready != nil { waiter = nil }
        lock.unlock()
        ready?.resume()
    }
    func closeAndWait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            closing = true
            if pending == 0 { lock.unlock(); continuation.resume() }
            else { waiter = continuation; lock.unlock() }
        }
    }
}
