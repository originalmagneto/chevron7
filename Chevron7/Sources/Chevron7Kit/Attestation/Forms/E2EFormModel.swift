// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import Foundation

/// Every value the E→E clause 1.3 and record 1.0 carry, derived once so the two cannot
/// disagree: the original read by `ElectronicOriginal`, the new document actually delivered,
/// and the conversion data from the ZaKo state.
public struct E2EFormModel: Sendable, Equatable {
    public struct NewDocument: Sendable, Equatable {
        public var name: String
        public var format: ZakoCodelistItem
        public var formatOther: String?
        public var sha256: Data
    }

    public var original: ElectronicOriginal
    /// "Druh dokumentu" (record only), e.g. "zmluva o pôžičke".
    public var originalDocumentType: String
    public var newDocument: NewDocument
    public var evidenceNumber: String
    public var usedDevice: String
    public var conversionTime: Date
    public var person: ConversionFormModel.Person
    /// A qualified validation service's sealed output; without it each authorization carries
    /// its own slim ETSI report from Chevron7's validation.
    public var qualifiedReport: Data?

    public var conversionTimeText: String { ConversionFormModel.bratislavaDateTime(conversionTime) }
    public var evidenceNumberURI: String { ZakoCodelists.conversionRecordURI(evidenceNumber: evidenceNumber) }

    /// `newDocumentData` is exactly what the client receives inside the container: the original
    /// PDF when it is kept, else the converted PDF/A-2b.
    public static func make(original: ElectronicOriginal, attestation d: AttestationData, newDocumentName: String,
                            newDocumentData: Data, usedDevice: String, qualifiedReport: Data?) throws -> E2EFormModel {
        let evidenceNumber = (d.evidenceNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidenceNumber.isEmpty else { throw AttestationGenerationError.missingEvidenceNumber }
        let names = ConversionFormModel.nameParts(d.performingPerson.fullName)
        guard !names.given.isEmpty, !names.family.isEmpty else { throw AttestationGenerationError.incompletePersonName }
        let typeLabel = d.originalDocumentTypeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let office = d.performingPerson.officeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let format: (ZakoCodelistItem, String?)
        switch original.plan {
        case .keep(let item, let other): format = (item, other)
        case .convert: format = (E2ECodelists.pdfa2Format, nil)
        }
        return E2EFormModel(
            original: original,
            originalDocumentType: typeLabel.isEmpty ? (original.documents.first?.name ?? "Dokument") : typeLabel,
            newDocument: NewDocument(name: newDocumentName, format: format.0, formatOther: format.1,
                                     sha256: Data(SHA256.hash(data: newDocumentData))),
            evidenceNumber: evidenceNumber,
            usedDevice: usedDevice,
            conversionTime: d.conversionExecutionDateTime,
            person: ConversionFormModel.Person(
                givenName: names.given, familyName: names.family,
                position: d.performingPerson.position.trimmingCharacters(in: .whitespacesAndNewlines),
                legalSubjectName: office.isEmpty ? d.performingPerson.fullName : office,
                legalSubjectURI: ZakoCodelists.legalSubjectURI(ico: d.performingPerson.ico)),
            qualifiedReport: qualifiedReport)
    }

    /// The record's `ValidityVerificationResult` of one authorization, base64.
    public func validityVerificationResult(_ authorization: ElectronicOriginal.Authorization) -> String {
        (qualifiedReport ?? authorization.slimReport).base64EncodedString()
    }
}

/// Renders the E→E clause 1.3 in the element order of its official schema; codelists carry code
/// and Slovak name, the evidence number is a URI, as in the P→E clause.
public struct ConversionCertificateE2ERenderer: Sendable {
    public init() {}

    public func render(_ m: E2EFormModel) -> String {
        var x = "<ConversionCertificateOfElectronicDocumentToElectronicDocument xmlns=\"\(OfficialForm.clauseE2E_1_3.namespace)\">"
        for document in m.original.documents {
            x += "<OriginalDocumentInfo>"
            x += element("OriginalDocumentName", document.name)
            x += "<OriginalDocumentFormat>\(codelist(E2ECodelists.documentFormat, document.format))</OriginalDocumentFormat>"
            if let other = document.formatOther { x += element("OriginalDocumentFormatOther", other) }
            x += element("ElectronicFingerprintValue", document.sha256.base64EncodedString())
            x += "<ElectronicFingerprintCalculationMethod>\(codelist(E2ECodelists.fingerprintMethod, ZakoCodelists.sha256Item))</ElectronicFingerprintCalculationMethod>"
            x += "</OriginalDocumentInfo>"
        }
        x += "<OriginalDocumentAuthorization>"
        x += element("OriginalDocumentAuthorizationOccurance", m.original.authorizations.isEmpty ? "false" : "true")
        for authorization in m.original.authorizations {
            x += "<OriginalDocumentAuthorization>"
            x += "<AuthorizationType>\(codelist(E2ECodelists.authorizationType, authorization.type))</AuthorizationType>"
            if let other = authorization.typeOther { x += element("AuthorizationTypeOther", other) }
            for name in authorization.documentNames {
                x += "<AuthorizedDocument>\(element("AuthorizedDocumentName", name))</AuthorizedDocument>"
            }
            x += "<AuthorizationState>\(codelist(E2ECodelists.validityState, authorization.state.item))</AuthorizationState>"
            if let time = authorization.signingTime {
                x += element("AuthorizationTime", ConversionFormModel.bratislavaDateTime(time))
            }
            x += element("AuthorizationValidationTime", ConversionFormModel.bratislavaDateTime(authorization.validationTime))
            x += element("AuthorizationLocation", authorization.location)
            x += "<AuthorizationPerson>"
            x += element("PersonID", authorization.personID)
            if let mandant = authorization.mandant { x += element("Mandant", mandant) }
            if let mandate = authorization.mandate { x += element("Mandate", mandate) }
            x += "</AuthorizationPerson>"
            if let timestamp = authorization.timestamp {
                x += "<TimeStamp>"
                x += "<TimeStampType>\(codelist(E2ECodelists.timestampType, timestamp.typeItem))</TimeStampType>"
                x += "<TimeStampState>\(codelist(E2ECodelists.validityState, timestamp.state.item))</TimeStampState>"
                x += element("TimeStampCreated", ConversionFormModel.bratislavaDateTime(timestamp.created))
                x += element("TimeStampPublisher", timestamp.publisherCommonName)
                x += element("TimeStampValidationTime", ConversionFormModel.bratislavaDateTime(timestamp.validationTime))
                x += "</TimeStamp>"
            }
            x += element("OtherAuthorizationInfo", authorization.otherInfo)
            x += "</OriginalDocumentAuthorization>"
        }
        x += "</OriginalDocumentAuthorization>"
        x += "<NewDocumentInfo>"
        x += element("NewDocumentName", m.newDocument.name)
        x += "<NewDocumentFormat>\(codelist(E2ECodelists.documentFormat, m.newDocument.format))</NewDocumentFormat>"
        if let other = m.newDocument.formatOther { x += element("NewDocumentFormatOther", other) }
        x += element("ElectronicFingerprintValue", m.newDocument.sha256.base64EncodedString())
        x += "<ElectronicFingerprintCalculationMethod>\(codelist(E2ECodelists.fingerprintMethod, ZakoCodelists.sha256Item))</ElectronicFingerprintCalculationMethod>"
        x += "</NewDocumentInfo>"
        x += element("ConversionRecordEvidenceNumber", m.evidenceNumberURI)
        x += element("ConversionExecutionDateTime", m.conversionTimeText)
        x += "<PersonPerformingConversion><PersonData><PhysicalPerson><PersonName>"
        x += element("GivenName", m.person.givenName)
        x += element("FamilyName", m.person.familyName)
        x += "</PersonName>"
        if !m.person.position.isEmpty { x += element("Position", m.person.position) }
        x += "</PhysicalPerson>"
        x += "<LegalSubject>\(element("Name", m.person.legalSubjectName))</LegalSubject>"
        if let uri = m.person.legalSubjectURI {
            x += "<ID><IdentifierType>\(codelist(ZakoCodelists.identifierType, ZakoCodelists.icoIdentifierItem))</IdentifierType>"
            x += element("IdentifierValue", uri) + "</ID>"
        }
        x += "</PersonData></PersonPerformingConversion>"
        x += "</ConversionCertificateOfElectronicDocumentToElectronicDocument>"
        return x
    }

    private func element(_ name: String, _ value: String) -> String {
        "<\(name)>\(AttestationClauseGenerator.escape(value))</\(name)>"
    }

    private func codelist(_ code: Int, _ item: ZakoCodelistItem) -> String {
        "<Codelist><CodelistCode>\(code)</CodelistCode><CodelistItem><ItemCode>\(AttestationClauseGenerator.escape(item.code))</ItemCode><ItemName Language=\"sk\">\(AttestationClauseGenerator.escape(item.skName))</ItemName></CodelistItem></Codelist>"
    }
}

/// Renders the E→E record 1.0: plain strings where the schema has `MandatoryStringType` (as the
/// P→E record EZZK accepted carries item names), the plain evidence number, person data last.
public struct ConversionRecordE2ERenderer: Sendable {
    public init() {}

    public func render(_ m: E2EFormModel) -> String {
        var x = "<ConversionRecord xmlns=\"\(OfficialForm.recordE2E_1_0.namespace)\">"
        for document in m.original.documents {
            x += "<OriginalDocumentInfo>"
            x += element("OriginalDocumentName", document.name)
            x += element("OriginalDocumentType", m.originalDocumentType)
            x += element("OriginalDocumentFormat", document.formatOther ?? document.format.skName)
            x += element("ElectronicFingerprintValue", document.sha256.base64EncodedString())
            x += element("ElectronicFingerprintCalculationMethod", ZakoCodelists.sha256Item.code)
            x += "</OriginalDocumentInfo>"
        }
        x += "<OriginalDocumentAuthorization>"
        x += element("OriginalDocumentAuthorizationOccurance", m.original.authorizations.isEmpty ? "false" : "true")
        for authorization in m.original.authorizations {
            x += "<OriginalDocumentAuthorization>"
            x += element("AuthorizationType", authorization.typeOther ?? authorization.type.skName)
            for name in authorization.documentNames {
                x += "<AuthorizedDocument>\(element("AuthorizedDocumentName", name))</AuthorizedDocument>"
            }
            x += element("AuthorizationState", authorization.state.rawValue)
            if let time = authorization.signingTime {
                x += element("AuthorizationTime", ConversionFormModel.bratislavaDateTime(time))
            }
            x += element("ElectronicSignature", authorization.signatureValue.base64EncodedString())
            x += element("ValidityVerificationResult", m.validityVerificationResult(authorization))
            x += element("AuthorizationValidationTime", ConversionFormModel.bratislavaDateTime(authorization.validationTime))
            x += element("AuthorizationLocation", authorization.location)
            x += "<AuthorizationPerson>"
            x += element("PersonID", authorization.personID)
            if let mandant = authorization.mandant { x += element("Mandant", mandant) }
            if let mandate = authorization.mandate { x += element("Mandate", mandate) }
            x += "</AuthorizationPerson>"
            if let timestamp = authorization.timestamp {
                x += "<TimeStamp>"
                x += element("TimeStampType", timestamp.typeItem.skName)
                x += element("TimeStampState", timestamp.state.rawValue)
                x += element("TimeStampCreated", ConversionFormModel.bratislavaDateTime(timestamp.created))
                x += element("TimeStampPublisher", timestamp.publisherCommonName)
                x += element("TimeStampValidationTime", ConversionFormModel.bratislavaDateTime(timestamp.validationTime))
                x += "</TimeStamp>"
            }
            x += element("OtherAuthorizationInfo", authorization.otherInfo)
            x += "</OriginalDocumentAuthorization>"
        }
        x += "</OriginalDocumentAuthorization><NewDocumentInfo>"
        x += element("NewDocumentName", m.newDocument.name)
        x += element("NewDocumentFormat", m.newDocument.formatOther ?? m.newDocument.format.skName)
        x += element("ElectronicFingerprintValue", m.newDocument.sha256.base64EncodedString())
        x += element("ElectronicFingerprintCalculationMethod", ZakoCodelists.sha256Item.code)
        x += "</NewDocumentInfo>"
        x += element("ConversionRecordEvidenceNumber", m.evidenceNumber)
        x += element("UsedDevice", m.usedDevice)
        x += element("ConversionExecutionDateTime", m.conversionTimeText)
        x += "<PersonPerformingConversion><PersonData><PhysicalPerson><PersonName>"
        x += element("GivenName", m.person.givenName)
        x += element("FamilyName", m.person.familyName)
        x += "</PersonName>"
        x += element("Position", m.person.position.isEmpty ? "advokát" : m.person.position)
        x += "</PhysicalPerson>"
        x += "<LegalSubject>\(element("Name", m.person.legalSubjectName))</LegalSubject>"
        if let uri = m.person.legalSubjectURI, ConversionRecordRenderer.recordAcceptsIdentifier(uri) {
            x += "<ID><IdentifierType><Codelist><CodelistCode>\(ZakoCodelists.identifierType)</CodelistCode><CodelistItem>"
            x += "<ItemCode>\(AttestationClauseGenerator.escape(ZakoCodelists.icoIdentifierItem.code))</ItemCode>"
            x += "<ItemName Language=\"sk\">\(AttestationClauseGenerator.escape(ZakoCodelists.icoIdentifierItem.skName))</ItemName>"
            x += "</CodelistItem></Codelist></IdentifierType>"
            x += element("IdentifierValue", uri) + "</ID>"
        }
        x += "</PersonData></PersonPerformingConversion></ConversionRecord>"
        return x
    }

    private func element(_ name: String, _ value: String) -> String {
        "<\(name)>\(AttestationClauseGenerator.escape(value))</\(name)>"
    }
}
