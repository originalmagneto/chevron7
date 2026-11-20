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
    /// Opens a record-first conversion waiting for its clause signature in ZaKo.
    var onFinishPendingConversion: (UUID) -> Void = { _ in }
    @State private var records: [EvidenceRecord] = []
    @State private var filterText = ""
    @State private var statusFilter: EvidenceRecord.Status?
    @State private var environmentFilter: EvidenceRegisterFilter.Environment = .all
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
                            EZZKEnvironmentBadge(mode: record.ezzkMode, form: .list)
                        }
                        .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(min: 130, ideal: 240)

                    TableColumn("Stav") { record in
                        statusCell(record)
                            .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(min: 150, ideal: 230)

                    TableColumn("Smer") { record in
                        let direction = EvidenceRegisterRowPresentation.direction(record.direction)
                        Label(direction.text, systemImage: direction.symbol)
                            .font(.callout)
                            .lineLimit(1)
                            .help(EvidenceRegisterRowPresentation.directionHelp(record.direction))
                            .accessibilityLabel(EvidenceRegisterRowPresentation.directionHelp(record.direction))
                            .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(min: 60, ideal: 70)

                    TableColumn("Výstup") { record in
                        Text(ZakoConversionHeaderModel.outputChip(for: record.clientOutput) ?? "")
                            .font(.callout)
                            .lineLimit(1)
                            .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(min: 80, ideal: 120)

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

                    TableColumn("Lehota EZZK") { record in
                        deadlineLabel(record)
                            .contextMenu { recordContextMenu(for: record) }
                    }
                    .width(min: 110, ideal: 170)
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
            ToolbarItem(placement: .automatic) {
                Picker("Prostredie EZZK", selection: $environmentFilter) {
                    ForEach(EvidenceRegisterFilter.Environment.allCases) { environment in
                        Text(environment.label).tag(environment)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 130, idealWidth: 170)
                .help("Zobraziť konverzie z jedného prostredia EZZK")
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
                                 onFinishPendingConversion: { id in
                                     showDetail = false
                                     selectedRecordID = nil
                                     onFinishPendingConversion(id)
                                 },
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
                        // A conversion waiting for its clause has nothing left to finish.
                        settingsStore.recordFirstPendingStore.remove(id: record.id)
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
        let tiles = EvidenceSummaryTile.tiles(summary: summary, overdue: overdue)
        return HStack(spacing: 12) {
            // Full titles while they fit, then the value alone with the title in the tooltip:
            // never truncated, and the last variant can shrink, so the window's minimum stays.
            ViewThatFits(in: .horizontal) {
                summaryTiles(tiles, compact: false)
                summaryTiles(tiles, compact: true)
            }
            .layoutPriority(1)
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

    private func summaryTiles(_ tiles: [EvidenceSummaryTile], compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            ForEach(tiles) { tile in
                SummaryCard(title: tile.title, value: "\(tile.value)", symbol: tile.symbol,
                            tint: Self.color(for: tile.tint), compact: compact)
                    .help(tile.help)
            }
        }
    }

    static func color(for tint: EvidenceSummaryTile.Tint) -> Color {
        switch tint {
        case .accent: .accentColor
        case .success: .green
        case .attention: .orange
        case .failure: .red
        case .quiet: .secondary
        }
    }

    @ViewBuilder
    private func deadlineLabel(_ record: EvidenceRecord) -> some View {
        if let deadline = EvidenceRegisterDetail.deadline(for: record, now: Date()) {
            Text(deadline.text)
                .font(deadline.tone == .failure ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(Self.tint(for: deadline.tone))
                .lineLimit(1)
                .help(record.status == .late ? EZZKRecordPresentation.lateWarning : deadline.text)
        } else {
            Text("")
        }
    }

    /// The row's state; a conversion waiting for its clause signature offers "Dokončiť" right
    /// there, the same action as the detail footer's "Dokončiť konverziu".
    private func statusCell(_ record: EvidenceRecord) -> some View {
        let row = EvidenceRegisterRowPresentation(record: record,
                                                  pendingStage: settingsStore.recordFirstPendingStore
                                                      .pending(id: record.id)?.stage,
                                                  now: Date())
        return HStack(spacing: 6) {
            Label(row.status.label, systemImage: row.status.symbol)
                .foregroundStyle(Self.tint(for: row.status.tone))
                .lineLimit(1)
                .help(row.status.label)
            if row.canFinish {
                Spacer(minLength: 0)
                Button("Dokončiť") {
                    onFinishPendingConversion(record.id)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help("Otvorí konverziu v Zaručenej konverzii, kde podpíšete doložku s dokumentom pre klienta kartou")
                .accessibilityLabel("Dokončiť konverziu")
            }
        }
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
        EvidenceRegisterFilter.isActive(status: statusFilter, environment: environmentFilter, text: filterText)
    }
    private var filteredRecords: [EvidenceRecord] {
        EvidenceRegisterFilter.apply(records, status: statusFilter, environment: environmentFilter, text: filterText)
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

/// "Uložiť správu o overení…" in the Register: the E→E validation evidence kept in
/// `Evidence/validation/`, unchanged (a qualified service's report keeps its seal).
@MainActor
enum ValidationEvidenceExport {
    static func save(_ record: EvidenceRecord, from store: LocalEvidenceStore,
                     onError: @escaping (String) -> Void) {
        guard let data = store.validationEvidenceData(for: record), let path = record.validationEvidencePath else {
            onError("Správa o overení sa v registri nenašla.")
            return
        }
        let stem = (record.originalName as NSString).deletingPathExtension
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(stem).overenie.\((path as NSString).pathExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                onError("Správu o overení sa nepodarilo uložiť: \(error.localizedDescription)")
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

struct SummaryCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    /// Symbol and value only; the title stays in the accessibility label (and the tooltip).
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Image(systemName: symbol)
                .font(compact ? .callout : .body)
                .foregroundStyle(tint.gradient)
            if compact {
                Text(value)
                    .font(.callout.monospacedDigit().weight(.bold))
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(value)
                        .font(.callout.monospacedDigit().weight(.bold))
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Record Detail Modal Sheet
struct RecordDetailView: View {
    /// Opened at this size, so the status, the submission and the facts show without scrolling;
    /// still resizable down to the minimum, where the overview scrolls.
    static let idealSize = CGSize(width: 720, height: 800)
    static let minimumSize = CGSize(width: 560, height: 400)
    static let padding: CGFloat = 22

    @Bindable var settingsStore: AppSettingsStore
    let recordID: UUID
    var onFinishPendingConversion: (UUID) -> Void = { _ in }
    let onClose: () -> Void
    /// False only in layout tests, which measure the overview's full height.
    var scrollsOverview = true
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
            .labelsHidden()

            if selectedTab == 0 {
                if scrollsOverview {
                    ScrollView { overview(record) }
                } else {
                    overview(record)
                }
            } else {
                attestationPreview(record)
            }

            Spacer(minLength: 0)

            RecordDetailFooter(
                evidenceURI: record.evidenceURI,
                canFinish: EvidenceRegisterRowPresentation.canFinish(
                    pendingStage: settingsStore.recordFirstPendingStore.pending(id: record.id)?.stage),
                canSaveRecord: record.recordContainerPath != nil,
                canSaveValidation: record.validationEvidencePath != nil,
                deleteDisabled: settingsStore.statusChecker.isBusy(record.id),
                onFinish: { onFinishPendingConversion(record.id) },
                onSaveRecord: {
                    actionMessage = nil
                    RecordContainerExport.save(record, from: settingsStore.evidenceStore) { actionMessage = $0 }
                },
                onSaveValidation: {
                    actionMessage = nil
                    ValidationEvidenceExport.save(record, from: settingsStore.evidenceStore) { actionMessage = $0 }
                },
                onDelete: { showDeleteConfirm = true },
                onClose: onClose)
        }
        .padding(Self.padding)
        .frame(minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width, maxWidth: .infinity,
               minHeight: Self.minimumSize.height, idealHeight: scrollsOverview ? Self.idealSize.height : nil,
               maxHeight: .infinity)
        .confirmationDialog("Naozaj chcete vymazať tento záznam?", isPresented: $showDeleteConfirm) {
            Button("Zmazať záznam", role: .destructive) {
                if settingsStore.statusChecker.delete(id: record.id) {
                    settingsStore.recordFirstPendingStore.remove(id: record.id)
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

    private func overview(_ record: EvidenceRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusTimeline(stages: EvidenceRegisterDetail.timeline(for: record)
                .map { (label: $0.label, done: $0.done, failed: $0.failed) })
            submissionCard(record)
            factsGrid(record)
        }
    }

    /// A record-first conversion waiting in the background reads as such, not as its bare row state.
    private func pendingState(_ record: EvidenceRecord) -> RecordFirstPendingPresentation.State? {
        settingsStore.recordFirstPendingStore.pending(id: record.id).flatMap {
            RecordFirstPendingPresentation.state(stage: $0.stage, rowStatus: record.status)
        }
    }

    private func header(_ record: EvidenceRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.originalName)
                .font(.title3.weight(.bold))
            HStack(spacing: 8) {
                if let waiting = pendingState(record) {
                    Label(waiting.label, systemImage: waiting.symbol)
                        .foregroundStyle(EvidenceDashboardView.tint(for: waiting.tone))
                } else {
                    Label(UXLabels.evidenceStatusLabel(for: record.status), systemImage: record.status.sfSymbol)
                        .foregroundStyle(EvidenceDashboardView.tint(for: EZZKRecordPresentation.tone(for: record.status)))
                }
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
            if let output = UXLabels.clientOutputLabel(record.clientOutput) {
                row("Výstup pre klienta", output)
            }
            if let renamed = ZakoSinglePDFDelivery.renamedNotice(for: record) {
                GridRow {
                    Text("Uložený súbor").foregroundStyle(.secondary)
                    Text(renamed)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if record.direction == .electronicToElectronic {
                row("Druh konverzie", "Z elektronickej do elektronickej podoby")
                row("Overenie podpisov", record.validationEvidenceSource ?? "neuložené")
            } else {
                row("Strany / listy / prvky",
                    "\(record.totalPages) strán / \(record.totalSheets) listov / \(record.securityElementCount) prvkov")
            }
            fingerprintRow(record)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
    }

    @ViewBuilder
    private func fingerprintRow(_ record: EvidenceRecord) -> some View {
        let short = String(record.fingerprintSHA256Hex.prefix(24)) + "…"
        GridRow {
            Text(UXLabels.fingerprintLabel(clientOutput: record.clientOutput,
                                           revisionOneLength: record.revisionOneLength))
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

/// The detail sheet's footer: "Zmazať" apart on the left, the save and portal actions in one
/// "Akcie" menu with their full labels, "Dokončiť konverziu" when the conversion waits for
/// its clause signature, and the primary "Zavrieť" on the right. "Overiť v EZZK" stays in the
/// submission card, next to the state it checks and its own waiting rules.
struct RecordDetailFooter: View {
    let evidenceURI: String?
    let canFinish: Bool
    let canSaveRecord: Bool
    let canSaveValidation: Bool
    let deleteDisabled: Bool
    let onFinish: () -> Void
    let onSaveRecord: () -> Void
    let onSaveValidation: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    static let portalURL = URL(string: "https://ezzk.iomo.sk")!

    private var hasActions: Bool { canSaveRecord || canSaveValidation || evidenceURI != nil }

    var body: some View {
        HStack(spacing: 10) {
            Button(role: .destructive, action: onDelete) {
                Label("Zmazať", systemImage: "trash")
            }
            .disabled(deleteDisabled)

            Spacer(minLength: 12)

            if hasActions {
                Menu {
                    if canSaveRecord {
                        Button(action: onSaveRecord) {
                            Label("Uložiť záznam…", systemImage: "square.and.arrow.down")
                        }
                        .help("Uložiť podpísaný záznam o konverzii (ASiC-E), ktorý sa odosiela do EZZK")
                    }
                    if canSaveValidation {
                        Button(action: onSaveValidation) {
                            Label("Uložiť správu o overení…", systemImage: "checkmark.seal")
                        }
                        .help("Uložiť výsledok overenia podpisov pôvodného dokumentu (E→E)")
                    }
                    if let evidenceURI {
                        if canSaveRecord || canSaveValidation { Divider() }
                        Button {
                            openURL(Self.portalURL)
                        } label: {
                            Label("Overiť na portáli CEZZK", systemImage: "safari")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(evidenceURI, forType: .string)
                        } label: {
                            Label("Skopírovať URI záznamu", systemImage: "link")
                        }
                    }
                } label: {
                    Label("Akcie", systemImage: "ellipsis.circle")
                }
                .fixedSize()
                .help("Uložiť záznam alebo správu o overení, overiť na portáli CEZZK")
            }

            if canFinish {
                Button(action: onFinish) {
                    Label("Dokončiť konverziu", systemImage: "signature")
                }
                .help("Otvorí konverziu v Zaručenej konverzii, kde podpíšete doložku s dokumentom pre klienta kartou")
            }

            Button("Zavrieť", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .lineLimit(1)
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
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stage.label + ", " + (stage.failed ? "zlyhalo" : stage.done ? "hotovo" : "čaká"))
            }
        }
        .padding(.vertical, 6)
    }
}
