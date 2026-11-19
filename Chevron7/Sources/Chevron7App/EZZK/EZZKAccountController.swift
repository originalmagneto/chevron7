// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation
import Observation

/// EZZK access for Settings, ZaKo and the Register konverzií: the selected mode, the
/// advocate's verified SOAP login, and the service ZaKo calls.
@MainActor
@Observable
final class EZZKAccountController {
    enum State: Equatable {
        case signedOut
        case verifying
        case signedIn(accountName: String, checkedAt: Date)
        case failed(String)
    }

    private(set) var state: State = .signedOut
    private(set) var mode: AppSettings.EZZKMode
    /// Login name saved for the current environment. Never the password.
    private(set) var storedLogin = ""

    /// Not `private` so tests can confirm which store a controller actually uses.
    let credentialStore: any EZZKSOAPCredentialStoring
    /// Whether numbers may be allocated and records sent on production. Read once at launch
    /// (the owner switch needs a relaunch) and handed to every SOAP client and the checker.
    let productionPolicy: EZZKProductionPolicy
    private let transportFactory: @Sendable (EZZKEnvironment) -> any EZZKHTTPTransport
    @ObservationIgnored private var personProvider: @MainActor () -> EZZKPerson = {
        EZZKPerson(corporateBodyFullName: "", ico: "")
    }
    @ObservationIgnored private var usedEvidenceNumbersProvider: @MainActor (AppSettings.EZZKMode) -> Set<String> = { _ in [] }
    /// "DEMO-yyMMdd-n": a simulated number never looks like one a real EZZK allocates.
    private let demoService = MockEZZKService(registryCode: "DEMO")
    /// Clients read the password from the credential store for each login.
    @ObservationIgnored private var clients: [EZZKEnvironment: EZZKSOAPClient] = [:]
    /// One transport (and so one URLSession) per environment for the controller's lifetime.
    @ObservationIgnored private var transports: [EZZKEnvironment: any EZZKHTTPTransport] = [:]
    @ObservationIgnored private var generation: UInt64 = 0

    init(mode: AppSettings.EZZKMode,
         credentialStore: any EZZKSOAPCredentialStoring = EZZKSOAPCredentialStore(),
         transportFactory: @escaping @Sendable (EZZKEnvironment) -> any EZZKHTTPTransport = {
             URLSessionEZZKSOAPTransport(environment: $0)
         },
         productionPolicy: EZZKProductionPolicy = .current(defaults: .standard)) {
        self.mode = mode
        self.credentialStore = credentialStore
        self.productionPolicy = productionPolicy
        self.transportFactory = transportFactory
        reloadStoredLogin()
    }

    /// Settings owns the person and the evidence store, and exists only after this controller.
    func configure(person: @escaping @MainActor () -> EZZKPerson,
                   usedEvidenceNumbers: @escaping @MainActor (AppSettings.EZZKMode) -> Set<String>) {
        personProvider = person
        usedEvidenceNumbersProvider = usedEvidenceNumbers
    }

    var isDemoMode: Bool { mode == .demo }
    var environment: EZZKEnvironment? { mode.environment }
    var hasStoredCredentials: Bool { !storedLogin.isEmpty }

    var service: any EZZKServicing {
        service(for: mode)
    }

    /// The service of one EZZK mode, whatever the current mode is: a register row is sent
    /// to the EZZK that allocated its number even if the mode changes while it is sent.
    func service(for mode: AppSettings.EZZKMode) -> any EZZKServicing {
        guard let environment = mode.environment else { return demoService }
        return EZZKSOAPServiceAdapter(client: client(for: environment), person: personProvider(),
                                      usedEvidenceNumbers: usedEvidenceNumbersProvider(mode))
    }

    func setMode(_ newMode: AppSettings.EZZKMode) {
        guard newMode != mode else { return }
        generation &+= 1
        mode = newMode
        state = .signedOut
        reloadStoredLogin()
    }

    /// Verifies the name and password with EZZK and saves them only when EZZK accepts them.
    func signIn(login: String, password: String) async {
        guard let environment else { return }
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty, !password.isEmpty else {
            state = .failed("Zadajte prihlasovacie meno aj heslo.")
            return
        }
        generation &+= 1
        let operation = generation
        state = .verifying
        let candidate = EZZKSOAPCredentials(login: login, password: password)
        let verification = EZZKSOAPClient(environment: environment, transport: transport(for: environment),
                                          credentials: { candidate }, productionPolicy: productionPolicy)
        do {
            let accountName = try await verification.logIn()
            guard operation == generation else { return }
            try credentialStore.save(candidate, environment: environment)
            // The verification client keeps the password in its closure; never cache it. The next
            // call builds a client that reads the saved item, at the cost of one more LogIn.
            clients[environment] = nil
            storedLogin = login
            state = .signedIn(accountName: accountName, checkedAt: Date())
        } catch {
            guard operation == generation else { return }
            state = .failed(Self.message(for: error))
        }
    }

    func signOut() {
        guard let environment else { return }
        generation &+= 1
        // Drop the live token first, even when the Keychain item cannot be deleted.
        clients[environment] = nil
        do {
            try credentialStore.delete(environment: environment)
        } catch {
            state = .failed(Self.message(for: error))
            return
        }
        storedLogin = ""
        state = .signedOut
    }

    func lookUp(evidenceNumber: String) async throws -> EZZKRecordLookup {
        try await lookUp(evidenceNumber: evidenceNumber, in: mode)
    }

    /// Looks a number up in one EZZK mode's environment, whatever the current mode is.
    /// `executionTime` distinguishes records EZZK stores under one number used more than
    /// once (result 106): pass it on a second attempt after a first 106.
    func lookUp(evidenceNumber: String, in mode: AppSettings.EZZKMode,
               executionTime: Date? = nil) async throws -> EZZKRecordLookup {
        guard let environment = mode.environment else { throw EZZKError.notConfigured }
        return try await client(for: environment)
            .publicRecord(evidenceNumber: evidenceNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                         executionTime: executionTime)
    }

    /// Raw list of the person's unconsumed numbers, for the test environment only.
    func requestTestNumbers() async throws -> [String] {
        guard mode == .test, let environment else { throw EZZKError.productionAllocationDisabled }
        return try await client(for: environment).evidenceNumbers(for: personProvider())
    }

    static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func client(for environment: EZZKEnvironment) -> EZZKSOAPClient {
        if let client = clients[environment] { return client }
        let store = credentialStore
        let client = EZZKSOAPClient(environment: environment, transport: transport(for: environment),
                                    credentials: { try store.load(environment: environment) },
                                    productionPolicy: productionPolicy)
        clients[environment] = client
        return client
    }

    private func transport(for environment: EZZKEnvironment) -> any EZZKHTTPTransport {
        if let transport = transports[environment] { return transport }
        let transport = transportFactory(environment)
        transports[environment] = transport
        return transport
    }

    private func reloadStoredLogin() {
        guard let environment else {
            storedLogin = ""
            return
        }
        do {
            storedLogin = try credentialStore.load(environment: environment)?.login ?? ""
        } catch {
            // An unreadable Keychain item (an access the person denied, a build Keychain no
            // longer recognises) is said, never shown as a plain "Neprihlásené".
            storedLogin = ""
            state = .failed(Self.message(for: error))
        }
    }
}
