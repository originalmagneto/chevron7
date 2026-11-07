// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Integration

struct CLIOptions: Sendable {
    var method = "help"
    var json = false
    var noWait = false
    var timeout: TimeInterval = 900
    var session = "terminal"
    var roots: [String] = []
    var allowRegister = false
    var allowEzzk = false
    var arguments: [String: JSONValue] = [:]

    init(_ tokens: [String]) throws {
        var positional: [String] = []
        var values: [String: String] = [:]
        var attachments: [String] = []
        var index = 0
        var localCommand: String?
        let flags: Set<String> = ["--json", "--no-wait", "--allow-register", "--allow-ezzk", "--help", "--version"]
        let valued: Set<String> = ["--session", "--root", "--output", "--format", "--level", "--attach", "--request-key", "--limit", "--cursor", "--timeout"]
        while index < tokens.count {
            let token = tokens[index]; index += 1
            if token == "--" { positional.append(contentsOf: tokens[index...]); break }
            if flags.contains(token) {
                switch token {
                case "--json": json = true
                case "--no-wait": noWait = true
                case "--allow-register": allowRegister = true
                case "--allow-ezzk": allowEzzk = true
                case "--help": localCommand = "help"
                case "--version": localCommand = "version"
                default: break
                }
            } else if valued.contains(token) {
                guard index < tokens.count, !tokens[index].hasPrefix("--") else { throw Self.invalid("Missing value for \(token).") }
                let value = tokens[index]; index += 1
                if token == "--root" { roots.append(Self.absolute(value)) }
                else if token == "--attach" { attachments.append(Self.absolute(value)) }
                else { guard values[token] == nil else { throw Self.invalid("Duplicate option \(token).") }; values[token] = value }
            } else if token.hasPrefix("-") { throw Self.invalid("Unknown option \(token).") }
            else { positional.append(token) }
        }
        if let localCommand { method = localCommand; return }
        session = values.removeValue(forKey: "--session") ?? session
        guard SessionProfile.validName(session) else { throw Self.invalid("Session name must contain 1 to 64 letters, digits, hyphens or underscores.") }
        guard let first = positional.first else { return }
        var operands = Array(positional.dropFirst())
        if ["jobs", "register", "ezzk"].contains(first) {
            guard !operands.isEmpty else { throw Self.invalid("Missing \(first) subcommand.") }
            method = first + "." + operands.removeFirst()
        } else { method = first }
        let allowedOptions: Set<String>
        let count: Int
        switch method {
        case "help", "version", "status", "mcp": count = 0; allowedOptions = []
        case "inspect", "validate": count = 1; allowedOptions = []
        case "sign": count = 1; allowedOptions = ["--output", "--format", "--level", "--request-key", "--timeout"]
        case "jobs.get", "jobs.cancel": count = 1; allowedOptions = []
        case "jobs.save": count = 1; allowedOptions = ["--output"]
        case "register.list": count = 0; allowedOptions = ["--limit", "--cursor"]
        case "register.get", "ezzk.lookup": count = 1; allowedOptions = []
        default: throw Self.invalid("Unknown command \(method).")
        }
        guard operands.count == count else { throw Self.invalid("Unexpected or missing operand for \(method).") }
        guard Set(values.keys).isSubset(of: allowedOptions), (attachments.isEmpty || method == "sign"), (!noWait || method == "sign") else { throw Self.invalid("An option does not apply to \(method).") }
        roots = roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        if method == "mcp", json { throw Self.invalid("MCP stdout is reserved for protocol messages; omit --json.") }
        if method == "mcp", roots.isEmpty { throw Self.invalid("MCP needs at least one --root directory chosen by the host.") }
        if ["inspect", "validate", "sign"].contains(method) { arguments["file"] = .string(Self.absolute(operands[0])) }
        if method.hasPrefix("jobs.") { arguments["jobId"] = .string(operands[0]) }
        if method == "register.get" || method == "ezzk.lookup" { arguments["recordId"] = .string(operands[0]) }
        for (option, key) in [("--output", "output"), ("--format", "format"), ("--level", "level"), ("--request-key", "requestKey"), ("--cursor", "cursor")] {
            if let value = values[option] { arguments[key] = .string(option == "--output" ? Self.absolute(value) : value) }
        }
        if method == "sign" {
            if let raw = values["--timeout"] {
                guard let seconds = Double(raw), seconds.isFinite, (1...3600).contains(seconds) else { throw Self.invalid("Timeout must be from 1 to 3600 seconds.") }
                timeout = seconds
            }
            arguments["format"] = arguments["format"] ?? .string("pades")
            arguments["level"] = arguments["level"] ?? .string("B")
            guard ["pades", "asice"].contains(arguments["format"]?.string ?? ""), ["B", "T"].contains(arguments["level"]?.string ?? "") else { throw Self.invalid("Use --format pades|asice and --level B|T.") }
            if !attachments.isEmpty { arguments["attachments"] = .array(attachments.map(JSONValue.string)) }
        }
        if method == "sign" || method == "jobs.save", arguments["output"] == nil { throw Self.invalid("An explicit --output file is required.") }
        if let limit = values["--limit"] {
            guard let number = Int(limit), (1...100).contains(number) else { throw Self.invalid("Limit must be an integer from 1 to 100.") }
            arguments["limit"] = .number(Double(number))
        }
        if method.hasPrefix("register."), !allowRegister { throw Self.invalid("Register reads require --allow-register (account-wide access).") }
        if method == "ezzk.lookup", !allowEzzk { throw Self.invalid("EZZK lookups require --allow-ezzk (account-wide access).") }
    }

    func scoped(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        var result = arguments
        if !roots.isEmpty { result["roots"] = .array(roots.map(JSONValue.string)) }
        result["allowRegister"] = .bool(allowRegister)
        result["allowEzzk"] = .bool(allowEzzk)
        return result
    }

    static func absolute(_ path: String) -> String { URL(fileURLWithPath: path).path }
    static func invalid(_ message: String) -> IntegrationError { IntegrationError(code: "INVALID_ARGUMENTS", message: message) }
}
