// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Chevron7Kit

struct RootView: View {
    enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
        case signing = "Podpisovanie"
        case zako = "Zaručená konverzia"
        case evidence = "Register konverzií"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .signing: return "signature"
            case .zako: return "building.columns.fill"
            case .evidence: return "archivebox.fill"
            }
        }
    }

    @Bindable var model: Chevron7AppModel
    @State private var selection: SidebarSection = .signing
    @State private var queueItemToDelete: UUID?
    @State private var showQueueDeleteConfirmation = false
    @AppStorage("sidebar.signedDocumentsExpanded") private var signedDocumentsExpanded = true
    @AppStorage("sidebar.recentDocumentsExpanded") private var recentDocumentsExpanded = true
    @AppStorage("sidebar.conversionsExpanded") private var conversionsExpanded = true
    /// A register row the sidebar asked the Register to open; the Register clears it.
    @State private var requestedEvidenceRecordID: UUID?
    @State private var showAllSignedDocuments = false
    @State private var showAllRecentDocuments = false
    @State private var showRegisterLoadError = false
    @State private var showSignedClearDialog = false

    /// Rows shown per history section before "Zobraziť všetky".
    private static let sidebarPreviewCount = 5

    init(model: Chevron7AppModel) {
        self._model = Bindable(wrappedValue: model)
    }

    private var settingsStore: AppSettingsStore { model.settingsStore }
    private var recentDocumentStore: RecentDocumentStore { model.recentDocumentStore }
    private var signedDocumentStore: SignedDocumentStore { model.signedDocumentStore }

    /// One signed document: what it was, where it came from and whether a copy
    /// was kept. A browser signature can legitimately have no file, so the row
    /// says so instead of offering a dead link.
    @ViewBuilder
    private func signedDocumentRow(_ entry: SignedDocumentStore.SignedDocument) -> some View {
        let isAvailable = entry.isAvailable
        Button {
            guard let url = entry.url, isAvailable else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: entry.method.sfSymbol)
                        .foregroundStyle(.secondary)
                        .frame(width: SidebarMetrics.iconWidth)
                    Text(entry.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.callout)
                }
                HStack(spacing: 6) {
                    Text(entry.origin.label)
                    Text("·")
                    Text(entry.method.label)
                    Text("·")
                    Text(entry.levelLabel)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, SidebarMetrics.iconWidth + 8)

                if !entry.wasSavedLocally {
                    Text("Neuložené lokálne")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, SidebarMetrics.iconWidth + 8)
                } else if !isAvailable {
                    Text("Súbor už neexistuje")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, SidebarMetrics.iconWidth + 8)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel("Podpísaný dokument \(entry.displayName)")
        .accessibilityValue("\(entry.origin.label), \(entry.method.label)")
        .contextMenu {
            if isAvailable, let url = entry.url {
                Button {
                    selection = .signing
                    Task { await signingStore.addFurtherSignature(to: url) }
                } label: {
                    Label("Pridať ďalší podpis", systemImage: "signature")
                }
                .disabled(!signingStore.canAddFurtherSignature)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Zobraziť vo Finderi", systemImage: "folder")
                }
            }
            Button {
                signedDocumentStore.remove(id: entry.id, trashingFile: false)
            } label: {
                Label("Odstrániť zo zoznamu", systemImage: "xmark.circle")
            }
            if isAvailable {
                Button(role: .destructive) {
                    signedDocumentStore.remove(id: entry.id, trashingFile: true)
                } label: {
                    Label("Odstrániť aj súbor (do Koša)", systemImage: "trash")
                }
            }
        }
    }

    /// Header of a collapsible history section with its own actions menu, so the
    /// clean-up is found without knowing about the header's context menu.
    private func historyHeader(_ title: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer(minLength: 0)
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Akcie pre \(title)")
        }
    }

    /// The newest register rows. `LocalEvidenceStore` is not observable, so the body reads
    /// the two signals that follow a register write: the status checker's change count
    /// (sends, lookups, the periodic check, deletions) and ZaKo's step (a new row is
    /// written straight to the register and the flow then reaches its last step).
    private var conversionSection: SidebarConversionRows.Section {
        _ = settingsStore.statusChecker.changeCount
        _ = zakoStore.step
        return SidebarConversionRows.section(from: settingsStore.evidenceStore.records, now: Date())
    }

    /// One conversion: its name, then its evidence number and EZZK state. Opens the row's
    /// detail in the Register.
    private func conversionRow(_ row: SidebarConversionRows.Row) -> some View {
        Button {
            openInRegister(row.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The EZZK state leads the row: it is what the advocate scans for.
                Image(systemName: row.symbol)
                    .foregroundStyle(EvidenceDashboardView.tint(for: row.tone))
                    .frame(width: SidebarMetrics.iconWidth)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.evidenceNumber)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.name): \(row.stateLabel)")
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Otvorí detail v Registri konverzií")
        .contextMenu {
            Button {
                openInRegister(row.id)
            } label: {
                Label("Zobraziť detail a doložku", systemImage: "doc.text")
            }
        }
    }

    /// Switches to the Register and, for a row, asks it to open that row's detail.
    private func openInRegister(_ id: UUID?) {
        selection = .evidence
        requestedEvidenceRecordID = id
    }

    private func showMoreButton(total: Int, isShowingAll: Binding<Bool>) -> some View {
        Button {
            isShowingAll.wrappedValue.toggle()
        } label: {
            Text(isShowingAll.wrappedValue ? "Zobraziť menej" : "Zobraziť všetky (\(total))")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .padding(.leading, SidebarMetrics.iconWidth + 8)
    }

    private var signingStore: SigningSessionStore { model.signingStore }

    private var batchIsActive: Bool {
        signingStore.batchPhase == .preflighting
            || signingStore.batchPhase == .ready
            || signingStore.batchPhase == .signing
    }
    private var zakoStore: ZakoSessionStore { model.zakoStore }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Kancelária") {
                    Label(SidebarSection.signing.rawValue, systemImage: SidebarSection.signing.symbol)
                        .tag(SidebarSection.signing)

                    Label(SidebarSection.zako.rawValue, systemImage: SidebarSection.zako.symbol)
                        .tag(SidebarSection.zako)

                    Label(SidebarSection.evidence.rawValue, systemImage: SidebarSection.evidence.symbol)
                        .tag(SidebarSection.evidence)
                }

                if !signedDocumentStore.entries.isEmpty {
                    let signed = signedDocumentStore.entries
                    Section(isExpanded: $signedDocumentsExpanded) {
                        ForEach(showAllSignedDocuments ? signed : Array(signed.prefix(Self.sidebarPreviewCount))) { entry in
                            signedDocumentRow(entry)
                        }
                        if signed.count > Self.sidebarPreviewCount {
                            showMoreButton(total: signed.count, isShowingAll: $showAllSignedDocuments)
                        }
                    } header: {
                        historyHeader("Podpísané dokumenty") {
                            Button("Vyčistiť…", systemImage: "trash") {
                                showSignedClearDialog = true
                            }
                        }
                    }
                }

                let conversions = conversionSection
                if !conversions.isEmpty {
                    Section(isExpanded: $conversionsExpanded) {
                        ForEach(conversions.rows) { row in
                            conversionRow(row)
                        }
                        if conversions.hasMore {
                            Button {
                                openInRegister(nil)
                            } label: {
                                Text("Zobraziť všetky (\(conversions.total))")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, SidebarMetrics.iconWidth + 8)
                            .accessibilityHint("Otvorí Register konverzií")
                        }
                    } header: {
                        historyHeader("Zaručené konverzie") {
                            Button("Otvoriť Register konverzií", systemImage: SidebarSection.evidence.symbol) {
                                openInRegister(nil)
                            }
                        }
                    }
                }

                if recentDocumentStore.isEnabled && !recentDocumentStore.entries.isEmpty {
                    let recent = recentDocumentStore.entries
                    Section(isExpanded: $recentDocumentsExpanded) {
                        ForEach(showAllRecentDocuments ? recent : Array(recent.prefix(Self.sidebarPreviewCount))) { entry in
                            let isAvailable = recentDocumentStore.isAvailable(entry)
                            Button {
                                guard isAvailable else { return }
                                openRecent(entry)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isAvailable ? "clock.arrow.circlepath" : "doc.badge.ellipsis")
                                        .foregroundStyle(.secondary)
                                        .frame(width: SidebarMetrics.iconWidth)
                                    Text(entry.displayName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .font(.callout)
                                    if !isAvailable {
                                        Spacer(minLength: 0)
                                        Text("Nedostupný")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!isAvailable)
                            .accessibilityLabel("Nedávny dokument \(entry.displayName)")
                            .accessibilityValue(isAvailable ? "Dostupný" : "Nedostupný")
                            .contextMenu {
                                Button(role: .destructive) {
                                    recentDocumentStore.remove(id: entry.id)
                                } label: {
                                    Label("Odstrániť z nedávnych", systemImage: "xmark.circle")
                                }
                            }
                        }
                        if recent.count > Self.sidebarPreviewCount {
                            showMoreButton(total: recent.count, isShowingAll: $showAllRecentDocuments)
                        }
                    } header: {
                        historyHeader("Nedávne dokumenty") {
                            Button("Vymazať zoznam", systemImage: "trash", role: .destructive) {
                                recentDocumentStore.clear()
                            }
                        }
                    }
                }


                if !signingStore.queue.isEmpty {
                    Section("Fronta podpisovania (\(signingStore.queue.count))") {
                        ForEach(signingStore.queue) { item in
                            let isSelected = signingStore.selectedQueueID == item.id
                            Button {
                                selection = .signing
                                Task { await signingStore.selectQueueItem(item.id) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: queueIcon(item.status))
                                        .foregroundStyle(queueColor(item.status))
                                        .frame(width: SidebarMetrics.iconWidth)
                                    Text(item.displayName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .font(.callout)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dokument \(item.displayName)")
                            .accessibilityValue("\(queueStatusLabel(item.status)); \(isSelected ? "Vybraný" : "Nevybraný")")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .padding(.vertical, 2)
                            .listRowBackground(
                                isSelected
                                    ? Color.primary.opacity(0.08)
                                    : Color.clear
                            )
                            .contextMenu {
                                Button {
                                    selection = .signing
                                    Task { await signingStore.selectQueueItem(item.id) }
                                } label: {
                                    Label("Vybrať na podpis", systemImage: "signature")
                                }
                                if let outputURL = item.signedOutputURL {
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                    } label: {
                                        Label("Ukázať vo Finderi", systemImage: "folder")
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    queueItemToDelete = item.id
                                    showQueueDeleteConfirmation = true
                                } label: {
                                    Label("Odstrániť z fronty", systemImage: "xmark.circle")
                                }
                                .disabled(batchIsActive)
                            }
                        }

                        if signingStore.unsignedQueueItems.count > 1 {
                            Button {
                                selection = .signing
                                let ids = signingStore.unsignedQueueItems.map(\.id)
                                Task { await signingStore.prepareBatch(ids: ids) }
                            } label: {
                                Label("Podpísať všetky (\(signingStore.unsignedQueueItems.count))",
                                      systemImage: "signature.badge.checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(batchIsActive)
                            .padding(.top, 4)
                            .accessibilityLabel("Pripraviť dávku podpisov")
                            .accessibilityValue(
                                batchIsActive
                                    ? "Dávka už prebieha"
                                    : "\(signingStore.unsignedQueueItems.count) dokumentov"
                            )
                        }
                    }
                }

            }
            .listStyle(.sidebar)
            .navigationTitle("Chevron7")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            .safeAreaInset(edge: .bottom) {
                // An opaque bar: without it the list scrolled underneath and the
                // document names ran through the reader status.
                sidebarBottomBar
                    .background(.regularMaterial)
            }
            .task(id: settingsStore.settings.webSigningRetentionDays) {
                signedDocumentStore.purgeBrowserCopies(olderThanDays: settingsStore.settings.webSigningRetentionDays)
            }
            // The reader badge and the signing store follow one poll, only while this
            // window exists and the app is active; activation refreshes at once.
            .task { await model.cardReader.watch() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.cardReader.refresh() }
            }
        } detail: {
            detailView
                .navigationTitle(selection.rawValue)
                .navigationSubtitle(subtitle)
        }
        .focusedValue(\.chevron7CommandActions, Chevron7CommandActions(
            openDocument: openDocument,
            addFiles: openMoreFiles,
            toggleSidebar: toggleSidebar,
            recentDocuments: recentDocumentStore.isEnabled ? recentDocumentStore.entries : [],
            openRecent: openRecent,
            clearRecent: { recentDocumentStore.clear() }))
        .confirmationDialog(
            "Naozaj chcete odstrániť dokument z fronty?",
            isPresented: $showQueueDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Odstrániť z fronty", role: .destructive) {
                if let id = queueItemToDelete { signingStore.removeQueueItem(id) }
                queueItemToDelete = nil
            }
            Button("Zrušiť", role: .cancel) { queueItemToDelete = nil }
        } message: {
            Text("Dokument zostane v pôvodnom umiestnení; odstráni sa iba z fronty podpisovania.")
        }
        .confirmationDialog(
            "Vyčistiť podpísané dokumenty?",
            isPresented: $showSignedClearDialog,
            titleVisibility: .visible
        ) {
            Button("Vyčistiť iba zoznam") {
                signedDocumentStore.clear(trashingFiles: false)
            }
            Button("Vyčistiť a presunúť súbory do Koša", role: .destructive) {
                signedDocumentStore.clear(trashingFiles: true)
            }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Súbory presunuté do Koša sa dajú obnoviť, kým Kôš nevysypete.")
        }
        // An unreadable register is the legal record of evidence numbers already used, so
        // the advocate hears about it at launch instead of seeing an empty Register.
        .onAppear {
            if settingsStore.evidenceStore.loadError != nil { showRegisterLoadError = true }
        }
        .alert("Register konverzií sa nepodarilo načítať", isPresented: $showRegisterLoadError) {
            Button("Otvoriť Register konverzií") { selection = .evidence }
            Button("OK", role: .cancel) {}
        } message: {
            Text(settingsStore.evidenceStore.loadError ?? "")
        }
    }

    private var sidebarBottomBar: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.5)

            VStack(alignment: .leading, spacing: 10) {
                let badge = SmartcardBadge(
                    section: selection,
                    reader: model.cardReader.identities,
                    signingSelectedID: signingStore.selectedIdentityID,
                    zakoSelectedID: zakoStore.selectedIdentityID,
                    isDemo: settingsStore.signingProvider is DemoSigningProvider,
                    missingDriver: model.cardReader.missingDriver)

                SmartcardHUDStatus(
                    isConnected: badge.isConnected,
                    label: badge.label,
                    detail: badge.detail,
                    needsDriver: badge.needsDriver,
                    drivers: badge.drivers
                )

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        openMoreFiles()
                    } label: {
                        sidebarFooterLabel("Pridať súbory…", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    OpenSettingsButton {
                        sidebarFooterLabel("Nastavenia", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Nastavenia")
                    .help("Otvoriť nastavenia")
                }

                DonateButton()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// A footer action with its icon in the same fixed-width column as every other
    /// sidebar icon, so the labels line up.
    private func sidebarFooterLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .frame(width: SidebarMetrics.iconWidth)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        switch selection {
        case .signing:
            let mode = settingsStore.signingProvider is DemoSigningProvider ? "demo" : "KEP"
            switch signingStore.step {
            case .intake:
                return "výber dokumentu · \(mode)"
            case .prepare:
                return "nastavenie podpisu · \(mode)"
            case .done:
                return "podpísané · \(mode)"
            }
        case .zako:
            switch zakoStore.step {
            case .intake:
                return "vstupný dokument"
            case .analysis:
                return "krok 2 z 5: overenie originálu"
            case .attestation:
                return "krok 3 z 5: osvedčovacia doložka"
            case .authorize:
                return "krok 4 z 5: autorizácia KEP"
            case .done:
                return "krok 5 z 5: hotovo"
            }
        case .evidence:
            return "register konverzií a CEZZK"
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .signing:
            SigningFlowView(store: signingStore)
        case .zako:
            ZakoFlowView(store: zakoStore)
        case .evidence:
            EvidenceDashboardView(settingsStore: settingsStore,
                                  requestedRecordID: $requestedEvidenceRecordID)
        }
    }

    private func queueIcon(_ status: SigningSessionStore.SigningQueueItem.Status) -> String {
        switch status {
        case .ready: "doc.richtext"
        case .signing: "hourglass"
        case .signed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
    private func queueStatusLabel(_ status: SigningSessionStore.SigningQueueItem.Status) -> String {
        switch status {
        case .ready: "Pripravené"
        case .signing: "Podpisuje sa"
        case .signed: "Podpísané"
        case .failed: "Podpis zlyhal"
        }
    }

    private func queueColor(_ status: SigningSessionStore.SigningQueueItem.Status) -> Color {
        switch status {
        case .ready: .secondary
        case .signing: .orange
        case .signed: .green
        case .failed: .red
        }
    }

    /// Opens a recent document in the signing flow, where it was recorded.
    private func openRecent(_ entry: RecentDocumentStore.RecentDocument) {
        guard recentDocumentStore.isAvailable(entry) else { return }
        selection = .signing
        Task {
            await recentDocumentStore.withResolvedURL(entry) { resolvedURL in
                await signingStore.loadDocument(at: resolvedURL)
            }
        }
    }

    private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, UTType(importedAs: "org.autogram.asice", conformingTo: .data)]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                selection = .signing
                await signingStore.loadDocument(at: url)
            }
        }
    }

    private func openMoreFiles() {
        guard !batchIsActive else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, UTType(importedAs: "org.autogram.asice", conformingTo: .data)]
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                selection = .signing
                let urls = panel.urls
                if urls.count == 1 {
                    await signingStore.addDocuments(at: urls, selectLast: true)
                } else {
                    await prepareReviewedBatch(for: urls)
                }
            }
        }
    }

    private func prepareReviewedBatch(for urls: [URL]) async {
        guard !batchIsActive else { return }
        await signingStore.addDocuments(at: urls, selectLast: false)
        let selectedURLs = Set(urls.map(\.standardizedFileURL))
        let ids = signingStore.queue
            .filter {
                selectedURLs.contains($0.url.standardizedFileURL)
                    && ($0.status == .ready || $0.status == .failed)
            }
            .map(\.id)
        await signingStore.prepareBatch(ids: ids)
    }

    private func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }
}


/// Shared sidebar measurements, so section rows and footer actions align.
enum SidebarMetrics {
    static let iconWidth: CGFloat = 18
}

/// The voluntary contribution link: a small button in Buy Me a Coffee's own yellow, so it
/// is recognisable and findable without competing with the navigation above it.
private struct DonateButton: View {
    @State private var isHovering = false

    /// The official button image when the app bundle carries it; SwiftPM test and
    /// preview builds do not, and fall back to the drawn yellow button below.
    private static let officialButton: NSImage? = Bundle.main
        .url(forResource: SidebarDonateLink.buttonImageName, withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let image = Self.officialButton {
            Button {
                NSWorkspace.shared.open(SidebarDonateLink.url)
            } label: {
                // The image carries the brand yellow itself, so centring it on a bar of the
                // same yellow widens the button to the sidebar without stretching the logo.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(yellow)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(ink.opacity(isHovering ? 0.35 : 0.12))
                    )
                    // Without the group the shadow is drawn for each layer, and the logo's
                    // own shadow outlines it as a smaller box inside the bar.
                    .compositingGroup()
                    // Hover lifts the whole button and keeps the brand yellow: any tint over
                    // it reads as grey.
                    .shadow(color: .black.opacity(isHovering ? 0.22 : 0.06), radius: isHovering ? 4 : 1.5, y: isHovering ? 2 : 1)
                    .scaleEffect(isHovering ? 1.015 : 1)
                    .animation(.easeOut(duration: 0.12), value: isHovering)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(SidebarDonateLink.accessibilityLabel)
            .help(SidebarDonateLink.help)
        } else {
            drawnButton
        }
    }

    private var drawnButton: some View {
        Button {
            NSWorkspace.shared.open(SidebarDonateLink.url)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: SidebarDonateLink.symbol)
                    .font(.callout.weight(.semibold))
                Text(SidebarDonateLink.title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .opacity(isHovering ? 0.9 : 0.45)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(yellow.opacity(isHovering ? 1 : 0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(ink.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(SidebarDonateLink.accessibilityLabel)
        .help(SidebarDonateLink.help)
    }

    private var yellow: Color {
        let c = SidebarDonateLink.brandYellow
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    private var ink: Color {
        let c = SidebarDonateLink.brandInk
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }
}
