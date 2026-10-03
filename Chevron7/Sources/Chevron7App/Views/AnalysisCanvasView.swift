// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import PDFKit
import Chevron7Kit

struct AnalysisCanvasView: View {
    @Bindable var store: ZakoSessionStore
    @State private var showPhysicalElementSheet = false
    @State private var showPrecisePlacement = false
    /// Scope of the bulk rejection waiting for confirmation: a page index, or -1 for the whole document.
    @State private var bulkRejectScope: Int?
    @State private var interaction: Interaction?
    @State private var pageImage: NSImage?
    @State private var pageAspect: CGFloat = 1.414
    @State private var zoomScale: CGFloat = 1.0
    @State private var showRejectedList = false
    /// Viewer preference: rejected findings stay on the canvas as faint dashed outlines.
    @AppStorage(ElementOverlay.showRejectedKey) private var showRejectedOnCanvas = true
    @AppStorage("zako.learningExplainerShown") private var learningExplainerShown = false
    @State private var showLearningExplainer = false

    struct Interaction {
        enum Kind {
            case moving(UUID, offset: NormalizedPoint)
            case resizing(UUID, NormalizedPoint)
        }
        var kind: Kind
        var startPoint: NormalizedPoint
        var moved: Bool = false
        /// True only when this interaction placed a brand-new placeholder element
        /// (via store.placeElement), so a click-without-drag on it should snap.
        var created: Bool = false
    }

    /// Maps between view coordinates (y=0 top) and the domain convention
    /// (normalized y=0 page BOTTOM, PDF semantics) used by SecurityElement boxes.
    struct CanvasMapper {
        let fitter: ElementGeometry.AspectFitter

        func viewRect(for normalized: NormalizedRect) -> CGRect {
            fitter.viewRect(for: NormalizedRect(
                x: normalized.x,
                y: 1 - normalized.y - normalized.height,
                width: normalized.width,
                height: normalized.height))
        }

        func normalizedPoint(from viewPoint: CGPoint) -> NormalizedPoint {
            let topDown = fitter.normalizedPoint(from: viewPoint)
            return NormalizedPoint(x: topDown.x, y: 1 - topDown.y)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let warning = store.analysisWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
            }

            HSplitView {
                HStack(spacing: 0) {
                    if store.analysis.totalPages > 1 {
                        pageThumbnailStrip
                            .frame(width: 80)
                        Divider()
                    }

                    VStack(spacing: 10) {
                        pageImageLoader
                            .frame(minWidth: MacOS27Layout.canvasMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
                        countersRow
                    }
                    .padding(14)
                }

                elementsPanel
                    .frame(minWidth: MacOS27Layout.inspectorMinimumWidth,
                           idealWidth: MacOS27Layout.inspectorIdealWidth,
                           maxWidth: 400)
            }

            StickyActionBar {
                Button {
                    store.resetSession(keepingProfile: true)
                    store.step = .intake
                } label: {
                    Label("Iný dokument", systemImage: "chevron.left")
                }
                .controlSize(.large)

                Button {
                    Task { await store.runAnalysis() }
                } label: {
                    Label("Znova analyzovať AI", systemImage: "arrow.clockwise")
                }
                .disabled(store.isAnalyzing)
                .controlSize(.large)

                detectionProviderPicker

                Spacer()

                Button {
                    store.step = .attestation
                } label: {
                    HStack(spacing: 6) {
                        Text("Pokračovať na doložku")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isAnalyzing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(isPresented: $showPhysicalElementSheet) { PhysicalSecurityElementSheet(store: store) }
        .onKeyPress(.delete) {
            // A pending AI suggestion is rejected, a rejected finding is left alone.
            guard let id = store.selectedElementID else { return .ignored }
            switch store.deleteOrRejectSecurityElement(id: id) {
            case .ignored:
                return .ignored
            case .removed, .rejected:
                store.selectedElementID = nil
                return .handled
            }
        }
        .onKeyPress(.escape) {
            if store.activeTool != nil {
                store.activeTool = nil
                return .handled
            }
            if store.selectedElementID != nil {
                store.selectedElementID = nil
                return .handled
            }
            return .ignored
        }
        .task(id: "\(store.previewPageIndex)-\(store.document == nil)") {
            renderPage()
        }
    }

    private func renderPage() {
        guard let document = store.document,
              let page = document.page(at: min(store.previewPageIndex,
                                               max(document.pageCount - 1, 0))),
              let rendered = BuiltInVisionProvider.render(page: page, targetWidth: 1240) else {
            pageImage = nil
            return
        }
        // Rotation-aware render: displayed bitmap and aspect agree with the page
        // as the user sees it (/Rotate honored).
        let cg = rendered.cgImage
        pageImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        pageAspect = CGFloat(cg.width) / max(CGFloat(cg.height), 1)
    }

    // MARK: - Left Page Thumbnail Strip
    private var pageThumbnailStrip: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 8) {
                ForEach(0..<store.analysis.totalPages, id: \.self) { pageIndex in
                    let isSelected = store.previewPageIndex == pageIndex
                    let countOnPage = store.securityElements.filter {
                        $0.pageIndex == pageIndex && $0.reviewState != .rejected
                    }.count
                    let page = store.document?.page(at: pageIndex)
                    let bounds = page?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
                    let aspect = bounds.width > 0 && bounds.height > 0 ? (bounds.width / bounds.height) : (54.0 / 72.0)
                    let thumbWidth: CGFloat = aspect >= 1.0 ? 64 : 54
                    let thumbHeight: CGFloat = max(thumbWidth / aspect, 40)

                    Button {
                        store.previewPageIndex = pageIndex
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                                .frame(width: thumbWidth, height: thumbHeight)
                                .overlay {
                                    if let page {
                                        Image(nsImage: page.thumbnail(
                                            of: CGSize(width: thumbWidth * 2, height: thumbHeight * 2),
                                            for: .mediaBox))
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: max(thumbWidth - 2, 10), height: max(thumbHeight - 2, 10))
                                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    }
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                                )

                            Text("\(pageIndex + 1)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                .padding(.horizontal, 4)
                                .padding(4)
                                .background(.regularMaterial, in: Capsule())

                            if store.reviewedNonEmptyPages.contains(pageIndex) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white, .green)
                                    .frame(width: thumbWidth, height: thumbHeight, alignment: .bottomTrailing)
                                    .offset(x: 3, y: 3)
                            }
                            if countOnPage > 0 {
                                Text("\(countOnPage)")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.green, in: Capsule())
                                    .foregroundStyle(.white)
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
        }
    }

    // MARK: - Markup Toolbar
    /// Manual marking lives in the inspector, not over the page: pick a kind,
    /// then click the element in the document. Picking it again leaves the mode.
    private var addElementCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pridať prvok", systemImage: "plus.circle")
                .font(.headline)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    toolButton(kind: .officialStamp, title: "Pečiatka", icon: "seal.fill")
                    toolButton(kind: .handwrittenSignature, title: "Podpis", icon: "signature")
                }
                GridRow {
                    toolButton(kind: .embossedSeal, title: "Slepotlač", icon: "rosette")
                    toolButton(kind: .initial, title: "Parafa", icon: "text.badge.checkmark")
                }
                GridRow {
                    toolButton(kind: .bindingCord, title: "Šnúrka", icon: "link")
                    toolButton(kind: .securityTape, title: "Páska / štítok", icon: "rectangle")
                }
            }

            Menu("Ďalší prvok v skene") { SecurityElementKindOptions { store.activeTool = $0 } }
            if let kind = store.activeTool {
                Text("Označte v skene: \(kind.label)").font(.caption).foregroundStyle(.secondary)
            }
            Button("Skontrolované na origináli…") { showPhysicalElementSheet = true }
                .disabled(store.document == nil)

            Button {
                let kind = store.activeTool ?? .officialStamp
                let defaultPoint = NormalizedPoint(x: 0.5, y: 0.5)
                let id = store.placeElement(kind: kind, at: defaultPoint)
                store.selectedElementID = id
                showPrecisePlacement = true
            } label: {
                Label("Pridať na aktuálnu stranu", systemImage: "plus.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Vloží nový rámec do stredu aktuálnej strany a označí ho na číselné alebo klávesové úpravy")

            if let progress = store.snapAssetProgress {
                HStack(spacing: 6) {
                    ProgressView(value: progress).frame(width: 80)
                    Text("Sťahujem model výberu…").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let reason = store.snapUnavailableReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(store.activeTool == nil
                     ? "Zvoľte typ a kliknite na prvok v dokumente; rámec sa prichytí k jeho obrysu."
                     : "Kliknite na prvok v dokumente. Ťahaním nakreslíte rámec ručne.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Indicator + inline switcher for the detection provider. Apple Vision
    /// (on-device) always runs; the selected mode only adds LLM findings.
    private var detectionProviderPicker: some View {
        let currentMode = store.settingsStore.settings.aiMode
        return Menu {
            Picker("Poskytovateľ detekcie", selection: Binding(
                get: { store.settingsStore.settings.aiMode },
                set: { store.settingsStore.settings.aiMode = $0 })) {
                ForEach(AppSettings.AIMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: icon(for: mode)).tag(mode)
                }
            }

        } label: {
            Label("Detekcia", systemImage: "sparkles")
        }
        .controlSize(.large)
        .fixedSize()
        .accessibilityLabel("Poskytovateľ detekcie")
        .accessibilityValue(currentMode.rawValue)
        .help("Detekcia: \(currentMode.rawValue). Apple Vision beží vždy on-device; zvolený režim dopĺňa LLM klasifikáciu. Zmena sa prejaví pri ďalšej analýze.")
    }

    private func icon(for mode: AppSettings.AIMode) -> String {
        switch mode {
        case .omlxLocal: return "apple.logo"
        case .ollamaLocal: return "laptopcomputer"
        case .builtInOnDevice: return "bolt.badge.checkmark"
        case .customAPIKey: return "key.fill"
        case .disabled: return "xmark.circle"
        }
    }

    private var pageNavBar: some View {
        HStack(spacing: 4) {
            Button {
                store.previewPageIndex = max(store.previewPageIndex - 1, 0)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(store.previewPageIndex <= 0)
            .controlSize(.small)
            .accessibilityLabel("Predchádzajúca strana")

            Text("Strana \(store.previewPageIndex + 1) z \(max(store.analysis.totalPages, 1))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            Button {
                store.previewPageIndex = min(store.previewPageIndex + 1,
                                             max(store.analysis.totalPages - 1, 0))
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(store.previewPageIndex >= max(store.analysis.totalPages - 1, 0))
            .controlSize(.small)
            .accessibilityLabel("Nasledujúca strana")
        }
    }

    private func toolButton(kind: SecurityElement.Kind, title: String, icon: String) -> some View {
        let isSelected = store.activeTool == kind
        return Button {
            store.activeTool = isSelected ? nil : kind
        } label: {
            Label(title, systemImage: icon)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }


    private var pageImageLoader: some View {
        GeometryReader { geometry in
            ZStack(alignment: .center) {
                Color(nsColor: .underPageBackgroundColor)

                if let image = pageImage {
                    let baseFitter = ElementGeometry.AspectFitter(
                        container: geometry.size,
                        imageAspect: pageAspect)

                    if zoomScale > 1.0 {
                        ScrollView([.horizontal, .vertical], showsIndicators: true) {
                            let zoomedWidth = baseFitter.contentRect.width * zoomScale
                            let zoomedHeight = baseFitter.contentRect.height * zoomScale
                            let zoomedSize = CGSize(width: zoomedWidth, height: zoomedHeight)

                            Image(nsImage: image)
                                .resizable()
                                .frame(width: zoomedWidth, height: zoomedHeight)
                                .overlay {
                                    ElementOverlay(
                                        store: store,
                                        mapper: AnalysisCanvasView.CanvasMapper(
                                            fitter: ElementGeometry.AspectFitter(
                                                container: zoomedSize,
                                                imageAspect: pageAspect)),
                                        interaction: $interaction)
                                }
                                .overlay {
                                    Rectangle()
                                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                }
                                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                                .padding(16)
                        }
                    } else {
                        // Fit to window
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: baseFitter.contentRect.width,
                                   height: baseFitter.contentRect.height)
                            .overlay {
                                ElementOverlay(
                                    store: store,
                                    mapper: AnalysisCanvasView.CanvasMapper(
                                        fitter: ElementGeometry.AspectFitter(
                                            container: baseFitter.contentRect.size,
                                            imageAspect: pageAspect)),
                                    interaction: $interaction)
                            }
                            .overlay {
                                Rectangle()
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    }
                } else if store.isAnalyzing {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.regular)
                        Text("Analyzujem bezpečnostné prvky…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Žiadna strana na zobrazenie")
                        .foregroundStyle(.secondary)
                }

                if let tool = store.activeTool {
                    VStack {
                        HStack {
                            Label("\(tool.rawValue): kliknite na prvok v dokumente", systemImage: "plus.viewfinder")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.9), in: Capsule())
                                .foregroundStyle(.white)
                                .shadow(radius: 4)

                            Spacer()
                        }
                        .padding(10)
                        Spacer()
                    }
                }
                if store.isAnalyzing {
                    analysisOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Covers the canvas while detection runs: the dimming layer also swallows
    /// clicks, so nobody edits boxes that the finishing run is about to replace.
    private var analysisOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text("Analyzujem dokument")
                    .font(.headline)
                if !store.analysisProgressText.isEmpty {
                    Text(store.analysisProgressText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Nálezy sa zobrazia po dokončení. Kontrola každej strany zostáva na vás.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Prebieha analýza dokumentu")
    }

    /// One quiet line under the page instead of four chips: the numbers matter,
    /// the decoration competed with the document.
    private var countersRow: some View {
        HStack(spacing: 4) {
            Text(SlovakCount.phrase(store.analysis.totalPages, "strana", "strany", "strán")
                 + " · \(store.analysis.nonEmptyPages) neprázdne ·")
            sheetCountMenu
            Text("· " + SlovakCount.phrase(store.securityElements.count, "prvok", "prvky", "prvkov"))

            Spacer(minLength: 8)

            zoomControls
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Súhrn dokumentu")
    }

    private var zoomControls: some View {
        HStack(spacing: 3) {
            Button {
                zoomScale = max(1.0, zoomScale - 0.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(zoomScale <= 1.0)
            .help("Zmenšiť náhľad strany")

            Menu {
                Button("100% (prispôsobiť)") { zoomScale = 1.0 }
                Button("125%") { zoomScale = 1.25 }
                Button("150%") { zoomScale = 1.5 }
                Button("200%") { zoomScale = 2.0 }
            } label: {
                Text("\(Int(zoomScale * 100))%")
                    .font(.caption2.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                zoomScale = min(2.5, zoomScale + 0.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(zoomScale >= 2.5)
            .help("Zväčšiť náhľad strany (lupa na detaily)")
        }
        .controlSize(.small)
    }

    private var sheetCountMenu: some View {
        Menu {
            Picker("Spôsob počítania listov", selection: $store.sheetMethod) {
                ForEach(SheetCountingMethod.allCases, id: \.self) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            if store.sheetMethod == .manual {
                Stepper("Počet listov: \(store.manualSheetCount ?? store.analysis.estimatedSheetsDuplex)",
                        value: Binding(
                            get: { store.manualSheetCount ?? store.analysis.estimatedSheetsDuplex },
                            set: { store.manualSheetCount = $0 }),
                        in: 1...999)
            }
        } label: {
            HStack(spacing: 2) {
                Text(SlovakCount.phrase(store.effectiveSheetCount, "list", "listy", "listov")
                     + (store.sheetMethod == .manual ? "" : " (odhad)"))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.mini)
        .font(.caption.monospacedDigit())
        .fixedSize()
        .help("Spôsob počítania listov: \(store.sheetMethod.rawValue)")
        .onChange(of: store.sheetMethod) { _, _ in
            store.applySheetMethodChange()
        }
    }
    private var elementsPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        pageReviewCard
                        Divider().opacity(0.35)
                        findingsCard
                        Divider().opacity(0.35)
                        addElementCard
                    }
                    .padding(12)
                }
                .onChange(of: store.selectedElementID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(.regularMaterial)
    }

    /// Findings of the current page plus the collapsed numeric inspector.
    private var findingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            let pendingOnPage = store.securityElements.filter {
                $0.pageIndex == store.previewPageIndex && $0.reviewState == .pending
            }.count
            HStack(spacing: 8) {
                Label("Nálezy", systemImage: "checklist")
                    .font(.headline)
                // Rejected findings are counted in their own group, like on the page thumbnails.
                let liveInDocument = store.securityElements.filter { !$0.isLockedByRejection }
                Text("\(liveInDocument.filter { $0.pageIndex == store.previewPageIndex }.count) z \(liveInDocument.count) celkom")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if pendingOnPage > 1 {
                    Button("Potvrdiť všetky (\(pendingOnPage))") {
                        store.confirmAllPendingElements(onPage: store.previewPageIndex)
                    }
                    .controlSize(.small)
                    .help("Potvrdí všetky nálezy na tejto strane, ktoré ešte čakajú na kontrolu")
                }
                let pendingInDocument = store.pendingElementCount(onPage: nil)
                if pendingInDocument > 0 {
                    Menu {
                        Button("Na tejto strane (\(pendingOnPage))") {
                            bulkRejectScope = store.previewPageIndex
                        }
                        .disabled(pendingOnPage == 0)
                        Button("V celom dokumente (\(pendingInDocument))") {
                            bulkRejectScope = -1
                        }
                    } label: {
                        Label("Odmietnuť návrhy", systemImage: "xmark.circle")
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Odmietne naraz všetky nálezy, ktoré ešte čakajú na kontrolu")
                }
                if store.lastDeletedElement != nil {
                    Button {
                        store.undoDelete()
                    } label: {
                        Label("Vrátiť", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    .help("Vrátiť zmazaný prvok")
                }
            }

            let pageElements = store.securityElements
                .filter { $0.pageIndex == store.previewPageIndex }
                .sorted { $0.boundingBox.y < $1.boundingBox.y }
            let liveElements = pageElements.filter { !$0.isLockedByRejection }
            let rejectedElements = pageElements.filter(\.isLockedByRejection)

            if liveElements.contains(where: { $0.detectedByAI && $0.reviewState == .pending }) {
                Text("Nesprávne umiestnený návrh opravte posunutím a potvrďte; odmietnite len to, čo nie je bezpečnostný prvok.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if liveElements.isEmpty && !store.isAnalyzing {
                emptyHint
            }

            ForEach(liveElements) { element in
                elementRow(element)
            }

            if !rejectedElements.isEmpty {
                DisclosureGroup(isExpanded: $showRejectedList) {
                    ForEach(rejectedElements) { element in
                        elementRow(element)
                            .opacity(store.selectedElementID == element.id ? 0.85 : 0.6)
                    }
                } label: {
                    Text("Odmietnuté (\(rejectedElements.count))")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .help("Odmietnuté nálezy sa nedostanú do doložky a učia detektor, čo nie je bezpečnostný prvok. Nedajú sa posunúť ani zmazať, len vrátiť na kontrolu.")
                Toggle("Zobraziť odmietnuté", isOn: $showRejectedOnCanvas)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Odmietnuté nálezy sa v dokumente kreslia slabým prerušovaným obrysom a nereagujú na klik")
            }

            // A rejected finding is locked: no placement inspector and no keyboard nudges.
            if let selected = store.securityElements.first(where: { $0.id == store.selectedElementID }),
               !selected.isLockedByRejection {
                if selected.observation == .physicalOriginal {
                    selectedElementInspector
                } else {
                    DisclosureGroup("Presná poloha", isExpanded: $showPrecisePlacement) {
                        selectedElementInspector
                    }
                    .font(.caption.weight(.semibold))
                    .help("Číselné umiestnenie a klávesové posuny. Ťahanie na plátne a klik na prvok sú rýchlejšie.")
                }
            }
        }
        .confirmationDialog(
            bulkRejectScope == -1
                ? "Odmietnuť všetky čakajúce nálezy v dokumente (\(store.pendingElementCount(onPage: nil)))?"
                : "Odmietnuť všetky čakajúce nálezy na tejto strane (\(store.pendingElementCount(onPage: bulkRejectScope)))?",
            isPresented: Binding(get: { bulkRejectScope != nil }, set: { if !$0 { bulkRejectScope = nil } }),
            titleVisibility: .visible
        ) {
            Button("Odmietnuť", role: .destructive) {
                if let scope = bulkRejectScope {
                    store.selectedElementID = nil
                    store.rejectAllPendingElements(onPage: scope == -1 ? nil : scope)
                }
                bulkRejectScope = nil
            }
            Button("Zrušiť", role: .cancel) { bulkRejectScope = nil }
        } message: {
            Text("Odmietnuté nálezy sa nedostanú do doložky a aplikácia sa z nich naučí, že nejde o bezpečnostný prvok. Potvrdené nálezy ostanú. Každý odmietnutý sa dá vrátiť na kontrolu v jeho riadku.")
        }
    }

    private func elementRow(_ element: SecurityElement) -> some View {
        ElementRow(element: element,
                   isSelected: store.selectedElementID == element.id,
                   isExpanded: store.selectedElementID == element.id,
                   onSelect: { store.selectedElementID = element.id },
                   onDelete: {
                       if store.selectedElementID == element.id {
                           store.selectedElementID = nil
                       }
                       store.deleteOrRejectSecurityElement(id: element.id)
                   },
                   onDuplicate: { _ = store.duplicateElement(id: element.id) },
                   onRefine: { Task { await store.refineElement(id: element.id) } },
                   onReviewStateChange: { state in
                       switch state {
                       case .confirmed: store.confirmSecurityElement(id: element.id)
                       case .rejected: store.rejectSecurityElement(id: element.id)
                       case .pending: store.returnSecurityElementToReview(id: element.id)
                       }
                   },
                   onKindChange: { kind in store.updateElementKind(id: element.id, kind: kind) },
                   onDescriptionChange: { text in
                       store.updateElementDescription(id: element.id, text: text)
                   })
        .id(element.id)
    }

    /// Review status of the current page: counts, the reviewed toggle, and the
    /// pages that still need a look.
    private var pageReviewCard: some View {
        let pageIndex = store.previewPageIndex
        let isReviewed = store.reviewedNonEmptyPages.contains(pageIndex)
        let isEmptyPage = store.analysis.pageAnalyses.first(where: { $0.pageIndex == pageIndex })?.isEmpty != false
        let rejected = store.securityElements.filter { $0.reviewState == .rejected }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Kontrola strany", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                pageNavBar
            }
            Text("\(store.confirmedSecurityElements.count) potvrdené · \(store.pendingSecurityElementCount) čaká · \(rejected) odmietnuté")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                if isReviewed { store.unmarkPageReviewed(pageIndex) } else { store.markPageReviewedAndAdvance(pageIndex) }
            } label: {
                Label(isReviewed ? "Strana skontrolovaná" : "Označiť stranu ako skontrolovanú",
                      systemImage: isReviewed ? "checkmark.circle.fill" : "circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(isReviewed ? .green : .accentColor)
            .disabled(isEmptyPage || store.securityElements.contains { $0.pageIndex == pageIndex && $0.reviewState == .pending })
            .help(isReviewed ? "Kliknutím zrušíte označenie" : "Každá neprázdna strana musí byť skontrolovaná")
            .popover(isPresented: $showLearningExplainer) {
                learningExplainer
            }
            .onChange(of: showLearningExplainer) { _, shown in
                if !shown { learningExplainerShown = true }
            }
            if store.settingsStore.settings.learnFromReviews {
                Text("Každá skontrolovaná strana učí Chevron7 rozpoznávať vaše dokumenty.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .task {
                        if !learningExplainerShown { showLearningExplainer = true }
                    }
            }

            if !store.unconfirmedNonEmptyPages.isEmpty && !store.isAnalyzing {
                unconfirmedWarning
            }
            if store.confirmedSecurityElements.isEmpty {
                Toggle("Originál som skontroloval: bez bezpečnostných prvkov", isOn: Binding(
                    get: { store.attestation.noSecurityElementsConfirmed },
                    set: { if $0 { store.confirmNoSecurityElements() } else { store.attestation.noSecurityElementsConfirmed = false } }))
                    .font(.caption)
                    .disabled(!store.canConfirmNoSecurityElements)
            }

        }
    }

    /// First-use explainer: the three layers of learning, shown once.
    private var learningExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ako sa Chevron7 učí").font(.headline)
            Text("Rovnaký výrez si zapamätá hneď.")
            Text("Rovnaký dokument si nabudúce prinesie vašu kontrolu.")
            Text("Dosť skontrolovaných strán natrénuje detektor aj pre nové dokumenty, iba na tomto Macu.")
        }
        .padding()
        .frame(width: 300)
    }

    @ViewBuilder
    private var selectedElementInspector: some View {
        if let element = store.securityElements.first(where: { $0.id == store.selectedElementID }) {
            if element.observation == .physicalOriginal {
                PhysicalSecurityElementInspector(store: store, element: element)
            } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Vybraný prvok: \(element.kind.label)", systemImage: element.kind.sfSymbol)
                    .font(.caption.weight(.semibold))
                Text("Umiestnenie a veľkosť (0 až 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        normalizedField("X", value: element.boundingBox.x) { value in
                            updateBoundingBox(element.id) { $0.x = value }
                        }
                        normalizedField("Y", value: element.boundingBox.y) { value in
                            updateBoundingBox(element.id) { $0.y = value }
                        }
                    }
                    GridRow {
                        normalizedField("Šírka", value: element.boundingBox.width) { value in
                            updateBoundingBox(element.id) { $0.width = value }
                        }
                        normalizedField("Výška", value: element.boundingBox.height) { value in
                            updateBoundingBox(element.id) { $0.height = value }
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text("Posun")
                        .font(.caption2.weight(.semibold))
                    placementButton("doľava", icon: "arrow.left", shortcut: .leftArrow, modifiers: [.option]) {
                        adjustSelectedElement(dx: -0.01, dy: 0)
                    }
                    placementButton("doprava", icon: "arrow.right", shortcut: .rightArrow, modifiers: [.option]) {
                        adjustSelectedElement(dx: 0.01, dy: 0)
                    }
                    placementButton("hore", icon: "arrow.up", shortcut: .upArrow, modifiers: [.option]) {
                        adjustSelectedElement(dx: 0, dy: 0.01)
                    }
                    placementButton("dole", icon: "arrow.down", shortcut: .downArrow, modifiers: [.option]) {
                        adjustSelectedElement(dx: 0, dy: -0.01)
                    }
                }

                HStack(spacing: 6) {
                    Text("Veľkosť")
                        .font(.caption2.weight(.semibold))
                    placementButton("zmenšiť šírku", icon: "arrow.left.and.right", shortcut: .leftArrow, modifiers: [.shift, .option]) {
                        adjustSelectedElement(dx: 0, dy: 0, dw: -0.01, dh: 0)
                    }
                    placementButton("zväčšiť šírku", icon: "arrow.left.and.right", shortcut: .rightArrow, modifiers: [.shift, .option]) {
                        adjustSelectedElement(dx: 0, dy: 0, dw: 0.01, dh: 0)
                    }
                    placementButton("zmenšiť výšku", icon: "arrow.up.and.down", shortcut: .downArrow, modifiers: [.shift, .option]) {
                        adjustSelectedElement(dx: 0, dy: 0, dw: 0, dh: -0.01)
                    }
                    placementButton("zväčšiť výšku", icon: "arrow.up.and.down", shortcut: .upArrow, modifiers: [.shift, .option]) {
                        adjustSelectedElement(dx: 0, dy: 0, dw: 0, dh: 0.01)
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "keyboard")
                        .font(.caption2)
                    Text(element.deleteAction == .reject
                         ? "Klávesy: ⌥+šípky (posun) · ⇧⌥+šípky (veľkosť) · ⌫ (odmietnuť návrh AI)"
                         : "Klávesy: ⌥+šípky (posun) · ⇧⌥+šípky (veľkosť) · ⌫ (zmazať)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityValue("\(UXLabels.confidenceLabel(for: element.confidence)); \(UXLabels.provenanceLabel(detectedByAI: element.detectedByAI))")
            }
        }
    }

    private func normalizedField(_ label: String, value: Double,
                                onChange: @escaping (Double) -> Void) -> some View {
        TextField(label, value: Binding(
            get: { value },
            set: { onChange($0) }
        ), format: .number.precision(.fractionLength(3)))
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 72)
        .accessibilityLabel(label)
    }

    private func updateBoundingBox(_ id: UUID, update: (inout NormalizedRect) -> Void) {
        guard var box = store.securityElements.first(where: { $0.id == id })?.boundingBox else { return }
        update(&box)
        store.updateElementBoundingBox(id: id, boundingBox: box)
    }

    private func adjustSelectedElement(dx: Double, dy: Double, dw: Double = 0, dh: Double = 0) {
        guard let element = store.securityElements.first(where: { $0.id == store.selectedElementID }) else { return }
        var box = element.boundingBox
        box.x += dx
        box.y += dy
        box.width += dw
        box.height += dh
        store.updateElementBoundingBox(id: element.id, boundingBox: box)
    }

    private func placementButton(_ label: String, icon: String, shortcut: KeyEquivalent,
                                 modifiers: EventModifiers = [], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(label)
        .keyboardShortcut(shortcut, modifiers: modifiers)
    }

    private var unconfirmedWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Neskontrolované neprázdne strany:", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            FlowChips(pages: store.unconfirmedNonEmptyPages) { pageIndex in
                store.previewPageIndex = pageIndex
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyHint: some View {
        Text("Žiadne prvky. Zvoľte nástroj a kliknite na prvok v dokumente.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }
}

struct FlowChips: View {
    let pages: [Int]
    let onSelect: (Int) -> Void

    var body: some View {
        let shown = Array(pages.prefix(6))
        HStack(spacing: 6) {
            ForEach(shown, id: \.self) { pageIndex in
                Button {
                    onSelect(pageIndex)
                } label: {
                    Text("\(pageIndex + 1)")
                        .font(.caption.monospacedDigit().weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Strana \(pageIndex + 1)")
            }
            if pages.count > shown.count {
                Text("+\(pages.count - shown.count) ďalších")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ElementOverlay: View {
    static let showRejectedKey = "zako.showRejectedElements"

    @Bindable var store: ZakoSessionStore
    let mapper: AnalysisCanvasView.CanvasMapper
    @Binding var interaction: AnalysisCanvasView.Interaction?
    @AppStorage(ElementOverlay.showRejectedKey) private var showRejected = true

    private let handleRadius: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, _ in
                let pageElements = store.securityElements.filter {
                    $0.pageIndex == store.previewPageIndex && $0.hasScanRegion
                }
                // Rejected findings recede beneath everything else, or disappear entirely.
                if showRejected {
                    for element in pageElements where element.isLockedByRejection {
                        drawRejected(context: context, element: element)
                    }
                }
                for element in pageElements where !element.isLockedByRejection {
                    draw(context: context, element: element)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
        }
    }

    /// Thin dashed grey outline, no fill, no label, no handles: a rejected finding is
    /// context only and never reacts to the pointer.
    private func drawRejected(context: GraphicsContext, element: SecurityElement) {
        let rect = mapper.viewRect(for: element.boundingBox)
        guard rect.width > 1, rect.height > 1 else { return }
        let isSelected = store.selectedElementID == element.id
        context.stroke(Path(roundedRect: rect, cornerRadius: 4),
                       with: .color(Color.gray.opacity(isSelected ? 0.7 : 0.35)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    private func draw(context: GraphicsContext, element: SecurityElement) {
        let rect = mapper.viewRect(for: element.boundingBox)
        guard rect.width > 1, rect.height > 1 else { return }
        let color = ElementKindColor.color(for: element.kind)
        let isSelected = store.selectedElementID == element.id

        context.fill(Path(roundedRect: rect, cornerRadius: 4),
                     with: .color(color.opacity(isSelected ? 0.22 : 0.10)))
        context.stroke(Path(roundedRect: rect, cornerRadius: 4),
                       with: .color(color),
                       lineWidth: isSelected ? 2.5 : 1.5)

        if isSelected {
            // Corner resize handles on all four corners.
            for corner in cornerPoints(of: rect) {
                let handle = CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)
                context.fill(Path(roundedRect: handle, cornerRadius: 2), with: .color(color))
                context.stroke(Path(roundedRect: handle, cornerRadius: 2),
                               with: .color(.white), lineWidth: 1.2)
            }

            let labelText = "\(element.kind.label) (\(Int(element.confidence * 100)) %)"
            let labelSize = CGSize(width: 170, height: 14)
            let labelFrame = CGRect(x: rect.minX,
                                    y: max(rect.minY - labelSize.height - 2, 0),
                                    width: labelSize.width,
                                    height: labelSize.height)
            context.fill(Path(roundedRect: labelFrame, cornerRadius: 3),
                         with: .color(color.opacity(0.9)))
            context.draw(
                context.resolve(
                    Text(labelText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white)),
                at: CGPoint(x: labelFrame.midX, y: labelFrame.midY),
                anchor: .center)
        }
    }

    private func cornerPoints(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }

    /// Returns the normalized point of the corner OPPOSITE to the grabbed corner,
    /// or nil when the point is not near any corner (with handleRadius tolerance).
    private func oppositeCornerAnchor(of box: NormalizedRect, at viewPoint: CGPoint) -> NormalizedPoint? {
        ElementGeometry.oppositeCornerAnchor(
            of: box,
            viewRect: mapper.viewRect(for: box),
            near: viewPoint,
            tolerance: handleRadius)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(value)
            }
            .onEnded { value in
                defer { interaction = nil }
                guard let current = interaction, !current.moved, current.created,
                      case .resizing(let id, _) = current.kind,
                      store.activeTool != nil else { return }
                // A click without movement right after placing a new element: snap its box in place.
                let point = mapper.normalizedPoint(from: value.location)
                Task { @MainActor in
                    await store.snapPlacedElement(id: id, at: point)
                }
            }
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        let normPoint = mapper.normalizedPoint(from: value.location)

        if interaction == nil {
            // Handles sit 5pt outside the box. Hit-test interiors first miss them,
            // and with a tool armed that used to place a new element.
            // Rejected findings are excluded: they never resize, move or block drawing.
            let interactive = store.interactiveCanvasElements(onPage: store.previewPageIndex)
            if let selected = interactive.first(where: { $0.id == store.selectedElementID }),
               let anchor = oppositeCornerAnchor(of: selected.boundingBox, at: value.location) {
                interaction = .init(kind: .resizing(selected.id, anchor), startPoint: anchor)
                return
            }

            // Selection can change while a drawing tool remains armed. Prefer any
            // existing corner over creating an overlapping element.
            if let resizeTarget = interactive.first(where: {
                $0.id != store.selectedElementID
                    && oppositeCornerAnchor(of: $0.boundingBox, at: value.location) != nil
            }), let anchor = oppositeCornerAnchor(of: resizeTarget.boundingBox, at: value.location) {
                store.selectedElementID = resizeTarget.id
                interaction = .init(kind: .resizing(resizeTarget.id, anchor), startPoint: anchor)
                return
            }

            if let hitID = store.elementID(at: normPoint, pageIndex: store.previewPageIndex),
               let element = interactive.first(where: { $0.id == hitID }) {
                store.selectedElementID = hitID
                if let anchor = oppositeCornerAnchor(of: element.boundingBox, at: value.location) {
                    interaction = .init(kind: .resizing(hitID, anchor), startPoint: anchor)
                } else {
                    let offset = NormalizedPoint(
                        x: element.boundingBox.midX - normPoint.x,
                        y: element.boundingBox.midY - normPoint.y)
                    interaction = .init(kind: .moving(hitID, offset: offset), startPoint: normPoint)
                }
                return
            }

            if let tool = store.activeTool {
                let newID = store.placeElement(kind: tool, at: normPoint)
                interaction = .init(kind: .resizing(newID, normPoint), startPoint: normPoint, created: true)
                return
            }

            store.selectedElementID = nil
            return
        }

        guard let current = interaction else { return }
        switch current.kind {
        case .moving(let id, let offset):
            store.moveElement(
                id: id,
                center: NormalizedPoint(x: normPoint.x + offset.x, y: normPoint.y + offset.y))
            interaction?.moved = true
        case .resizing(let id, _):
            store.drawElement(id: id, from: current.startPoint, to: normPoint)
            interaction?.moved = true
        }
    }
}

struct ElementRow: View {
    let element: SecurityElement
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onRefine: () -> Void
    let onReviewStateChange: (SecurityElementReviewState) -> Void
    let onKindChange: (SecurityElement.Kind) -> Void
    let onDescriptionChange: (String) -> Void
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compact header: always visible, one line, tap selects.
            HStack(spacing: 8) {
                Image(systemName: element.kind.sfSymbol)
                    .foregroundStyle(ElementKindColor.color(for: element.kind))
                    .frame(width: 16)
                if isExpanded && !element.isLockedByRejection {
                    kindMenu
                } else {
                    Text(element.kind.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(UXLabels.confidenceLabel(for: element.confidence))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Label(element.reviewState.label, systemImage: reviewIcon)
                    .font(.caption2)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(reviewColor)
                    .help(element.reviewState.label)
                if element.reviewState == .pending && !isExpanded {
                    Button { onReviewStateChange(.confirmed) } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.borderless).controlSize(.small).help("Potvrdiť")
                    Button { onReviewStateChange(.rejected) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).controlSize(.small).help("Odmietnuť")
                }
            }
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(element.kind.label), stav: \(element.reviewState.label), \(UXLabels.provenanceLabel(detectedByAI: element.detectedByAI))")
            .accessibilityValue("\(UXLabels.confidenceLabel(for: element.confidence)); \(isSelected ? "Vybraný" : "Nevybraný")")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
            .accessibilityAction(named: "Vybrať prvok", onSelect)
            .focusable()
            .onKeyPress(.space) {
                onSelect()
                return .handled
            }
            .onKeyPress(.return) {
                onSelect()
                return .handled
            }

            if isExpanded {
                if element.isLockedByRejection {
                    // Locked: editing would drop the negative example from the learning bank.
                    if !element.verbalDescription.isEmpty {
                        Text(element.verbalDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2...4)
                    }
                } else {
                    TextField("Popis prvku", text: Binding(
                        get: { element.verbalDescription },
                        set: { onDescriptionChange($0) }
                    ), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Popis prvku")
                }

                HStack(alignment: .center, spacing: 6) {
                    Label(element.reviewState.label, systemImage: reviewIcon)
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                        .foregroundStyle(reviewColor)
                    Spacer(minLength: 6)
                    if element.reviewState == .pending {
                        Button("Potvrdiť") { onReviewStateChange(.confirmed) }
                            .buttonStyle(.borderedProminent).controlSize(.small).fixedSize()
                        Button("Odmietnuť") { onReviewStateChange(.rejected) }
                            .buttonStyle(.bordered).controlSize(.small).fixedSize()
                    } else {
                        Button("Vrátiť na kontrolu") { onReviewStateChange(.pending) }
                            .buttonStyle(.bordered).controlSize(.small).fixedSize()
                    }
                    if !element.isLockedByRejection {
                        Button { onDuplicate() } label: { Label("Duplikovať prvok", systemImage: "plus.square.on.square") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Duplikovať prvok").foregroundStyle(.secondary)
                        Button { onRefine() } label: { Label("Spresniť rámec", systemImage: "wand.and.stars") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Spresniť rámec podľa obrysu (Apple Vision)").foregroundStyle(.secondary)
                    }
                    // A pending AI suggestion has no trash: "Odmietnuť" above teaches the detector.
                    // Delete stays for hand-drawn elements and AI findings already confirmed.
                    if element.deleteAction == .remove {
                        Button(role: .destructive) { showDeleteConfirmation = true } label: { Label("Odstrániť prvok", systemImage: "trash") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Odstrániť prvok").foregroundStyle(.red)
                    }
                }
                .lineLimit(1)

                Text(sourceCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(isExpanded ? 10 : 6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .confirmationDialog("Naozaj chcete odstrániť tento prvok?",
                           isPresented: $showDeleteConfirmation,
                           titleVisibility: .visible) {
            Button("Odstrániť prvok", role: .destructive, action: onDelete)
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Prvok bude odstránený z doložky. Túto zmenu môžete vrátiť tlačidlom Späť.")
        }
    }

    private var sourceCaption: String {
        element.observation == .physicalOriginal ? "Kontrola originálu" : DetectionSourceLabel.slovak(element.detectionSource)
    }

    private var kindMenu: some View {
        Menu {
            SecurityElementKindOptions(select: onKindChange)
        } label: {
            HStack(spacing: 3) {
                Text(element.kind.label).font(.callout.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Typ prvku")
        .accessibilityValue(element.kind.label)
    }

    private var reviewIcon: String {
        switch element.reviewState {
        case .pending: return "questionmark.circle"
        case .confirmed: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        }
    }

    private var reviewColor: Color {
        switch element.reviewState {
        case .pending: return .orange
        case .confirmed: return .green
        case .rejected: return .secondary
        }
    }
}

/// Slovak count phrases: 1 strana, 2-4 strany, 5+ strán.
enum SlovakCount {
    static func phrase(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let word: String
        switch n {
        case 1: word = one
        case 2...4: word = few
        default: word = many
        }
        return "\(n) \(word)"
    }
}
