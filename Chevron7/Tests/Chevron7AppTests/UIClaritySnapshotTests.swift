// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
@testable import Chevron7Kit
import Chevron7TestSupport
import SwiftUI
import XCTest
@testable import Chevron7App

/// Renders the screens of the ZaKo UI clarity work to PNG for a visual review: the E→E
/// authorize step under the conversion header, the record-first done step and its timeline,
/// the register and its detail sheet, the E→E verification, the detector training overview,
/// the AI pane's bank counts and the signature banner's rows. Runs only when
/// `CHEVRON7_SNAPSHOT_DIR` names an output folder; otherwise every test is skipped. Every
/// store lives in a temporary folder with in-memory defaults and credentials; all names and
/// numbers are synthetic.
@MainActor
final class UIClaritySnapshotTests: XCTestCase {
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["CHEVRON7_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static let mainSize = NSSize(width: 1200, height: 800)

    private func requireOutput() throws -> URL {
        guard let outputDirectory else { throw XCTSkip("Set CHEVRON7_SNAPSHOT_DIR to render the screens.") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return outputDirectory
    }

    // MARK: 1. E→E authorize step

    func testRenderAuthorizeStep() async throws {
        let output = try requireOutput()
        let store = try await makeE2EStore(identities: [
            SigningIdentityInfo(id: "card", label: "Ján Testovací (eID)", issuerSummary: "Disig Qualified CA 2026",
                                isMandateCertificate: false, isQualified: true)
        ])
        store.readMandateCardState = { .noMandate(labels: ["Ján Testovací (eID)"]) }
        store.attestation.originalDocumentTypeLabel = "Zmluva"
        store.step = .authorize
        await store.refreshIdentities()
        for scheme in Scheme.allCases {
            render(ZakoFlowView(store: store), named: "1a-authorize-no-mandate", scheme: scheme, to: output)
        }

        store.cardPrompt = .checkingCard
        render(ZakoFlowView(store: store), named: "1b-authorize-checking-card", scheme: .light, to: output)
        store.cardPrompt = nil
    }

    // MARK: 2. Record-first done step

    func testRenderRecordFirstDoneStates() async throws {
        let output = try requireOutput()
        let settingsStore = makeSettingsStore(ezzkAccountController: signedInController())
        let store = ZakoSessionStore(settingsStore: settingsStore,
                                     exampleBank: ExampleBank(directory: makeTemporaryDirectory("clarity-done-bank")))
        store.sourceNameOverride = "Zmluva o diele.pdf"
        store.attestation.evidenceNumber = "261120-TEST000001"
        store.attestation.evidenceNumberMode = .test
        let signedAt = Date().addingTimeInterval(-7 * 60)
        let id = store.currentRecordID

        var row = record(id: id, name: "Zmluva o diele.pdf", number: "261120-TEST000001", mode: .test,
                         status: .acceptedForProcessing, recordFirst: true, created: signedAt)
        row.submittedAt = signedAt.addingTimeInterval(20)
        settingsStore.evidenceStore.upsert(row)
        store.attachRecordFirstPending(pending(id: id, attestation: store.attestation, stage: .awaitingEZZK,
                                               signedAt: signedAt))
        store.step = .done
        for scheme in Scheme.allCases {
            render(ZakoFlowView(store: store), named: "2a-done-waiting-for-ezzk", scheme: scheme, to: output)
        }

        row.status = .processed
        row.ezzkResultCode = 1
        row.ezzkResultDescription = "Záznam o konverzii bol úspešne spracovaný"
        row.lastLookupAt = Date().addingTimeInterval(-60)
        settingsStore.evidenceStore.upsert(row)
        store.attachRecordFirstPending(pending(id: id, attestation: store.attestation, stage: .signingClientContainer,
                                               signedAt: signedAt))
        render(ZakoFlowView(store: store), named: "2b-done-ready-for-clause", scheme: .light, to: output)

        store.discardRecordFirstPending()
        row.deliveredFileName = "Zmluva o diele.asice"
        settingsStore.evidenceStore.upsert(row)
        store.outputDirectory = makeTemporaryDirectory("clarity-output")
        render(ZakoFlowView(store: store), named: "2c-done-delivered", scheme: .light, to: output)
    }

    // MARK: 3. Register and its detail sheet

    func testRenderRegister() async throws {
        let output = try requireOutput()
        let settingsStore = makeSettingsStore()
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        var rows: [EvidenceRecord] = []
        var a = record(name: "Zmluva o diele.pdf", number: "261120-PROD000014", mode: .production,
                       status: .processed, recordFirst: false, created: ago(2))
        a.submittedAt = ago(1.9)
        rows.append(a)
        var b = record(name: "Kúpna zmluva - byt.asice", number: "261120-TEST000001", mode: .test,
                       status: .processed, recordFirst: true, created: ago(1), direction: .electronicToElectronic,
                       output: .singlePDF)
        b.submittedAt = ago(0.9)
        rows.append(b)
        var c = record(name: "Plnomocenstvo.pdf", number: "261120-TEST000002", mode: .test,
                       status: .acceptedForProcessing, recordFirst: true, created: ago(0.2))
        c.submittedAt = ago(0.19)
        rows.append(c)
        rows.append(record(name: "Výpis z účtu.pdf", number: "DEMO-261120-3", mode: .demo,
                           status: .processed, recordFirst: false, created: ago(5)))
        rows.append(record(name: "Nájomná zmluva.pdf", number: "261118-PROD000009", mode: .production,
                           status: .submissionFailed, recordFirst: false, created: ago(30)))
        var f = record(name: "Darovacia zmluva.asice", number: "261119-TEST000007", mode: .test,
                       status: .rejected, recordFirst: false, created: ago(20), direction: .electronicToElectronic)
        f.ezzkResultCode = 214
        f.ezzkResultDescription = "Záznam nie je v súlade s XSD schémou"
        rows.append(f)
        rows.append(record(name: "Uznesenie valného zhromaždenia.pdf", number: "261117-PROD000003", mode: .production,
                           status: .submitted, recordFirst: false, created: ago(70), output: .singlePDF))
        rows.append(record(name: "Zápisnica.pdf", number: "DEMO-261120-4", mode: .demo,
                           status: .acceptedForProcessing, recordFirst: true, created: ago(3),
                           direction: .electronicToElectronic))
        for row in rows { settingsStore.evidenceStore.upsert(row) }
        let attestation = ZakoSessionStore(settingsStore: settingsStore,
                                           exampleBank: ExampleBank(directory: makeTemporaryDirectory("clarity-register-bank")))
            .attestation
        try settingsStore.recordFirstPendingStore.save(pending(id: b.id, attestation: attestation,
                                                              stage: .signingClientContainer, signedAt: b.createdAt,
                                                              direction: .electronicToElectronic, output: .singlePDF))
        try settingsStore.recordFirstPendingStore.save(pending(id: c.id, attestation: attestation,
                                                              stage: .awaitingEZZK, signedAt: c.createdAt))

        for scheme in Scheme.allCases {
            render(EvidenceDashboardView(settingsStore: settingsStore, requestedRecordID: .constant(nil)),
                   named: "3a-register", scheme: scheme, to: output)
        }
        let detailSize = NSSize(width: RecordDetailView.idealSize.width, height: RecordDetailView.idealSize.height)
        for scheme in Scheme.allCases {
            render(RecordDetailView(settingsStore: settingsStore, recordID: b.id, onClose: {}),
                   named: "3b-record-detail-ready-for-clause", scheme: scheme, to: output, size: detailSize)
        }
        render(RecordDetailView(settingsStore: settingsStore, recordID: f.id, onClose: {}),
               named: "3c-record-detail-rejected", scheme: .light, to: output, size: detailSize)
    }

    // MARK: 4. E→E verification

    func testRenderVerification() async throws {
        let output = try requireOutput()
        let store = try await makeE2EStore(identities: [])
        for scheme in Scheme.allCases {
            render(ZakoFlowView(store: store), named: "4-verification", scheme: scheme, to: output)
        }
    }

    // MARK: 5. Detector training and the AI pane's counts

    func testRenderDetectorTraining() async throws {
        let output = try requireOutput()
        let settingsStore = makeSettingsStore()
        settingsStore.settings.learnFromReviews = true
        let kinds: [SecurityElement.Kind] = [.officialStamp, .handwrittenSignature, .initial, .embossedSeal]
        for index in 0..<22 {
            let kind = kinds[index % kinds.count]
            let boxes = (0..<(index % 3 + 1)).map { _ in
                ReviewedPageBox(kind: kind, box: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.1))
            }
            try await settingsStore.exampleBank.saveReviewedPage(
                ReviewedBankPage(documentSHA256: "fake-doc-\(index % 5)", pageIndex: index, boxes: boxes,
                                 reviewedAt: Date(), detectorVersion: "snapshot"))
        }
        let size = NSSize(width: 680, height: 600)
        // The window itself, as the app opens it. Its report loads in a `.task` whose main-actor
        // continuations cannot run inside `RunLoop.main.run` (this test is itself a main-actor
        // job), so this render yields with `Task.sleep` instead of spinning the run loop.
        await renderYielding(DetectorTrainingView(settingsStore: settingsStore),
                             named: "5a0-detector-training-window", scheme: .light, to: output, size: size)

        // The same chrome around the overview built from the same pages, so the overview
        // renders whether or not the window's own load finished in the snapshot.
        let report = DetectorTrainingReadiness.report(
            pages: try await settingsStore.exampleBank.reviewedPages(), lastRunAt: nil, learnOn: true,
            offersEnabled: true, snoozedUntil: nil)
        let overview = DetectorTrainingOverview.make(report: report, trainedBefore: false, learnOn: true,
                                                     offersEnabled: true, snoozedUntil: nil)
        let window = VStack(spacing: 0) {
            FlowStepBar(steps: [("Prehľad", "chart.bar"), ("Odhad", "clock"), ("Trénovanie", "cpu"),
                                ("Výsledok", "checkmark.seal")], currentStepIndex: 0)
                .padding(.top, 8)
            ScrollView {
                DetectorTrainingOverviewView(overview: overview, onImport: {})
                    .padding(20)
            }
            StickyActionBar {
                Spacer()
                if let reason = overview.continueBlockedReason {
                    Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                Button("Pokračovať") {}.buttonStyle(.borderedProminent).disabled(overview.continueBlockedReason != nil)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        for scheme in Scheme.allCases {
            render(window, named: "5a-detector-training-overview", scheme: scheme, to: output, size: size)
        }

        let counts: [BankLabel: Int] = [
            .kind(.officialStamp): 34, .kind(.handwrittenSignature): 51, .kind(.embossedSeal): 3,
            .kind(.initial): 12, .kind(.watermark): 2, .kind(.lamination): 1, .negative: 27
        ]
        let grid = Form {
            Section {
                Toggle("Učiť sa z potvrdených a odmietnutých prvkov", isOn: .constant(true))
                LearningBankCountsGrid(counts: counts)
            } header: {
                Label("Učenie", systemImage: "graduationcap")
            }
        }
        .formStyle(.grouped)
        for scheme in Scheme.allCases {
            render(grid, named: "5b-ai-bank-counts", scheme: scheme, to: output, size: NSSize(width: 560, height: 300))
        }
    }

    // MARK: 6. Signature banner rows

    func testRenderSignatureBannerRows() throws {
        let output = try requireOutput()
        let rows = [
            SignatureBannerModel.Row(id: "S-1", title: "Ján Klient", verdict: .valid, badges: ["KEP"],
                                     verdictLabel: "Platný", detail: "Podpísané 18. 11. 2026 09:12 · PAdES",
                                     reason: nil,
                                     dataTimestamp: "Časová pečiatka údajov: Belgium BOSA, kvalifikovaná · 18. 11. 2026 09:12:03",
                                     timestamp: "Časová pečiatka podpisu: Sectigo Qualified, kvalifikovaná · 18. 11. 2026 09:12:05",
                                     warning: nil, depth: 0, isNew: true),
            SignatureBannerModel.Row(id: "S-2", title: "Mária Testovacia", verdict: .indeterminate,
                                     badges: ["Kvalifikácia neurčená"], verdictLabel: "Neurčitý",
                                     detail: "Podpísané 17. 11. 2026 15:40 · PAdES",
                                     reason: "Stav zrušenia certifikátu sa nepodarilo overiť.",
                                     dataTimestamp: nil, timestamp: nil, warning: nil, depth: 0, isNew: false),
            SignatureBannerModel.Row(id: "S-3", title: "Peter Neplatný", verdict: .invalid, badges: ["Nekvalifikovaný"],
                                     verdictLabel: "Neplatný", detail: "Podpísané 16. 11. 2026 08:00 · XAdES",
                                     reason: "Dokument bol po podpísaní zmenený.",
                                     dataTimestamp: nil, timestamp: nil, warning: nil, depth: 0, isNew: false),
        ]
        let bubble = VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                SignatureRowView(model: SignatureRowModel(row), density: .compact)
                if row.id != rows.last?.id { Divider() }
            }
        }
        .padding(12)
        .frame(width: 500, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        for scheme in Scheme.allCases {
            render(bubble, named: "6-banner-rows-compact", scheme: scheme, to: output,
                   size: NSSize(width: 500, height: 280))
        }
    }

    // MARK: Fixtures

    private enum Scheme: CaseIterable {
        case light, dark
        var suffix: String { self == .light ? "light" : "dark" }
        var appearance: NSAppearance? { NSAppearance(named: self == .light ? .aqua : .darkAqua) }
    }

    /// Testovacia evidencia with a saved (in-memory) login, so nothing asks to sign in.
    private func signedInController() -> EZZKAccountController {
        let credentials = MemoryCredentialStore()
        try? credentials.save(EZZKSOAPCredentials(login: "test-ucet", password: "test-heslo"), environment: .sandbox)
        return EZZKAccountController(mode: .test, credentialStore: credentials,
                                     transportFactory: { _ in ScriptedTransport([]) }, productionPolicy: .refused)
    }

    /// An E→E store loaded with a signed PDF of two signatures: the client's, valid with a
    /// timestamp and the SAK mandate, and a second signer's.
    private func makeE2EStore(identities: [SigningIdentityInfo]) async throws -> ZakoSessionStore {
        let settingsStore = makeSettingsStore(ezzkAccountController: signedInController())
        let profile = AdvocateProfile(fullName: "Mgr. Ján Testovací", position: "advokát", registrationNumber: "9999",
                                      ico: "12345678", officeName: "Advokátska kancelária Testovací")
        settingsStore.settings.profiles = [profile]
        settingsStore.settings.activeProfileID = profile.id
        let directory = makeTemporaryDirectory("clarity-e2e")
        let a4 = CGSize(width: 595, height: 842)
        let data = TestPDFBuilderApp.build(pages: [
            (a4, { ctx, size in
                TestPDFBuilderApp.text("Zmluva o diele", at: CGPoint(x: 60, y: size.height - 90), size: 18)(ctx, size)
            })
        ])
        let source = directory.appendingPathComponent("Zmluva o diele.pdf")
        try data.write(to: source)
        var client = E2EEvidenceFixtures.Signature()
        client.signer = "Ján Klient"
        client.mandate = "advokát"
        client.signedRevisionLength = data.count
        var other = E2EEvidenceFixtures.Signature()
        other.id = "S-2"
        other.signer = "Mária Zhotoviteľka"
        other.signingTime = "2026-10-11T10:02:00Z"
        other.signatureValue = Data("signature-value-2".utf8)
        other.timestamps = []
        other.signedRevisionLength = data.count
        var facts = E2EEvidenceFixtures.PDF()
        facts.declaredPdfaPart = 2
        facts.pdfaCompliant = true
        let provider = ClaritySnapshotProvider(
            payload: E2EEvidenceFixtures.payload(signatures: [client, other], pdf: facts), identities: identities)
        settingsStore.useRealSigningProvider(provider)
        let store = ZakoSessionStore(settingsStore: settingsStore,
                                     exampleBank: ExampleBank(directory: makeTemporaryDirectory("clarity-e2e-bank")))
        store.readMandateCardState = { .noCard }
        store.direction = .electronicToElectronic
        await store.loadElectronicOriginal(at: source)
        return store
    }

    private func record(id: UUID = UUID(), name: String, number: String, mode: AppSettings.EZZKMode,
                        status: EvidenceRecord.Status, recordFirst: Bool, created: Date,
                        direction: ConversionDirection = .paperToElectronic,
                        output: AppSettings.ZakoClientOutput = .asicContainer) -> EvidenceRecord {
        let stem = (name as NSString).deletingPathExtension
        let pack: ConversionFormPack
        if direction == .electronicToElectronic {
            pack = recordFirst ? FormPackRepository.e2eRecord12Unverified : FormPackRepository.e2eRecord10Unverified
        } else {
            pack = recordFirst ? FormPackRepository.record12Unverified : FormPackRepository.currentLegacyUnverified
        }
        return EvidenceRecord(id: id, createdAt: created, status: status, direction: direction, originalName: name,
                              newDocumentName: stem + ".pdf", evidenceNumber: number,
                              fingerprintSHA256Hex: String(repeating: "ab", count: 32), attestationXML: "<x/>",
                              conversionTime: created, performingPersonName: "Mgr. Ján Testovací",
                              securityElementCount: direction == .paperToElectronic ? 3 : 0,
                              totalPages: 4, totalSheets: 2, formPack: FormPackStamp(pack: pack), ezzkMode: mode,
                              evidenceNumberAllocatedAt: created,
                              recordContainerPath: "records/\(id.uuidString).asice", clientOutput: output)
    }

    private func pending(id: UUID, attestation: AttestationData, stage: RecordFirstPending.Stage, signedAt: Date,
                         direction: ConversionDirection = .paperToElectronic,
                         output: AppSettings.ZakoClientOutput = .asicContainer) -> RecordFirstPending {
        var pending = RecordFirstPending(
            recordID: id, stage: stage, direction: direction,
            originalFingerprints: direction == .electronicToElectronic ? [Data(repeating: 1, count: 32)] : nil,
            mode: .test, evidenceNumber: "261120-TEST000001", conversionTime: signedAt,
            finalPDF: Data("%PDF-1.7\n".utf8), fingerprint: "00", containerDocumentName: "Zmluva o diele.pdf",
            containerFiles: [], directory: FileManager.default.temporaryDirectory,
            stampsSignatures: false, timestampServers: nil, tsaURL: nil, attestation: attestation,
            clientOutput: output, appendedClause: nil, fixedTarget: nil,
            clientTimestampServers: nil, clientTSAURL: nil)
        pending.recordSignedAt = signedAt
        return pending
    }

    /// `render`, but settling by suspending the test, so the view's own `.task` work can finish.
    private func renderYielding<V: View>(_ view: V, named name: String, scheme: Scheme, to directory: URL,
                                         size: NSSize, settle: Duration = .seconds(2)) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = scheme.appearance
        host.appearance = scheme.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: settle)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        scheme.appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        let url = directory.appendingPathComponent("\(name)-\(scheme.suffix).png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
        window.close()
    }

    private func render<V: View>(_ view: V, named name: String, scheme: Scheme, to directory: URL,
                                 size: NSSize = UIClaritySnapshotTests.mainSize, settle: TimeInterval = 0.5) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = scheme.appearance
        host.appearance = scheme.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        scheme.appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        let url = directory.appendingPathComponent("\(name)-\(scheme.suffix).png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
        window.close()
    }
}

private final class ClaritySnapshotProvider: QualifiedSigningProviding, @unchecked Sendable {
    let payload: Data
    let identities: [SigningIdentityInfo]
    init(payload: Data, identities: [SigningIdentityInfo]) {
        self.payload = payload
        self.identities = identities
    }
    func availableIdentities() async -> [SigningIdentityInfo] { identities }
    func conversionEvidence(for fileURL: URL) async throws -> ConversionEvidence {
        try ConversionEvidence.decode(payloadJSON: payload)
    }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        try await DemoSigningProvider().sign(request)
    }
}
