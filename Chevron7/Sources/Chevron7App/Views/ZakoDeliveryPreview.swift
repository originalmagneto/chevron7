// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Kit
import PDFKit
import SwiftUI

/// What the client receives, in words and file names, for the authorize step's "Čo podpíšete"
/// and the done step's summary. A name is given only when it is certain at that moment; the
/// clause's name needs the evidence number, which is allocated only after the card check.
struct ZakoDeliveryPlan: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        /// Inside the container above it.
        var indented = false
    }

    let output: AppSettings.ZakoClientOutput
    let items: [Item]
    let signatureNote: String

    var outputLabel: String { UXLabels.clientOutputLabel(output) ?? "" }

    /// - Parameters:
    ///   - documentName: the new document's name as the clause and the record carry it.
    ///   - clauseName: the clause file's name, nil while the evidence number is not known.
    ///   - containerName: the ASiC-E file's name, nil while it is not certain.
    static func make(output: AppSettings.ZakoClientOutput, documentName: String,
                     clauseName: String?, containerName: String?) -> ZakoDeliveryPlan {
        switch output {
        case .singlePDF:
            return ZakoDeliveryPlan(output: output, items: [
                Item(id: "document", symbol: "doc.richtext", title: documentName,
                     detail: "Nový dokument v PDF/A"),
                Item(id: "pages", symbol: "doc.text", title: "Osvedčovacia doložka",
                     detail: "pripojená ako posledné strany"),
                Item(id: "attachment", symbol: "paperclip", title: clauseName ?? "Doložka v XML",
                     detail: clauseName == nil
                        ? "príloha PDF, pomenovaná evidenčným číslom"
                        : "príloha PDF s doložkou v XML"),
            ], signatureNote: "Jeden kvalifikovaný podpis nad celým PDF")
        case .asicContainer:
            return ZakoDeliveryPlan(output: output, items: [
                Item(id: "container", symbol: "archivebox", title: containerName ?? "Súbor .asice",
                     detail: containerName == nil ? "pomenovaný podľa nového dokumentu" : "kontajner pre klienta"),
                Item(id: "document", symbol: "doc.richtext", title: documentName,
                     detail: "Nový dokument v PDF/A", indented: true),
                Item(id: "clause", symbol: "doc.text", title: clauseName ?? "Osvedčovacia doložka v XML",
                     detail: clauseName == nil ? "pomenovaná evidenčným číslom" : "Osvedčovacia doložka v XML",
                     indented: true),
            ], signatureNote: "Jeden kvalifikovaný podpis nad oboma súbormi")
        }
    }
}

extension ZakoSessionStore {
    /// What the client gets from this conversion. A stored record-first conversion names
    /// everything as it was fixed when its record was signed; otherwise the chosen output.
    var deliveryPlan: ZakoDeliveryPlan {
        if let pending = recordFirstPending {
            let documentName = pending.fixedTarget?.lastPathComponent ?? pending.containerDocumentName
            let clauseName = pending.appendedClause?.attachmentName
                ?? ConversionOutputNaming.containerClauseName(evidenceNumber: pending.evidenceNumber)
            return .make(output: pending.clientOutput, documentName: documentName, clauseName: clauseName,
                         containerName: pending.clientOutput == .asicContainer
                            ? ConversionOutputNaming.asicFileName(pdfFileName: pending.containerDocumentName)
                            : nil)
        }
        let documentName = ConversionOutputNaming.containerDocumentName(
            newDocumentName: attestation.newDocumentName,
            fallback: attestation.originalDocumentName)
        return .make(output: settings.zakoClientOutput, documentName: documentName, clauseName: nil,
                     containerName: nil)
    }

    /// The caption under the page preview: the first page of the new document, or for a
    /// container of several files the original's preview, which the new document joins.
    var deliveryPreviewCaption: String {
        if recordFirstPending == nil, direction == .electronicToElectronic,
           electronicOriginal?.kind == .asicEMultiple {
            return "Náhľad pôvodných súborov. Nový dokument ich spojí v poradí z overenia."
        }
        return "Prvá strana nového dokumentu"
    }
}

/// Page images for the previews, made once per document: the views redraw every 30 seconds
/// (their timelines), and the snapshot tests cannot wait for a `.task`.
@MainActor
final class ZakoPagePreviewCache {
    private var images: [ObjectIdentifier: NSImage] = [:]
    private var storedDocuments: [UUID: PDFDocument?] = [:]

    /// The document a conversion's preview shows: a stored record-first conversion's exact new
    /// document when its bytes read as a PDF, else the document open in ZaKo.
    func previewDocument(for store: ZakoSessionStore) -> PDFDocument? {
        if let pending = store.recordFirstPending {
            let stored: PDFDocument?
            if let cached = storedDocuments[pending.recordID] {
                stored = cached
            } else {
                stored = PDFDocument(data: pending.finalPDF).flatMap { $0.pageCount > 0 ? $0 : nil }
                storedDocuments[pending.recordID] = stored
            }
            if let stored { return stored }
        }
        return store.document.flatMap { $0.pageCount > 0 ? $0 : nil }
    }

    func firstPage(of document: PDFDocument) -> NSImage? {
        let key = ObjectIdentifier(document)
        if let image = images[key] { return image }
        guard let page = document.page(at: 0) else { return nil }
        let image = page.thumbnail(of: NSSize(width: 1100, height: 1100), for: .cropBox)
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        images[key] = image
        return image
    }
}

/// One page as paper: white, with a hairline border and a soft shadow.
struct ZakoPagePreview: View {
    let image: NSImage
    let accessibilityLabel: String

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isImage)
    }
}

/// The client's files as a short list: the container with its two files, or the one PDF with
/// its parts, then the one signature over them.
struct ZakoDeliveryPlanView: View {
    let plan: ZakoDeliveryPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Klient dostane")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(plan.outputLabel)
                    .font(.callout.weight(.semibold))
            }
            ForEach(plan.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(item.title)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, item.indented ? 22 : 0)
                .accessibilityElement(children: .combine)
            }
            Divider()
            Label(plan.signatureNote, systemImage: "signature")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Čo dostane klient")
    }
}

/// How the authorize step divides a wide window: the page and the client's files on the
/// left, the certificate and the checklist on the right. Nil when the area is too small for
/// the preview: the step then keeps its one scrolling column, so its minimum size never grows.
enum ZakoAuthorizeLayout {
    struct Columns: Equatable {
        /// The preview column's width, padding included.
        let previewWidth: CGFloat
        let detailsWidth: CGFloat
        /// The client's files beside the page (true) or below it.
        let planBesidePage: Bool
    }

    static let padding: CGFloat = 20
    static let headingHeight: CGFloat = 30
    static let planWidth: CGFloat = 280
    static let planGap: CGFloat = 24
    /// Room the client's files take below the page.
    static let planHeightBelow: CGFloat = 230
    static let minDetailsWidth: CGFloat = 420
    static let maxDetailsWidth: CGFloat = 640
    static let minHeight: CGFloat = 420

    /// - Parameter pageAspect: the first page's width over its height.
    static func columns(for size: CGSize, pageAspect: CGFloat) -> Columns? {
        guard size.height >= minHeight, pageAspect > 0 else { return nil }
        let pageHeight = size.height - 2 * padding - headingHeight
        let beside = (pageHeight * pageAspect).rounded(.up) + planGap + planWidth + 2 * padding
        if size.width - beside >= minDetailsWidth {
            return Columns(previewWidth: beside, detailsWidth: min(size.width - beside, maxDetailsWidth),
                           planBesidePage: true)
        }
        let pageWidth = min((pageHeight - planHeightBelow) * pageAspect, size.width - minDetailsWidth - 2 * padding)
        guard pageWidth >= planWidth else { return nil }
        let below = pageWidth.rounded(.up) + 2 * padding
        return Columns(previewWidth: below, detailsWidth: min(size.width - below, maxDetailsWidth),
                       planBesidePage: false)
    }
}

/// The done step's summary card: the conversion's document, number, output and environment,
/// with the record's times and the output folder once known. Pure values, tested without SwiftUI.
struct ZakoDoneSummary: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let label: String
        let value: String
        var isMonospaced = false
    }

    let rows: [Row]
    let mode: AppSettings.EZZKMode?
    let folder: String?

    static func make(pending: RecordFirstPending?, record: EvidenceRecord?, evidenceNumber: String?,
                     outputDirectory: URL?) -> ZakoDoneSummary? {
        guard pending != nil || record != nil else { return nil }
        var rows: [Row] = []
        if let name = pending?.fixedTarget?.lastPathComponent ?? pending?.containerDocumentName
            ?? record?.newDocumentName ?? record?.originalName, !name.isEmpty {
            rows.append(Row(id: "document", label: "Nový dokument", value: name))
        }
        if let number = evidenceNumber ?? record?.evidenceNumber ?? pending?.evidenceNumber, !number.isEmpty {
            rows.append(Row(id: "number", label: "Evidenčné číslo", value: number, isMonospaced: true))
        }
        if let output = UXLabels.clientOutputLabel(pending?.clientOutput ?? record?.clientOutput) {
            rows.append(Row(id: "output", label: "Výstup pre klienta", value: output))
        }
        if outputDirectory != nil, let delivered = record?.deliveredFileName {
            rows.append(Row(id: "delivered", label: "Súbor pre klienta", value: delivered))
        }
        let mode = pending?.mode ?? record?.ezzkMode
        if mode != nil {
            rows.append(Row(id: "environment", label: "Evidencia", value: ""))
        }
        if let signedAt = pending?.recordSignedAt {
            rows.append(Row(id: "signed", label: "Záznam o konverzii podpísaný",
                            value: EZZKRecordPresentation.timeText(signedAt)))
        }
        if let sentAt = record?.submittedAt {
            rows.append(Row(id: "sent", label: "Záznam odoslaný do EZZK",
                            value: EZZKRecordPresentation.timeText(sentAt)))
        }
        return ZakoDoneSummary(rows: rows, mode: mode, folder: outputDirectory?.path)
    }
}
