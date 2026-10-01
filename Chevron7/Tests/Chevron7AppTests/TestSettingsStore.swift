// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Chevron7TestSupport
import Foundation
import XCTest
@testable import Chevron7App

extension XCTestCase {
    /// An `AppSettingsStore` whose evidence register, vision bank, output, templates and
    /// signature images live in a temporary folder removed when the test ends, never in
    /// the user's real `~/Library/Application Support/Chevron7`.
    ///
    /// When no `ezzkAccountController` is given, this builds one in Demo mode with an
    /// in-memory credential store and a transport that never touches the network: whatever
    /// EZZK mode and Keychain credentials the developer's real, saved `AppSettings` carry
    /// (`AppSettingsStore.init` otherwise defaults to `EZZKAccountController(mode:
    /// loaded.ezzkMode)`, which reads the real Keychain) must never reach a test. Its
    /// production policy is `.refused`, never the developer's real owner switch.
    ///
    /// Settings load from and save to a fresh `MemoryUserDefaults`, never `.standard`: under
    /// XCTest that is `com.apple.dt.xctest.tool` in `~/Library/Preferences`, so every
    /// `settings` change a test made would persist and be what the next test loads.
    @MainActor
    func makeSettingsStore(ezzkAccountController: EZZKAccountController? = nil) -> AppSettingsStore {
        let controller = ezzkAccountController ?? EZZKAccountController(
            mode: .demo,
            credentialStore: MemoryCredentialStore(),
            transportFactory: { _ in ScriptedTransport([]) }, productionPolicy: .refused)
        return AppSettingsStore(ezzkAccountController: controller,
                                 storageRoot: makeTemporaryDirectory("app-storage"),
                                 defaults: MemoryUserDefaults())
    }

    /// An `AppSettingsStore` whose register.json is unreadable from the start (a temporary
    /// folder, never the real register), so `evidenceStore.loadError` is already set when
    /// the store returns. Used to prove code that must refuse to touch the register or the
    /// evidence number pool while it cannot be trusted.
    @MainActor
    func makeSettingsStoreWithUnreadableRegister(ezzkAccountController: EZZKAccountController? = nil) throws -> AppSettingsStore {
        let storageRoot = makeTemporaryDirectory("app-storage")
        let evidence = storageRoot.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data(#"{"not":"an array"}"#.utf8).write(to: evidence.appendingPathComponent("register.json"))
        let controller = ezzkAccountController ?? EZZKAccountController(
            mode: .demo,
            credentialStore: MemoryCredentialStore(),
            transportFactory: { _ in ScriptedTransport([]) }, productionPolicy: .refused)
        return AppSettingsStore(ezzkAccountController: controller, storageRoot: storageRoot,
                                 defaults: MemoryUserDefaults())
    }
}

/// In-memory `EZZKSOAPCredentialStoring` double: never the real Keychain.
final class MemoryCredentialStore: EZZKSOAPCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EZZKEnvironment: EZZKSOAPCredentials] = [:]
    private var failureOnDelete: Error?

    var deleteFailure: Error? {
        get { lock.withLock { failureOnDelete } }
        set { lock.withLock { failureOnDelete = newValue } }
    }

    func load(environment: EZZKEnvironment) throws -> EZZKSOAPCredentials? {
        lock.withLock { items[environment] }
    }

    func save(_ credentials: EZZKSOAPCredentials, environment: EZZKEnvironment) throws {
        lock.withLock { items[environment] = credentials }
    }

    func delete(environment: EZZKEnvironment) throws {
        try lock.withLock {
            if let failureOnDelete { throw failureOnDelete }
            items[environment] = nil
        }
    }
}

/// Scripted `EZZKHTTPTransport` double: never a real network request.
final class ScriptedTransport: EZZKHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private var recorded: [URLRequest] = []

    init(_ replies: [String]) {
        self.replies = replies
    }

    var requestCount: Int {
        lock.withLock { recorded.count }
    }

    /// SOAP operation of each request, read from the action in its Content-Type.
    var operations: [String] {
        lock.withLock { recorded }.compactMap { request in
            request.value(forHTTPHeaderField: "Content-Type")?
                .components(separatedBy: "/").last?
                .replacingOccurrences(of: "\"", with: "")
        }
    }

    /// Request bodies as text, in order.
    var bodies: [String] {
        lock.withLock { recorded }.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String? = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let body else { throw URLError(.badServerResponse) }
        // A real "Date" header on every reply, so `EZZKSOAPClient.serverTime()` (which reads
        // it, not the body) works against a script the same way it does against EZZK.
        return (Data(body.utf8),
               HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                               headerFields: ["Date": Self.httpDateFormatter.string(from: Date())])!)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}
