// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import Foundation
/// Metadata observed in Podpisuj's P2E v1.2 artifacts.
/// This profile is retained for validating existing reference fixtures.
public struct P2EConformanceProfile: Sendable, Equatable {
    public let xdcfNamespace: String
    public let clauseNamespace: String
    public let clauseIdentifier: String
    public let clauseRoot: String
    public let clauseVersion: String
    public let recordNamespace: String
    public let recordIdentifier: String
    public let recordRoot: String
    public let recordVersion: String
    public let xdcfMimeType: String
    public let pdfMimeType: String
    public let pdfa2Code: String
    public let pdfa2Name: String
    public let sha256Code: String
    public let sha256Name: String
    public let evidenceURIBase: String

    public init(
        xdcfNamespace: String,
        clauseNamespace: String,
        clauseIdentifier: String,
        clauseRoot: String,
        clauseVersion: String,
        recordNamespace: String,
        recordIdentifier: String,
        recordRoot: String,
        recordVersion: String,
        xdcfMimeType: String = ASiCEPackager.xdcfMimeType,
        pdfMimeType: String = "application/pdf",
        pdfa2Code: String = "PDFA2",
        pdfa2Name: String = "PDF/A-2",
        sha256Code: String = "SHA-256",
        sha256Name: String = "SHA-256",
        evidenceURIBase: String = "https://data.gov.sk/id/egov/conversion-record/") {
        self.xdcfNamespace = xdcfNamespace
        self.clauseNamespace = clauseNamespace
        self.clauseIdentifier = clauseIdentifier
        self.clauseRoot = clauseRoot
        self.clauseVersion = clauseVersion
        self.recordNamespace = recordNamespace
        self.recordIdentifier = recordIdentifier
        self.recordRoot = recordRoot
        self.recordVersion = recordVersion
        self.xdcfMimeType = xdcfMimeType
        self.pdfMimeType = pdfMimeType
        self.pdfa2Code = pdfa2Code
        self.pdfa2Name = pdfa2Name
        self.sha256Code = sha256Code
        self.sha256Name = sha256Name
        self.evidenceURIBase = evidenceURIBase
    }

    /// Official current P2E clause target. The CEZZK record is v1.0 until 2027-01-01 and
    /// v1.2 from then (`FormPackRepository.record12Unverified`, `OfficialForm.record_1_2`).
    public static let targetV1_3 = P2EConformanceProfile(
        xdcfNamespace: "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
        clauseNamespace: "http://schemas.gov.sk/form/50349287.ConversionCertificateOfPaperToElectronicDocument.sk/1.3",
        clauseIdentifier: "http://data.gov.sk/doc/eform/50349287.ConversionCertificateOfPaperToElectronicDocument.sk/1.3",
        clauseRoot: "ConversionCertificateOfPaperToElectronicDocument",
        clauseVersion: "1.3",
        recordNamespace: "https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0",
        recordIdentifier: "http://data.gov.sk/doc/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0",
        recordRoot: "ConversionRecord",
        recordVersion: "1.0")

    /// Metadata observed in Podpisuj's current P2E v1.2 artifacts.
    public static let referenceV1_2 = P2EConformanceProfile(
        xdcfNamespace: "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
        clauseNamespace: "http://schemas.gov.sk/form/50349287.ConversionCertificateOfPaperToElectronicDocument/1.2",
        clauseIdentifier: "http://data.gov.sk/doc/eform/50349287.ConversionCertificateOfPaperToElectronicDocument/1.2",
        clauseRoot: "ConversionCertificateOfPaperToElectronicDocument",
        clauseVersion: "1.2",
        recordNamespace: "https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0",
        recordIdentifier: "http://data.gov.sk/doc/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0",
        recordRoot: "ConversionRecord",
        recordVersion: "1.0")

    public static let officialClauseV1_3MetadataURL = URL(
        string: "https://formulare.slovensko.sk/_layouts/eFLCM/DetailVzoruEFormulara.aspx?vid=50349287.ConversionCertificateOfPaperToElectronicDocument.sk&vh=1&vl=3")!

    public static let officialClauseV1_3ArchiveURL = URL(
        string: "https://formulare.slovensko.sk/_layouts/eFLCM/GetEFormArtefact.aspx?ac=4&vid=50349287.ConversionCertificateOfPaperToElectronicDocument.sk&sid=&vh=1&vl=3")!

    public static let officialCEZZKDocumentationURL = URL(
        string: "https://mirri.gov.sk/sekcie/informatizacia/dokumenty/zakon-o-e-governmente/centralna-evidencia-zaznamov-o-vykonanej-zarucenej-konverzii/")!

    public static func sha256Base64(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }
}
