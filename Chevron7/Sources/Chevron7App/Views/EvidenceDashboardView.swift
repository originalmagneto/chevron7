// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit
import AppKit
import UniformTypeIdentifiers

struct EvidenceDashboardView: View {
    @Bindable var settingsStore: AppSettingsStore
    /// A row another view (the sidebar's "Zaručené konverzie") asks to open; the Register
    /// selects it, opens its detail and clears the request.
    @Binding var requestedRecordID: UUID?
    @State private var records: [EvidenceRecord] = []
    @State private var filterText = ""
    @State private var statusFilter: EvidenceRecord.Status?
    @State private var selectedRecordID: UUID?
    @State private var showDetail = false
    @State private var isSubmitting = false
    @State private var submitFeedback: String?
    @State private var submitSucceeded = false
    @State private var refreshTimer: Timer?
    @State private var recordToDelete: EvidenceRecord?
    @State private var showDeleteConfirmation = false
    @State private var exportError: String?
    @State private var recordSaveError: String?

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
            Divider().opacity(0.5)

            if let loadError = settingsStore.evidenceStore.loadError {
                // Never an empty register over one that could not be read.
                ContentUnavailableView {
                    Label("Register konverzií sa nepodarilo načítať", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(loadError)
                }
            } else if records.isEmpty {
                ContentUnavailableView("Register je prázdny",
                                       systemImage: "archivebox",
                                       description: Text("Po dokončení prvej zaručenej konverzie sa tu zobrazí evidenčný záznam."))
            } else if filteredRecords.isEmpty && hasActiveFilter {
                ContentUnavailableView.search(text: filterText)
            } else {
                Table(filteredRecords, selection: $selectedRecordID) {
                    TableColumn("Evidenčné číslo") { record in
                        HStack(spacing: 6) {
                            if record.isOverdue, record.ezzkMode != .demo { OverdueDot() }
                            Text(record.evidenceNumber ?? "nezískané")
                                .font(.callout.monospacedDigit().weight(.semibold))
                            if record.ezzkMode == .demo { DemoBadge() }
                        }
                        .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(min: 130, ideal: 170)

                    TableColumn("Stav") { record in
                        Label(UXLabels.evidenceStatusLabel(for: record.status, isOverdue: record.isOverdue),
                              systemImage: record.status.sfSymbol)
                            .foregroundStyle(statusTint(record.status))
                            .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(min: 150, ideal: 190)

                    TableColumn("Lehota EZZK") { record in
                        deadlineLabel(record)
                            .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(min: 140, ideal: 220)

                    TableColumn("Dátum konverzie") { record in
                        Text(LocalEvidenceStore.csvDate(record.conversionTime))
                            .font(.caption.monospacedDigit())
                            .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Pôvodný dokument") { record in
                        Text(record.originalName).lineLimit(1)
                            .help(record.originalName)
                            .contextMenu { recordContextMenu(for: record) }
                    }

                    TableColumn("Strany / Listy") { record in
                        Text("\(record.totalPages) / \(record.totalSheets)")
                            .font(.caption.monospacedDigit())
                            .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(90)

                    TableColumn("SHA-256") { record in
                        Text(String(record.fingerprintSHA256Hex.prefix(16)) + "…")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .contextMenu { recordContextMenu(for: record) }
                    }
                }
                .onKeyPress(.return) {
                    guard selectedRecordID != nil else { return .ignored }
                    showDetail = true
                    return .handled
                }
                .onTapGesture(count: 2) {
                    if selectedRecordID != nil { showDetail = true }
                }
            }
        }
        .searchable(text: $filterText, prompt: "Hľadať podľa názvu alebo čísla")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Stav", selection: $statusFilter) {
                    Text("Všetky stavy").tag(EvidenceRecord.Status?.none)
                    ForEach(EvidenceRecord.Status.allCases, id: \.self) { status in
                        Text(status.rawValue).tag(Optional(status))
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 130, idealWidth: 160)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showDetail = true
                } label: {
                    Label("Otvoriť detail", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(selectedRecordID == nil)
                .keyboardShortcut(.defaultAction)
                .help("Otvoriť detail a doložku vybraného záznamu")

                Button {
                    submitPending()
                } label: {
                    HStack(spacing: 5) {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "tray.and.arrow.up")
                        }
                        Text("Odoslať do EZZK")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || settingsStore.evidenceStore.loadError != nil
                          || !records.contains(where: \.isSubmissionPending))
                .help("Odoslať čakajúce záznamy do EZZK; pri neznámom výsledku sa záznam najprv overí v EZZK")

                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up.on.square")
                }
                .help("Exportovať záznamy do CSV")
            }
        }
        .onAppear {
            reload()
            startClock()
            openRequestedRecord()
        }
        .onChange(of: requestedRecordID) { openRequestedRecord() }
        .onDisappear { refreshTimer?.invalidate() }
        // The periodic check, ZaKo and the detail sheet change rows through the checker.
        .onChange(of: settingsStore.statusChecker.changeCount) { reload() }
        .sheet(isPresented: $showDetail) {
            if let record = detailRecord {
                RecordDetailView(settingsStore: settingsStore,
                                 recordID: record.id,
                                 onClose: {
                                     showDetail = false
                                     selectedRecordID = nil
                                     reload()
                                 })
            }
        }
        .confirmationDialog(
            "Naozaj chcete vymazať záznam z evidencie?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Zmazať záznam", role: .destructive) {
                if let record = recordToDelete {
                    if settingsStore.statusChecker.delete(id: record.id) {
                        recordSaveError = nil
                        reload()
                    } else {
                        recordSaveError = EZZKStatusChecker.busyDeleteMessage
                    }
                }
                recordToDelete = nil
            }
            Button("Zrušiť", role: .cancel) {
                recordToDelete = nil
            }
        } message: {
            Text("Tento krok je nevratný. Záznam bude odstránený z lokálneho registra konverzií.")
        }
    }

    @ViewBuilder
    private func recordContextMenu(for record: EvidenceRecord) -> some View {
        Button {
            selectedRecordID = record.id
            showDetail = true
        } label: {
            Label("Zobraziť detail a doložku", systemImage: "doc.text")
        }

        if let evidenceNumber = record.evidenceNumber {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(evidenceNumber, forType: .string)
            } label: {
                Label("Kopírovať evidenčné číslo", systemImage: "doc.on.doc")
            }
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.fingerprintSHA256Hex, forType: .string)
        } label: {
            Label("Kopírovať SHA-256 odtlačok", systemImage: "number.square")
        }

        if record.recordContainerPath != nil {
            Button {
                recordSaveError = nil
                RecordContainerExport.save(record, from: settingsStore.evidenceStore) { recordSaveError = $0 }
            } label: {
                Label("Uložiť záznam…", systemImage: "square.and.arrow.down")
            }
        }

        Divider()

        Button(role: .destructive) {
            recordToDelete = record
            showDeleteConfirmation = true
        } label: {
            Label("Vymazať z evidencie…", systemImage: "trash")
        }
        .disabled(settingsStore.statusChecker.isBusy(record.id))
    }

    private var detailRecord: EvidenceRecord? {
        guard let id = selectedRecordID else { return nil }
        return records.first { $0.id == id }
    }

    private var summaryHeader: some View {
        let summary = EvidenceRegisterSummary(records: records)
        let overdue = records.filter { $0.isOverdue && $0.ezzkMode != .demo }.count
        return HStack(spacing: 12) {
            SummaryCard(title: "Konverzií celkovo", value: "\(summary.total)", symbol: "archivebox", tint: .accentColor)
            SummaryCard(title: "Zapísaných v EZZK", value: "\(summary.sent)", symbol: "checkmark.seal.fill", tint: .green)
            SummaryCard(title: "Čaká na odoslanie", value: "\(summary.pending)", symbol: "tray.and.arrow.up", tint: summary.pending > 0 ? .orange : .secondary)
            SummaryCard(title: "Odmietnuté alebo nepodpísané", value: "\(summary.failed)", symbol: "xmark.seal.fill", tint: summary.failed > 0 ? .red : .secondary)
            SummaryCard(title: "Po lehote 24 h", value: "\(overdue)", symbol: "clock.badge.exclamationmark", tint: overdue > 0 ? .red : .secondary)
            if summary.demo > 0 {
                SummaryCard(title: "Skúšobný režim (mimo EZZK)", value: "\(summary.demo)", symbol: "theatermasks", tint: .secondary)
                    .help("Konverzie v skúšobnom režime sú lokálna simulácia. Do EZZK sa nikdy neodoslali.")
            }
            Spacer()
            if let feedback = submitFeedback {
                Text(feedback)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(submitSucceeded ? Color.green : Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: Capsule())
            }
            if let exportError {
                HStack(spacing: 4) {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Skúsiť znova", action: exportCSV)
                        .buttonStyle(.link)
                }
            }
            if let recordSaveError {
                Text(recordSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func deadlineLabel(_ record: EvidenceRecord) -> some View {
        let deadline = EvidenceRegisterDetail.deadline(for: record, now: Date())
        return Text(deadline.text)
            .font(deadline.tone == .failure ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(Self.tint(for: deadline.tone))
            .lineLimit(2)
            .help(deadline.text)
    }

    static func tint(for tone: EZZKRecordPresentation.Tone) -> Color {
        switch tone {
        case .success: return .green
        case .pending: return .secondary
        case .warning: return .orange
        case .failure: return .red
        }
    }

    private var hasActiveFilter: Bool {
        statusFilter != nil || !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var filteredRecords: [EvidenceRecord] {
        var result = records
        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }
        guard !filterText.isEmpty else { return result }
        let query = filterText.lowercased()
        return result.filter {
            $0.originalName.lowercased().contains(query) ||
            $0.newDocumentName.lowercased().contains(query) ||
            ($0.evidenceNumber ?? "").lowercased().contains(query)
        }
    }

    private func statusTint(_ status: EvidenceRecord.Status) -> Color {
        switch status {
        case .draft, .awaitingNumber, .recordUnsigned: return .secondary
        case .readyToSign: return .blue
        case .signed, .queuedForSubmission, .acceptedForProcessing, .outcomeUnknown, .late: return .orange
        case .submitted, .processed: return .green
        case .submissionFailed, .rejected: return .red
        }
    }

    private func reload() {
        records = settingsStore.evidenceStore.records
    }

    /// Opens the detail of the row the sidebar asked for. The rows are reloaded first,
    /// since the sheet shows only a row in `records`; presenting waits one turn of the
    /// main actor, so a sheet asked for while the Register first appears is not lost.
    private func openRequestedRecord() {
        guard let id = requestedRecordID else { return }
        requestedRecordID = nil
        Task { @MainActor in
            reload()
            guard records.contains(where: { $0.id == id }) else { return }
            selectedRecordID = id
            showDetail = true
        }
    }

    private func startClock() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in reload() }
        }
    }
    /// Every pending row goes through the app's status checker: unknown outcomes are
    /// looked up first and never resent, and nothing is ever marked failed for an error
    /// that may have followed an accepted record.
    private func submitPending() {
        isSubmitting = true
        submitFeedback = nil
        Task {
            let summary = await settingsStore.statusChecker.submitPending()
            reload()
            isSubmitting = false
            submitFeedback = summary.feedback
            submitSucceeded = summary.isSuccess
        }
    }

    private func exportCSV() {
        exportError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "evidencia-konverzii.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(settingsStore.evidenceStore.exportCSV().utf8).write(to: url, options: [.atomic])
            } catch {
                exportError = "Export sa nepodaril: \(error.localizedDescription)"
            }
        }
    }
}

/// "Uložiť záznam…" in the Register: the signed conversion record is kept only in the
/// register (`Evidence/records/<id>.asice`), so the advocate saves a copy from there.
@MainActor
enum RecordContainerExport {
    static func save(_ record: EvidenceRecord, from store: LocalEvidenceStore,
                     onError: @escaping (String) -> Void) {
        guard let stored = EvidenceRegisterDetail.storedRecordContainer(for: record, in: store) else {
            onError(EvidenceRegisterDetail.recordContainerMissingMessage)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "asice") ?? .data]
        panel.nameFieldStringValue = stored.fileName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try stored.data.write(to: url, options: [.atomic])
            } catch {
                onError("Záznam sa nepodarilo uložiť: \(error.localizedDescription)")
            }
        }
    }
}

struct OverdueDot: View {
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .help("Záznam prekročil zákonnú lehotu 24 h na zápis do CEZZK")
    }
}

/// Marks a row made in EZZK Demo mode: its state is a local simulation.
struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.16), in: Capsule())
            .foregroundStyle(.secondary)
            .help("Konverzia v skúšobnom režime: lokálna simulácia, do EZZK sa neodoslala.")
            .accessibilityLabel("DEMO: skúšobný režim, mimo EZZK")
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.bold))
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Record Detail Modal Sheet
struct RecordDetailView: View {
    @Bindable var settingsStore: AppSettingsStore
    let recordID: UUID
    let onClose: () -> Void
    @State private var copiedFingerprint = false
    @State private var showDeleteConfirm = false
    @State private var showResendConfirm = false
    @State private var selectedTab = 0
    @State private var isWorking = false
    @State private var actionMessage: String?

    /// Read from the register on every draw; the checker's change count redraws the sheet
    /// when a send, a lookup or the periodic check changes the row.
    private var record: EvidenceRecord? {
        _ = settingsStore.statusChecker.changeCount
        return settingsStore.evidenceStore.record(id: recordID)
    }

    var body: some View {
        if let record {
            content(record)
        } else {
            VStack {
                ContentUnavailableView("Záznam sa v Registri nenašiel", systemImage: "archivebox")
                Button("Zavrieť") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(22)
            .frame(minWidth: 320, minHeight: 200)
        }
    }

    private func content(_ record: EvidenceRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(record)

            Picker("Časť detailu záznamu", selection: $selectedTab) {
                Text("Prehľad záznamu").tag(0)
                Text("Záznam o konverzii (XML)").tag(1)
            }
            .pickerStyle(.segmented)

            if selectedTab == 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        StatusTimeline(stages: EvidenceRegisterDetail.timeline(for: record)
                            .map { (label: $0.label, done: $0.done, failed: $0.failed) })
                        submissionCard(record)
                        factsGrid(record)
                    }
                }
            } else {
                attestationPreview(record)
            }

            Spacer(minLength: 0)

            HStack {
                if let uri = record.evidenceURI {
                    Link(destination: URL(string: "https://ezzk.iomo.sk")!) {
                        Label("Overiť na portáli CEZZK", systemImage: "safari")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(uri, forType: .string)
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skopírovať URI záznamu")
                    .help("Skopírovať URI záznamu (\(uri))")
                }

                Spacer()

                if record.recordContainerPath != nil {
                    Button {
                        actionMessage = nil
                        RecordContainerExport.save(record, from: settingsStore.evidenceStore) { actionMessage = $0 }
                    } label: {
                        Label("Uložiť záznam…", systemImage: "square.and.arrow.down")
                    }
                    .help("Uložiť podpísaný záznam o konverzii (ASiC-E), ktorý sa odosiela do EZZK")
                }

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Zmazať", systemImage: "trash")
                }
                .disabled(settingsStore.statusChecker.isBusy(record.id))

                Button("Zavrieť") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 320, idealWidth: 600, maxWidth: .infinity,
               minHeight: 400, idealHeight: 600, maxHeight: .infinity)
        .confirmationDialog("Naozaj chcete vymazať tento záznam?", isPresented: $showDeleteConfirm) {
            Button("Zmazať záznam", role: .destructive) {
                if settingsStore.statusChecker.delete(id: record.id) {
                    onClose()
                } else {
                    actionMessage = EZZKStatusChecker.busyDeleteMessage
                }
            }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Záznam bude natrvalo odstránený z lokálnej evidencie.")
        }
    }

    private func header(_ record: EvidenceRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.originalName)
                .font(.title3.weight(.bold))
            HStack(spacing: 8) {
                Label(UXLabels.evidenceStatusLabel(for: record.status), systemImage: record.status.sfSymbol)
                    .foregroundStyle(EvidenceDashboardView.tint(for: EZZKRecordPresentation.tone(for: record.status)))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(LocalEvidenceStore.csvDate(record.conversionTime))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// State, submission facts, what the row needs and the "Odoslať" / "Overiť v EZZK" actions.
    private func submissionCard(_ record: EvidenceRecord) -> some View {
        let actions = EvidenceRegisterDetail.actions(for: record,
                                                     currentMode: settingsStore.ezzkAccountController.mode,
                                                     productionAllowed: settingsStore.ezzkAccountController
                                                         .productionPolicy.allowsConsequentialCalls)
        let explanation = EZZKRecordPresentation.stateExplanation(for: record)
            .filter { $0 != actions.note && $0 != record.ezzkResultDescription }
        let nextCheck = settingsStore.statusChecker.nextStatusCheck(for: record)
        let verifyWaitsUntil = record.status == .outcomeUnknown ? nextCheck.flatMap { $0 > Date() ? $0 : nil } : nil
        return VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(EvidenceRegisterDetail.submissionFacts(for: record), id: \.label) { fact in
                    GridRow {
                        Text(fact.label).foregroundStyle(.secondary)
                        Text(fact.value).textSelection(.enabled)
                    }
                }
            }
            ForEach(explanation + [actions.note].compactMap { $0 }, id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(EvidenceDashboardView.tint(for: EZZKRecordPresentation.tone(for: record.status)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let verifyWaitsUntil {
                Text("Overiť v EZZK bude možné od \(EZZKRecordPresentation.timeText(verifyWaitsUntil)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if actions.canSend || actions.canVerify {
                HStack(spacing: 10) {
                    if actions.canSend {
                        Button {
                            run { await settingsStore.statusChecker.submit(id: record.id) }
                        } label: {
                            Label("Odoslať", systemImage: "tray.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if actions.canVerify {
                        Button {
                            run { await settingsStore.statusChecker.verify(id: record.id) }
                        } label: {
                            Label("Overiť v EZZK", systemImage: "magnifyingglass")
                        }
                        .disabled(verifyWaitsUntil != nil)
                    }
                    if isWorking { ProgressView().controlSize(.small) }
                }
                .disabled(isWorking)
            }
            if actions.canResend {
                HStack(spacing: 10) {
                    Button {
                        showResendConfirm = true
                    } label: {
                        Label("Odoslať znova", systemImage: "arrow.clockwise")
                    }
                    if isWorking { ProgressView().controlSize(.small) }
                }
                .disabled(isWorking)
                .confirmationDialog(actions.resendConfirmation ?? "Odoslať záznam znova?",
                                    isPresented: $showResendConfirm, titleVisibility: .visible) {
                    Button("Odoslať znova") {
                        run { await settingsStore.statusChecker.resend(id: record.id) }
                    }
                    Button("Zrušiť", role: .cancel) {}
                }
            }
            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
    }

    private func run(_ action: @escaping () async -> EZZKStatusChecker.RowResult) {
        isWorking = true
        actionMessage = nil
        Task {
            let result = await action()
            // A refusal (another mode, a row in flight) says why; a changed row speaks for itself.
            actionMessage = result.refusal
            isWorking = false
        }
    }

    private func factsGrid(_ record: EvidenceRecord) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Evidenčné číslo", record.evidenceNumber ?? "nezískané")
            row("Osvedčujúca osoba", record.performingPersonName.isEmpty ? "neurčená" : record.performingPersonName)
            row("Nový dokument", record.newDocumentName)
            row("Strany / listy / prvky",
                "\(record.totalPages) strán / \(record.totalSheets) listov / \(record.securityElementCount) prvkov")
            fingerprintRow(record)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
    }

    @ViewBuilder
    private func fingerprintRow(_ record: EvidenceRecord) -> some View {
        let short = String(record.fingerprintSHA256Hex.prefix(24)) + "…"
        GridRow {
            Text("SHA-256 odtlačok")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(short)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.fingerprintSHA256Hex, forType: .string)
                    copiedFingerprint = true
                } label: {
                    Image(systemName: copiedFingerprint ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skopírovať SHA-256 odtlačok")
                .help("Skopírovať otlačok")
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func attestationPreview(_ record: EvidenceRecord) -> some View {
        GroupBox("Záznam o konverzii (XML dáta)") {
            ScrollView {
                Text(record.attestationXML)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 240)
        }
    }
}

struct StatusTimeline: View {
    let stages: [(label: String, done: Bool, failed: Bool)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                if index > 0 {
                    Rectangle()
                        .fill(stage.done ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(height: 2)
                }
                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(stage.done ? Color.accentColor : Color.primary.opacity(0.06))
                            .strokeBorder(stage.done ? Color.clear : Color.primary.opacity(0.2), lineWidth: 1)
                            .frame(width: 22, height: 22)
                        Image(systemName: stage.failed ? "xmark" :
                                (stage.done ? "checkmark" : "circle"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(stage.done ? .white : .secondary)
                    }
                    Text(stage.label)
                        .font(.caption2)
                        .foregroundStyle(stage.done ? .primary : .secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
