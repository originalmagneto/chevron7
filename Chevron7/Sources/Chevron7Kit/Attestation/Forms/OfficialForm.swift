// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// An official slovensko.sk form as an XMLDataContainer references it. The files and their
/// digests come from `docs/reference/forms` through `scripts/embed-official-forms.sh`.
public struct OfficialForm: Sendable, Equatable {
    public let identifier: String
    public let namespace: String
    public let version: String
    public let schema: Data
    /// A libxml2-compatible copy used only for local validation; identifiers, digests and
    /// XMLDataContainer references stay on `schema`. Equal to `schema` unless libxml2 rejects it.
    public let validationSchema: Data
    public let presentation: Data
    /// `MediaDestinationTypeDescription` of the signer presentation (`TXT` or `HTML`).
    public let presentationMediaDestination: String
    public let schemaDigestBase64: String
    public let presentationDigestBase64: String

    public var schemaURI: String { namespace + "/form.xsd" }
    public var presentationURI: String { namespace + "/form.xslt" }

    /// Záznam o vykonanej zaručenej konverzii 1.0, the form EZZK receives.
    public static let record_1_0 = OfficialForm(
        identifier: "http://data.gov.sk/doc/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0",
        namespace: "https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0",
        version: "1.0",
        schema: OfficialFormFiles.recordSchema,
        validationSchema: OfficialFormFiles.recordValidationSchema,
        presentation: OfficialFormFiles.recordPresentation,
        presentationMediaDestination: "TXT",
        schemaDigestBase64: OfficialFormFiles.recordSchemaDigest,
        presentationDigestBase64: OfficialFormFiles.recordPresentationDigest)

    /// Záznam o konverzii 1.2 (`_2021.sk`), the record form from 1. 1. 2027 (MIRRI's CEZZK
    /// page). libxml2 compiles its official schema, so validation uses it as is.
    public static let record_1_2 = OfficialForm(
        identifier: "http://data.gov.sk/doc/eform/50349287.ConversionRecordOfPaperToElectronicDocument_2021.sk/1.2",
        namespace: "http://schemas.gov.sk/form/50349287.ConversionRecordOfPaperToElectronicDocument_2021.sk/1.2",
        version: "1.2",
        schema: OfficialFormFiles.record12Schema,
        validationSchema: OfficialFormFiles.record12Schema,
        presentation: OfficialFormFiles.record12Presentation,
        presentationMediaDestination: "TXT",
        schemaDigestBase64: OfficialFormFiles.record12SchemaDigest,
        presentationDigestBase64: OfficialFormFiles.record12PresentationDigest)

    /// Osvedčovacia doložka 1.3, attached to the converted document.
    public static let clause_1_3 = OfficialForm(
        identifier: "http://data.gov.sk/doc/eform/50349287.ConversionCertificateOfPaperToElectronicDocument.sk/1.3",
        namespace: "http://schemas.gov.sk/form/50349287.ConversionCertificateOfPaperToElectronicDocument.sk/1.3",
        version: "1.3",
        schema: OfficialFormFiles.clauseSchema,
        validationSchema: OfficialFormFiles.clauseSchema,
        presentation: OfficialFormFiles.clausePresentation,
        presentationMediaDestination: "HTML",
        schemaDigestBase64: OfficialFormFiles.clauseSchemaDigest,
        presentationDigestBase64: OfficialFormFiles.clausePresentationDigest)
}
