// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit
import AppKit
import UniformTypeIdentifiers

/// How the authorize step shows `lastError`. Every message there is a failure: a record-first
/// conversion still waiting for EZZK goes to the done step and is finished later from the
/// notification, the sidebar or the Register, never through this notice.
struct AuthorizeNoticePresentation: Equatable {
    let title: String
    let message: String
    let tone: ZakoNotice.Tone

    init(message: String) {
        title = "Konverziu sa nepodarilo autorizovať"
        self.message = message
        tone = .failure
    }
}

struct AuthorizeView: View {
    @Bindable var store: ZakoSessionStore
    @State private var showsMetChecklistItems = false
    @State private var previewCache = ZakoPagePreviewCache()

    /// Authorizing, or a card flow that may go on to sign: the step's other controls stay off.
    private var isBusy: Bool { store.isAuthorizing || store.isCardFlowActive }

    var body: some View {
        VStack(spacing: 0) {
            // The measured area decides the layout, never the content: a wide and tall window
            // gets the page and the client's files beside the certificate, anything smaller
            // the one scrolling column, so the step's minimum size stays where it was.
            GeometryReader { geometry in
                if let preview = previewImage,
                   let columns = ZakoAuthorizeLayout.columns(for: geometry.size,
                                                             pageAspect: preview.size.width / preview.size.height) {
                    HStack(spacing: 0) {
                        previewColumn(preview, columns: columns)
                            .frame(width: columns.previewWidth)
                        Divider()
                        ScrollView {
                            detailsColumn
                                .padding(ZakoAuthorizeLayout.padding)
                        }
                        .frame(width: columns.detailsWidth)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        singleColumn
                            .padding(20)
                    }
                }
            }

            StickyActionBar {
                // A conversion opened from the store has no form on screen to go back to.
                if !store.isLoadedPendingConversion {
                    Button {
                        store.step = .attestation
                    } label: {
                        Label("Späť na doložku", systemImage: "chevron.left")
                    }
                    .controlSize(.large)
                    .disabled(isBusy)
                }

                Spacer()

                mobileAuthorizeButton
                if store.cardPrompt == .checkingCard {
                    // The card check runs inline; the PIN and the card prompts stay sheets.
                    Button("Zrušiť", role: .cancel) { store.cancelCardFlow() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                }
                VStack(alignment: .trailing, spacing: 4) {
                    authorizeButton
                    // Width-bound under the button and at most two lines: squeezed into the bar's
                    // row at the window's narrowest, a note that may grow vertically wrapped word
                    // by word and raised the window's minimum height (582 points). It truncates
                    // instead there, with the whole text in the help tag.
                    if let note = authorizeButtonNote {
                        Label(note.text, systemImage: note.symbol)
                            .font(.caption)
                            .foregroundStyle(note.isRefusal ? Color.orange : Color.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: 320, alignment: .trailing)
                            .help(note.text)
                    }
                }
            }
        }
        .sheet(isPresented: Bindable(store.mobileSigning).isPresented) {
            if let session = store.mobileSigning.session {
                MobileSigningSheet(session: session) { store.mobileSigning.cancel() }
                    .interactiveDismissDisabled()
            }
        }
        .task { await store.refreshIdentities() }
        .task(id: store.signingPIN) {
            guard !store.signingProviderIsDemo, !store.signingPIN.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await store.refreshIdentities()
        }
    }

    /// The first page of what will be signed, or nil when there is nothing to show.
    private var previewImage: NSImage? {
        previewCache.previewDocument(for: store).flatMap { previewCache.firstPage(of: $0) }
    }

    /// Errors and refusals first: they say why "Autorizovať" is off.
    @ViewBuilder
    private var leadingNotices: some View {
        Label("Pred autorizáciou: kontrolný zoznam", systemImage: "checklist")
            .font(.headline)

        tokenStatusRow

        if let error = store.lastError {
            let notice = AuthorizeNoticePresentation(message: error)
            ZakoNotice(title: notice.title, message: notice.message, tone: notice.tone)
        }

        if let signedOut = store.ezzkSignInRefusal {
            VStack(alignment: .leading, spacing: 8) {
                ZakoNotice(title: "Nie ste prihlásený do EZZK", message: signedOut, tone: .warning)
                OpenSettingsButton(pane: .ezzk) {
                    Label("Otvoriť nastavenia EZZK", systemImage: "gearshape")
                }
            }
        }
    }

    @ViewBuilder
    private var trailingNotices: some View {
        if store.rasterConversionOffered, !store.rasterConversionApproved {
            Button {
                store.rasterConversionApproved = true
                store.lastError = nil
            } label: {
                Label("Použiť rastrový PDF/A", systemImage: "photo.on.rectangle")
            }
            .help("Strany sa uložia ako obrázky v PDF/A-2b; text sa nebude dať označiť. Potom znova autorizujte.")
            .disabled(isBusy)
        }

        if !store.validationErrors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(store.validationErrors.enumerated()), id: \.offset) { _, err in
                    Text("• \(err.errorDescription ?? "")")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// A small or short window: everything in one column, the two cards side by side when
    /// they fit.
    private var singleColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            leadingNotices
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    checklistCard
                    certificateCard
                }
                VStack(alignment: .leading, spacing: 14) {
                    checklistCard
                    certificateCard
                }
            }
            trailingNotices
        }
    }

    /// Beside the preview: the certificate and the output first (they are chosen here), then
    /// the checklist.
    private var detailsColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            leadingNotices
            certificateCard
            checklistCard
            trailingNotices
        }
    }

    /// "Čo podpíšete": the page and the client's files, beside the page when there is room.
    private func previewColumn(_ image: NSImage, columns: ZakoAuthorizeLayout.Columns) -> some View {
        let page = ZakoPagePreview(image: image, accessibilityLabel: store.deliveryPreviewCaption)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let caption = Text(store.deliveryPreviewCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        let plan = ZakoDeliveryPlanView(plan: store.deliveryPlan)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Čo podpíšete", systemImage: "signature")
                .font(.headline)
                .frame(height: ZakoAuthorizeLayout.headingHeight - 12, alignment: .leading)
            if columns.planBesidePage {
                HStack(alignment: .top, spacing: ZakoAuthorizeLayout.planGap) {
                    page
                    VStack(alignment: .leading, spacing: 16) {
                        caption
                        plan
                    }
                    .frame(width: ZakoAuthorizeLayout.planWidth, alignment: .topLeading)
                }
            } else {
                page
                caption
                plan
            }
        }
        .padding(ZakoAuthorizeLayout.padding)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tokenStatusRow: some View {
        let status = store.tokenStatus
        return Label(status.text, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(status.isWarning ? Color.orange : (status.isReady ? Color.green : Color.secondary))
    }

    private func checklistRow(_ item: ZakoChecklistItem) -> some View {
        let marker = ChecklistMarker(met: item.met, blocksBeforeCard: item.blocksBeforeCard)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: marker.symbol)
                .foregroundStyle(marker.color)
            Image(systemName: item.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = item.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(marker.accessibilityValue)
    }

    @ViewBuilder
    private var checklistCard: some View {
        if store.isLoadedPendingConversion, let pending = store.recordFirstPending {
            loadedConversionCard(pending)
        } else {
            formChecklistCard
        }
    }

    /// A conversion opened from the store: its document and form are not on screen, so the
    /// card says what will be signed instead of checking the form again.
    private func loadedConversionCard(_ pending: RecordFirstPending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Čakajúca konverzia")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Label(RecordFirstPendingPresentation.documentName(pending), systemImage: "doc.text")
                .font(.callout.weight(.semibold))
            Label("Evidenčné číslo \(pending.evidenceNumber)", systemImage: "number")
                .font(.callout)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let timeline = store.conversionTimeline(now: context.date) {
                    ZakoConversionTimelineView(timeline: timeline, compact: true)
                        .padding(.vertical, 2)
                }
            }
            Text(pending.clientOutput == .singlePDF
                 ? "Podpíše sa uložená doložka pripojená k dokumentu v jednom PDF (\(pending.containerDocumentName))."
                 : "Podpíše sa uložená doložka s dokumentom \(pending.containerDocumentName) v kontajneri ASiC-E.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Výstup sa uloží do priečinka \(pending.directory.path).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(padding: 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var formChecklistCard: some View {
        let checklist = store.authorizeChecklist
        return VStack(alignment: .leading, spacing: 10) {
            Text("Zákonné náležitosti doložky")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            // What is still missing leads; the met items fold into one row.
            ForEach(checklist.unmet) { item in
                checklistRow(item)
            }
            if !checklist.met.isEmpty {
                DisclosureGroup(isExpanded: $showsMetChecklistItems) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(checklist.met) { item in
                            checklistRow(item)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label(checklist.foldedTitle, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(checklist.allMet ? Color.green : Color.primary)
                        .accessibilityLabel("\(checklist.foldedTitle) z kontrolného zoznamu")
                }
            }
            if store.direction == .electronicToElectronic {
                EmptyView()
            } else if let banner = SignatureBannerModel.make(from: store.inputSignatureInspection) {
                SignatureBanner(model: banner)
            } else {
                Text(store.inputSignatureInspection.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Detail overenia vstupných podpisov")
                    .accessibilityValue(store.inputSignatureInspection.detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(padding: 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var certificateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Podpisový certifikát pre autorizáciu")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if store.identities.isEmpty {
                ProgressView("Vyhľadávam certifikáty…")
                    .controlSize(.small)
            } else {
                ForEach(store.identities) { identity in
                    IdentityRow(identity: identity,
                               isSelected: store.selectedIdentityID == identity.id,
                               onSelect: { store.selectedIdentityID = identity.id })
                        .disabled(isBusy)
                }
            }

            if store.isResolvingCertificate {
                ProgressView("Načítavam certifikáty z karty…")
                    .controlSize(.small)
            }

            if let error = store.certificateLoadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.signingProviderIsDemo {
                Label(authorizationCardHint, systemImage: "key.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Here, not in the action bar: squeezed between the buttons this text wrapped
            // word by word and grew the window past the screen, hiding "Autorizovať".
            if store.showsMobileOutsideDemoNotice {
                Label(ZakoSessionStore.mobileOutsideDemoMessage, systemImage: "iphone.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let mobileRefusal = store.mobileButtonRefusalNote {
                Label(mobileRefusal, systemImage: "iphone.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Výstup pre klienta") {
                    Picker("Výstup pre klienta", selection: clientOutputSelection) {
                        ForEach(AppSettings.ZakoClientOutput.allCases, id: \.self) { output in
                            Text(UXLabels.clientOutputLabel(output) ?? "").tag(output)
                                .selectionDisabled(output == .singlePDF && store.singlePDFProductionRefusal != nil)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(isBusy || store.recordFirstPending != nil)
                }
                // Ostrá evidencia does not run the one PDF yet: said here, before any card step.
                if let refusal = store.singlePDFProductionRefusal, store.recordFirstPending == nil {
                    Label(refusal, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(store.settings.zakoClientOutput == .singlePDF ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.settings.zakoClientOutput == .singlePDF {
                    Text("Jeden PDF, ktorého súčasťou je osvedčovacia doložka ako príloha XML a ako posledné strany (§ 37 ods. 4 zákona č. 305/2013 Z. z., § 2 ods. 3 vyhlášky č. 70/2021 Z. z.). Vhodné napríklad pre Obchodný register, ktorý neprijíma kontajnery s viacerými súbormi.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if store.showsQualifiedTimestampToggle {
                // With the engine the card always timestamps, so the Demo switch shows on and locked.
                let timestampLocked = store.signingProvider.alwaysAddsQualifiedTimestamp
                Toggle(isOn: timestampLocked ? .constant(true) : $store.includeQualifiedTimestamp) {
                    Label("Kvalifikovaná časová pečiatka (QTS)", systemImage: "clock.badge.checkmark")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(timestampLocked || isBusy)
            }

            if store.requiresMandateOverride {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Zvolený certifikát nie je mandátnym certifikátom pre zaručenú konverziu.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Toggle(isOn: Binding(
                        get: { store.hasValidMandateOverride },
                        set: { store.setMandateOverride($0) })) {
                        Text("Rozumiem: pokračovať s ne-mandátnym certifikátom")
                            .font(.caption2)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(padding: 14)
        .frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity, alignment: .topLeading)
    }

    /// The output picker's selection: the one PDF cannot be chosen while Ostrá evidencia refuses
    /// it, and a selection already on it can always switch back to the container.
    private var clientOutputSelection: Binding<AppSettings.ZakoClientOutput> {
        Binding(
            get: { store.settings.zakoClientOutput },
            set: { output in
                if output == .singlePDF, store.singlePDFProductionRefusal != nil { return }
                store.settingsStore.settings.zakoClientOutput = output
            })
    }

    private var authorizationCardHint: String {
        if let pending = store.recordFirstPending {
            return pending.stage == .awaitingEZZK
                ? "Záznam o konverzii č. \(pending.evidenceNumber) je podpísaný a odoslaný do EZZK. Keď ho EZZK spracuje, podpíše sa doložka s dokumentom."
                : "EZZK spracovalo záznam č. \(pending.evidenceNumber). Podržte Dokončiť konverziu: podpíše sa doložka s dokumentom pre klienta."
        }
        return switch store.mandateGate {
        case .ready(let label) where store.hasResolvedCertificate:
            "Podpíše sa mandátnym certifikátom \(label)."
        case .noMandate:
            ZakoSessionStore.noMandateMessage
        default:
            "Podržte Autorizovať: aplikácia skontroluje kartu, vyžiada PIN alebo BOK a načíta mandátny certifikát."
        }
    }

    @ViewBuilder
    private var authorizeButton: some View {
        HoldToConfirmButton(
            title: store.recordFirstPending == nil ? "Autorizovať konverziu" : "Dokončiť konverziu",
            systemImage: ZakoSessionStore.authorizeButtonSymbol,
            workingText: store.cardPrompt == .checkingCard ? "Kontrolujem kartu…" : store.analysisProgressText,
            disabled: store.isAuthorizing || store.isResolvingCertificate || store.cardPrompt != nil
                || store.pendingCardAction != nil || !store.canBeginAuthorization,
            isWorking: store.isAuthorizing || store.cardPrompt == .checkingCard
        ) {
            Task { await store.beginAuthorization() }
        }
    }

    private var authorizeButtonNote: ZakoAuthorizeNote? { store.authorizeButtonNote }

    @ViewBuilder
    private var mobileAuthorizeButton: some View {
        if store.isMobileSigningAvailable, store.direction != .electronicToElectronic {
            Button {
                Task { await store.authorizeAndSign(viaMobile: true) }
            } label: {
                HStack(spacing: 8) {
                    if store.isAuthorizing, store.isAuthorizingViaMobile {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: ZakoSessionStore.mobileAuthorizeButtonSymbol)
                    }
                    Text("Autorizovať mobilom")
                        .font(.body.weight(.semibold))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isBusy || !store.isMobilePreflightComplete || store.recordFirstPending != nil
                || store.mobileRefusalForClientOutput != nil)
            .help(store.mobileRefusalForClientOutput
                  ?? "Vyžaduje mandátny certifikát na občianskom preukaze. Bez neho sa konverzia odmietne.")
            .accessibilityHint(store.mobileRefusalForClientOutput ?? "")
        }
    }
}

/// The mark in front of a checklist item: green when met, an orange warning for an unmet item
/// that stops the authorization before the card (the EZZK login), a dashed circle otherwise.
enum ChecklistMarker: Equatable {
    case met
    case blocking
    case pending

    init(met: Bool, blocksBeforeCard: Bool) {
        self = met ? .met : (blocksBeforeCard ? .blocking : .pending)
    }

    var symbol: String {
        switch self {
        case .met: "checkmark.circle.fill"
        case .blocking: "exclamationmark.triangle.fill"
        case .pending: "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .met: .green
        case .blocking: .orange
        case .pending: .secondary
        }
    }

    var accessibilityValue: String {
        switch self {
        case .met: "splnené"
        case .blocking: "chýba, bráni autorizácii"
        case .pending: "nesplnené"
        }
    }
}

// MARK: - Identity Row Component
struct IdentityRow: View {
    let identity: SigningIdentityInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text(identity.issuerSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !identity.hasPrivateKey {
                        Text("vyžaduje PIN/BOK na karte")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if identity.isMandateCertificate {
                    badge("MANDÁTNY", tint: .green)
                }
                if identity.isQualified {
                    badge("QCP", tint: .blue)
                } else if !identity.id.hasPrefix("demo") {
                    badge("KOMERČNÝ", tint: .orange)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(isSelected ? Color.accentColor.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Certifikát \(identity.label)")
        .accessibilityValue("\(identity.issuerSummary); \(isSelected ? "Vybraný" : "Nevybraný")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Step 5: Done View for ZaKo
struct DoneView: View {
    let store: ZakoSessionStore
    @State private var exportError: String?
    @State private var isWorkingOnEZZK = false
    @State private var previewCache = ZakoPagePreviewCache()

    /// The content's widest extent, and the width from which the summary sits beside the status.
    static let maxContentWidth: CGFloat = 980
    static let twoColumnMinWidth: CGFloat = 860
    static let summaryWidth: CGFloat = 340

    var body: some View {
        // In a scroll view at least as tall as the window: the content starts at the top, and
        // its height at the narrowest width no longer sets the window's minimum. Without it the
        // waiting card's wrapped texts asked for about 3000 points and grew the main window
        // past the screen (F16, 2026-11-20).
        GeometryReader { geometry in
            ScrollView {
                content(twoColumns: geometry.size.width >= Self.twoColumnMinWidth)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
        }
    }

    private func content(twoColumns: Bool) -> some View {
        VStack(spacing: 20) {
            if twoColumns, let summary = summaryModel {
                HStack(alignment: .top, spacing: 24) {
                    statusColumn
                        .frame(maxWidth: .infinity, alignment: .top)
                    summaryCard(summary)
                        .frame(width: Self.summaryWidth)
                }
            } else {
                statusColumn
                if let summary = summaryModel {
                    summaryCard(summary)
                        .frame(maxWidth: 520)
                }
            }

            DetectorTrainingOfferBanner(settingsStore: store.settingsStore)
                .frame(maxWidth: 520)

            DetectorTrainingProgressLine(store: store)
        }
        .frame(maxWidth: Self.maxContentWidth)
        .padding(24)
    }

    /// Where the conversion stands, then what can be done next.
    private var statusColumn: some View {
        VStack(spacing: 20) {
            // The stored row decides what is said (its state and the EZZK mode it was signed
            // in); the checker's change count redraws when the periodic check moves it on,
            // and the timeline when a waiting "Overiť v EZZK" becomes available.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                // The order of 1. 1. 2027 shows where the conversion stands as a timeline;
                // today's order keeps its result screen.
                if let timeline = store.conversionTimeline(now: context.date) {
                    recordFirstStatus(timeline, done: presentation(at: context.date))
                } else {
                    ezzkStatus(presentation(at: context.date))
                }
            }
            if let directory = store.outputDirectory {
                deliveredActions(directory)
                    .frame(maxWidth: 520)
            } else {
                // Plain buttons under the timeline card: a card around one or two buttons
                // read as a second, empty panel.
                recordFirstCard
                    .frame(maxWidth: 520)
            }
        }
    }

    /// The delivered file: open the folder, save a copy, start the next conversion.
    private func deliveredActions(_ directory: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let renamed = ZakoSinglePDFDelivery.renamedNotice(
                for: store.evidenceStore.record(id: store.currentRecordID)) {
                Label(renamed, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(directory)
                } label: {
                    Label("Ukázať vo Finderi", systemImage: "folder")
                }
                .controlSize(.large)

                Button {
                    exportAs()
                } label: {
                    Label("Uložiť ako…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    startNewConversion()
                } label: {
                    Label("Nová konverzia", systemImage: "plus")
                }
                .controlSize(.large)
            }
            if let exportError {
                HStack(spacing: 8) {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Skúsiť znova", action: exportAs)
                        .buttonStyle(.bordered)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The conversion at a glance; nil when there is neither a stored conversion nor a row.
    private var summaryModel: ZakoDoneSummary? {
        let pending = store.recordFirstPending
        _ = store.settingsStore.statusChecker.changeCount
        let record = store.evidenceStore.record(id: pending?.recordID ?? store.currentRecordID)
        return ZakoDoneSummary.make(pending: pending, record: record,
                                    evidenceNumber: store.attestation.evidenceNumber,
                                    outputDirectory: store.outputDirectory)
    }

    private func summaryCard(_ summary: ZakoDoneSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Konverzia")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let document = previewCache.previewDocument(for: store),
               let image = previewCache.firstPage(of: document) {
                ZakoPagePreview(image: image, accessibilityLabel: "Prvá strana nového dokumentu")
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .padding(.vertical, 4)
            }
            ForEach(summary.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if row.id == "environment", let mode = summary.mode {
                        EZZKEnvironmentBadge(mode: mode, form: .subject)
                    } else {
                        Text(row.value)
                            .font(row.isMonospaced ? .callout.monospacedDigit().weight(.semibold) : .callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let folder = summary.folder {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Priečinok s vygenerovanými súbormi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(folder)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(cornerRadius: 12, padding: 14)
    }

    private func presentation(at now: Date) -> ZakoDonePresentation {
        let checker = store.settingsStore.statusChecker
        _ = checker.changeCount
        let record = store.evidenceStore.record(id: store.currentRecordID)
        return ZakoDonePresentation(record: record,
                                    lastError: store.lastError,
                                    lastErrorStatus: store.submissionStatus,
                                    nextStatusCheck: record.flatMap { checker.nextStatusCheck(for: $0) },
                                    now: now,
                                    currentMode: store.settingsStore.ezzkAccountController.mode,
                                    productionAllowed: store.settingsStore.ezzkAccountController
                                        .productionPolicy.allowsConsequentialCalls,
                                    recordFirstStage: store.recordFirstPending?.stage)
    }

    private func toneColor(_ tone: EZZKRecordPresentation.Tone) -> Color {
        switch tone {
        case .success: return .green
        case .pending, .warning: return .orange
        case .failure: return .red
        }
    }

    @ViewBuilder
    private func ezzkStatus(_ done: ZakoDonePresentation) -> some View {
        let tint = toneColor(done.tone)
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 130, height: 130)
                Image(systemName: done.symbol)
                    .font(.system(size: 60))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(done.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let result = store.result {
                    Text(result.isLegallyBinding
                         ? "Kvalifikovaný elektronický podpis a doložka pripojené"
                         : "DEMO režim: konverzia nemá právne účinky")
                        .font(.callout)
                        .foregroundStyle(result.isLegallyBinding ? Color.secondary : Color.orange)
                }

                ForEach(done.lines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(done.tone == .success ? Color.secondary : tint)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }

                if let evidence = store.attestation.evidenceNumber {
                    HStack(spacing: 6) {
                        Text("Evidenčné číslo:")
                            .foregroundStyle(.secondary)
                        Text(evidence)
                            .font(.callout.monospacedDigit().weight(.bold))
                    }
                    .padding(.top, 2)
                }

                ezzkActionButton(done)

                if let error = done.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// The record-first waiting and done screen: one headline, the timeline, what comes next.
    /// The environment is in the conversion header, so it is not repeated here.
    @ViewBuilder
    private func recordFirstStatus(_ timeline: ZakoConversionTimeline, done: ZakoDonePresentation) -> some View {
        let record = store.evidenceStore.record(id: store.recordFirstPending?.recordID ?? store.currentRecordID)
        let tint = timelineTint(timeline.phase)
        VStack(spacing: 16) {
            Label {
                Text(timeline.headline)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: timelineSymbol(timeline.phase))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: 520)

            if let result = store.result, timeline.phase == .done, !result.isLegallyBinding {
                Text("DEMO režim: konverzia nemá právne účinky")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 12) {
                if !timeline.headlineNamesNumber,
                   let evidence = store.attestation.evidenceNumber ?? record?.evidenceNumber {
                    HStack(spacing: 6) {
                        Text("Evidenčné číslo:")
                            .foregroundStyle(.secondary)
                        Text(evidence)
                            .font(.callout.monospacedDigit().weight(.bold))
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }
                ZakoConversionTimelineView(timeline: timeline)
                if let line = timeline.line {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(ZakoConversionTimeline.supplementaryLines(done.lines, record: record), id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(done.tone == .success ? Color.secondary : toneColor(done.tone))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ezzkActionButton(done)
                if let error = done.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 496, alignment: .leading)
            .glassCard(cornerRadius: 12, padding: 12)
            .frame(maxWidth: 520)
        }
    }

    private func timelineSymbol(_ phase: ZakoConversionTimeline.Phase) -> String {
        switch phase {
        case .waitingNotSent: "tray.and.arrow.up.fill"
        case .waitingOutcomeUnknown: "questionmark.circle.fill"
        case .waitingSent: "hourglass"
        case .ready, .signing: "signature"
        case .done: "checkmark.seal.fill"
        case .rejected: "xmark.seal.fill"
        }
    }

    private func timelineTint(_ phase: ZakoConversionTimeline.Phase) -> Color {
        switch phase {
        case .done: .green
        case .rejected: .red
        case .waitingNotSent, .waitingOutcomeUnknown: .orange
        case .waitingSent, .ready, .signing: .accentColor
        }
    }

    @ViewBuilder
    private func ezzkActionButton(_ done: ZakoDonePresentation) -> some View {
        switch done.action {
        case .none:
            EmptyView()
        case .send, .verify:
            let isSend = done.action == .send
            Button {
                isWorkingOnEZZK = true
                Task {
                    if isSend {
                        await store.retryQueuedSubmission()
                    } else {
                        await store.verifyRecordInEZZK()
                    }
                    isWorkingOnEZZK = false
                }
            } label: {
                HStack(spacing: 5) {
                    if isWorkingOnEZZK {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isSend ? "tray.and.arrow.up" : "magnifyingglass")
                    }
                    Text(isSend ? "Odoslať do EZZK" : "Overiť v EZZK")
                }
            }
            .controlSize(.small)
            .disabled(!done.isActionEnabled || isWorkingOnEZZK)
            .padding(.top, 4)
        }
    }

    /// "Uložiť ako…": a copy of the file the client got (the ASiC-E, the one PDF, or the PDF/A on the
    /// phone route; rows from before the single output name only the PDF/A).
    private func exportAs() {
        exportError = nil
        guard let directory = store.outputDirectory else { return }
        let record = store.evidenceStore.record(id: store.currentRecordID)
        let fileName = record?.deliveredFileName ?? record?.pdfFileName
            ?? ConversionOutputNaming.pdfFileName(
                originalDocumentName: store.attestation.originalDocumentName,
                requestedDocumentName: store.attestation.newDocumentName)
        let delivered = directory.appendingPathComponent(fileName)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: delivered.pathExtension) ?? .data]
        panel.nameFieldStringValue = delivered.lastPathComponent
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard FileManager.default.fileExists(atPath: delivered.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Výstup sa nenašiel."])
                }
                try FileManager.default.copyItem(at: delivered, to: url)
            } catch {
                exportError = "Export sa nepodaril: \(error.localizedDescription)"
            }
        }
    }

    /// Nothing delivered yet: a record-first conversion waits for EZZK in the background, is
    /// ready for its clause signature, or ended (rejected) and leaves only a new start. The
    /// timeline above says where it stands; this card holds only the actions.
    @ViewBuilder
    private var recordFirstCard: some View {
        VStack(alignment: .center, spacing: 10) {
            if let warning = store.recordFirstPersistWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if store.recordFirstPending?.stage == .signingClientContainer {
                    Button {
                        store.lastError = nil
                        store.step = .authorize
                    } label: {
                        Label("Dokončiť konverziu", systemImage: "signature")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button {
                    startNewConversion()
                } label: {
                    Label("Nová konverzia", systemImage: "plus")
                }
                .controlSize(.large)
            }
        }
    }

    private func startNewConversion() {
        store.resetSession(keepingProfile: true)
        store.step = .intake
    }
}
