// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import SwiftUI
import Chevron7Kit

@MainActor
@Observable
final class AppSettingsStore {
    var settings: AppSettings {
        didSet {
            settings.save(to: defaults)
        }
    }

    let ezzkAccountController: EZZKAccountController
    var ezzkService: any EZZKServicing {
        ezzkAccountController.service
    }
    private(set) var signingProvider: any QualifiedSigningProviding
    let evidenceStore: LocalEvidenceStore
    let evidenceNumberPool: EvidenceNumberPool
    /// Sends and checks register rows for ZaKo, the Register and the periodic check, one
    /// action per row at a time. The app model starts its five-minute check at launch.
    let statusChecker: EZZKStatusChecker
    let exampleBank: ExampleBank
    /// Root for every file the app keeps: evidence register, vision bank, output,
    /// templates and signature images.
    let storageRoot: URL
    /// Where `settings` is loaded from and saved to.
    private let defaults: UserDefaults

    /// Tests pass a controller with in-memory credentials and a scripted transport, a
    /// temporary `storageRoot` so they never read or write the user's real evidence register,
    /// and a `MemoryUserDefaults` so one test's saved settings never reach another test.
    init(ezzkAccountController: EZZKAccountController? = nil,
         storageRoot: URL = ProductIdentity.applicationSupportDirectory(),
         defaults: UserDefaults = .standard) {
        let loaded = AppSettings.load(defaults: defaults)
        self.defaults = defaults
        self.settings = loaded
        self.storageRoot = storageRoot
        let controller = ezzkAccountController ?? EZZKAccountController(mode: loaded.ezzkMode)
        self.ezzkAccountController = controller
        // LocalEvidenceStore.init appends its own "Evidence" folder to whatever
        // directory it is given, so pass storageRoot itself here. EvidenceNumberPool
        // follows the same convention.
        let evidenceStore = LocalEvidenceStore(directory: storageRoot)
        let numberPool = EvidenceNumberPool(directory: storageRoot)
        self.evidenceStore = evidenceStore
        self.evidenceNumberPool = numberPool
        self.statusChecker = EZZKStatusChecker(evidenceStore: evidenceStore, numberPool: numberPool,
                                               controller: controller)
        self.exampleBank = ExampleBank(directory: Self.exampleBankDirectory(in: storageRoot))
        self.signingProvider = SigningProviderFactory.makeDefault()
        self.ezzkAccountController.configure(
            person: { [weak self] in
                guard let self else { return EZZKPerson(corporateBodyFullName: "", ico: "") }
                return EZZKPerson(corporateBodyFullName: settings.ezzkPersonName, ico: settings.ezzkICO)
            },
            usedEvidenceNumbers: { [weak self] mode in
                EvidenceRecord.usedEvidenceNumbers(in: self?.evidenceStore.records ?? [], mode: mode)
            })
    }

    /// Numbers asked for from Settings join the pool ZaKo draws from. EZZK holds each one
    /// until a record uses it, so a number kept only on screen would make the next
    /// conversion's request fail with code 113.
    func requestTestNumbersIntoPool() async throws -> [String] {
        let controller = ezzkAccountController
        let mode = controller.mode
        let numbers = try await controller.requestTestNumbers()
        let allocatedAt = (try? await controller.service(for: mode).serverTime()) ?? Date()
        for number in numbers {
            evidenceNumberPool.add(EvidenceNumberPool.Entry(number: number, mode: mode, allocatedAt: allocatedAt))
        }
        return numbers
    }

    func useRealSigningProvider(_ provider: any QualifiedSigningProviding) {
        signingProvider = provider
    }

    var exampleBankDirectory: URL { Self.exampleBankDirectory(in: storageRoot) }
    /// Fallback for signed and converted files when the source folder is not writable.
    var outputDirectory: URL { storageRoot.appendingPathComponent("Output", isDirectory: true) }
    var templatesDirectory: URL { storageRoot.appendingPathComponent("Templates", isDirectory: true) }
    var signaturesDirectory: URL { storageRoot.appendingPathComponent("Signatures", isDirectory: true) }

    private nonisolated static func exampleBankDirectory(in root: URL) -> URL {
        root.appendingPathComponent("VisionBank", isDirectory: true)
    }
}
