// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// The clause the engine appends to a PDF/A for the "one PDF" ZaKo output: its rendered pages
/// plus the machine-readable XDC, which becomes a PDF/A-3 associated file.
public struct AppendedClause: Codable, Sendable, Equatable {
    public static let xdcMimeType = "application/vnd.gov.sk.xmldatacontainer+xml"

    public var pages: Data
    public var attachment: Data
    public var attachmentName: String
    public var attachmentMimeType: String

    public init(pages: Data, attachment: Data, attachmentName: String,
                attachmentMimeType: String = AppendedClause.xdcMimeType) {
        self.pages = pages
        self.attachment = attachment
        self.attachmentName = attachmentName
        self.attachmentMimeType = attachmentMimeType
    }
}
