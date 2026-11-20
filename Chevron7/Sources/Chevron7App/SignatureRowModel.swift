// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// One signature (or one signed file) as `SignatureRowView` shows it, whichever screen it
/// comes from: the signature banner's bubble in signing, the Safari panel and ZaKo, and the
/// E→E verification's list of authorizations. Each source keeps its own wording.
struct SignatureRowModel: Equatable, Identifiable {
    enum Tone: Equatable {
        case valid, invalid, undetermined
        /// A file row (the signatures inside it follow).
        case neutral
        /// A file whose signatures could not be checked.
        case warning
    }

    let id: String
    let title: String
    let symbol: String
    let tone: Tone
    /// "Platný" in the banner, "platná" in the E→E list; nil for a file row.
    let verdictLabel: String?
    /// Qualification ("KEP", "Kvalifikovaná pečať", ...).
    let badges: [String]
    /// The signature this session added.
    let isNew: Bool
    /// Secondary facts, one line each, in order.
    let lines: [String]
    /// Why the validator did not call the signature valid, in Slovak.
    let reason: String?
    let warning: String?
    /// DSS's own (English) text, behind "Technický detail".
    let technicalDetail: String?
    let depth: Int

    // MARK: Signature banner

    init(_ row: SignatureBannerModel.Row) {
        id = row.id
        title = row.title
        if let verdict = row.verdict {
            symbol = SignatureTreePresentation.icon(verdict)
            switch verdict {
            case .valid: tone = .valid
            case .invalid: tone = .invalid
            case .indeterminate, .unknown: tone = .undetermined
            }
        } else if row.warning != nil {
            symbol = "exclamationmark.triangle.fill"
            tone = .warning
        } else {
            symbol = "doc.text"
            tone = .neutral
        }
        verdictLabel = row.verdict == nil ? nil : row.verdictLabel
        badges = row.badges
        isNew = row.isNew
        lines = [row.detail.isEmpty ? nil : row.detail, row.dataTimestamp, row.timestamp].compactMap { $0 }
        reason = row.reason
        warning = row.warning
        technicalDetail = nil
        depth = row.depth
    }

    // MARK: E→E verification

    /// `fileName` names the container file a nested PAdES signature sits in; `showsDocuments`
    /// lists the documents a signature covers when the original has several.
    init(authorization: ElectronicOriginal.Authorization, fileName: String?, showsDocuments: Bool) {
        id = Self.detailKey(authorization)
        title = authorization.signerName
        switch authorization.state {
        case .valid:
            symbol = "checkmark.seal.fill"
            tone = .valid
        case .invalid:
            symbol = "xmark.seal.fill"
            tone = .invalid
        case .undetermined:
            symbol = "questionmark.diamond.fill"
            tone = .undetermined
        }
        verdictLabel = authorization.state.rawValue
        badges = []
        isNew = false
        var lines = [authorization.typeOther ?? authorization.type.skName]
        if let time = authorization.signingTime {
            lines.append("Podpísané \(E2EDateText.string(time))")
        }
        if let mandate = authorization.mandate {
            lines.append("Mandát: \(mandate)")
        }
        if let timestamp = authorization.timestamp {
            lines.append("Časová pečiatka \(timestamp.typeItem.skName.lowercased()), \(timestamp.state.rawValue): "
                + "\(timestamp.publisherCommonName), \(E2EDateText.string(timestamp.created))")
        } else {
            lines.append("Bez časovej pečiatky")
        }
        if let fileName {
            lines.append("Podpis v súbore \(fileName)")
        }
        if showsDocuments {
            lines.append("Pokrýva \(authorization.documentNames.joined(separator: ", "))")
        }
        self.lines = lines
        // The verification step says why above the list, in its notice.
        reason = nil
        warning = nil
        technicalDetail = authorization.technicalDetail
        depth = 0
    }

    /// Tells the same signature in two files apart, so each "Technický detail" opens on its own.
    static func detailKey(_ authorization: ElectronicOriginal.Authorization) -> String {
        "\(authorization.fileEntryName ?? "")|\(authorization.signatureID)"
    }
}
