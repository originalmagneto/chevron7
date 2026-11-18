// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Renders the E→E record 1.2 (`50349287.ConversionRecordOfElectronicDocumentToElectronicDocument_2021.sk`),
/// the record form of the order from 1. 1. 2027, in the element order of its official schema
/// (spec 2026-11-18 section 7.2). It carries the values record 1.0 carries where the forms agree;
/// where 1.2 differs it uses its enums (authorization type, state in the masculine, timestamp
/// type, certificate type), `https://` codelist codes (CL009008, CL009009, CL009005), hex
/// fingerprints, names for authorizations and timestamps with the references between them, the
/// evidence number as a URI and no `Position` or `AuthorizationLocation`.
///
/// It never substitutes a value it cannot map: an unmappable authorization type or format is
/// written empty, which the schema refuses, and `E2EDeliveryBuilder` refuses it before rendering;
/// a timestamp it cannot name makes `render` throw.
public struct ConversionRecordE2E12Renderer: Sendable {
    public init() {}

    // MARK: Mappings

    /// The `AuthorizationTypeEnum` value for a DSS `SignatureQualification`; seals and signatures
    /// are told apart by QcType where DSS says `NOT_ADES*`. Nil for anything else (`QES`,
    /// `ADES_QC`, `ADES`, `NA`, `INDETERMINATE_*`, empty), which the new order refuses.
    public static func authorizationType(qualification: String?, qcType: String?) -> String? {
        let value = (qualification ?? "").uppercased()
        switch value {
        case "QESIG": return "kvalifikovaný elektronický podpis"
        case "ADESIG_QC": return "zdokonalený elektronický podpis s použitím kvalifikovaného certifikátu"
        case "ADESIG": return "zdokonalený elektronický podpis"
        case "QESEAL": return "kvalifikovaná elektronická pečať"
        case "ADESEAL_QC": return "zdokonalená elektronická pečať s použitím kvalifikovaného certifikátu"
        case "ADESEAL": return "zdokonalená elektronická pečať"
        default:
            guard value.hasPrefix("NOT_ADES") else { return nil }
            return qcType == "eseal" ? "elektronická pečať" : "elektronický podpis"
        }
    }

    /// The `CertificateTypeEnum` value the qualification decides; nil (the element omitted)
    /// otherwise. The first value has a hyphen, the second an en dash, as in the schema.
    public static func certificateType(qualification: String?) -> String? {
        switch (qualification ?? "").uppercased() {
        case "QESIG", "QESEAL": return "certifikát - kvalifikovaný, certifikát je na QSCD"
        case "ADESIG_QC", "ADESEAL_QC": return "certifikát \u{2013} kvalifikovaný, certifikát nie je na QSCD"
        default: return nil
        }
    }

    /// Authorizations whose qualification has no record 1.2 `AuthorizationType`.
    public static func unmappableAuthorizations(_ original: ElectronicOriginal) -> [ElectronicOriginal.Authorization] {
        original.authorizations.filter { authorizationType(qualification: $0.qualification, qcType: $0.qcType) == nil }
    }

    /// CL009008 item (and `OriginalDocumentFormatOther`) of an original document, from the
    /// codelist 53 item `ElectronicOriginal` gives it. Nil for a format it does not know.
    static func originalDocumentFormat(_ document: ElectronicOriginal.Document) -> (item: ZakoCodelistItem, other: String?)? {
        switch (document.format.code, document.formatOther) {
        case (E2ECodelists.pdfFormat.code, nil): return (ZakoCodelists.record12OriginalFormatPDF, nil)
        case (E2ECodelists.pdfa1Format.code, nil): return (ZakoCodelists.record12OriginalFormatPDFA1, nil)
        case (E2ECodelists.pdfa2Format.code, nil): return (ZakoCodelists.record12OriginalFormatPDFA2, nil)
        case (E2ECodelists.pngFormat.code, nil): return (ZakoCodelists.record12OriginalFormatPNG, nil)
        case (E2ECodelists.otherFormat.code, ZakoCodelists.pdfa3FormatName?): return (ZakoCodelists.record12OriginalFormatPDFA3, nil)
        case (E2ECodelists.otherFormat.code, let other?)
            where !other.isEmpty && other.count <= 30 && other != ZakoCodelists.pdfa3FormatName:
            return (ZakoCodelists.record12OriginalFormatOther, other)
        default: return nil
        }
    }

    /// CL009009 item of the new document: the kept PDF/A part, the converted PDF/A-2, or PDF/A-3
    /// for the one PDF. Nil for anything else (record 1.2 has no `NewDocumentFormatOther`).
    static func newDocumentFormat(_ document: E2EFormModel.NewDocument) -> ZakoCodelistItem? {
        switch (document.format.code, document.formatOther) {
        case (E2ECodelists.pdfa1Format.code, nil): return ZakoCodelists.record12PDFA1Item
        case (E2ECodelists.pdfa2Format.code, nil): return ZakoCodelists.record12PDFA2Item
        case (E2ECodelists.otherFormat.code, ZakoCodelists.pdfa3FormatName?): return ZakoCodelists.record12PDFA3Item
        default: return nil
        }
    }

    /// `AuthorizationOrTimeStampStateEnum`, masculine (record 1.0 and the clause are feminine).
    static func state(_ state: ElectronicOriginal.ValidityState) -> String {
        switch state {
        case .valid: return "platný"
        case .invalid: return "neplatný"
        case .undetermined: return "nie je možné zistiť"
        }
    }

    static func timestampType(qualified: Bool) -> String {
        qualified ? "kvalifikovaná elektronická časová pečiatka" : "nekvalifikovaná elektronická časová pečiatka"
    }

    /// `AuthorizationName` per authorization: the file name of its signature file in the
    /// container, when no other authorization shares it; else `Autorizacia1`, `Autorizacia2`, ...
    /// in authorization order, as the schema says when the file name cannot be used.
    static func authorizationNames(_ authorizations: [ElectronicOriginal.Authorization]) -> [String] {
        let files = authorizations.map { $0.signatureFilename.map { ($0 as NSString).lastPathComponent } }
        let usable = files.map { file in file.flatMap { name in
            !name.isEmpty && files.filter { $0 == name }.count == 1 ? String(name.prefix(255)) : nil
        } }
        let taken = Set(usable.compactMap { $0 })
        var counter = 0
        return usable.map { name in
            if let name { return name }
            repeat { counter += 1 } while taken.contains("Autorizacia\(counter)")
            return "Autorizacia\(counter)"
        }
    }

    /// Whether the authorization is a PAdES signature of a PDF (of the original or of a
    /// container's file), as opposed to a container signature.
    static func isPAdES(_ authorization: ElectronicOriginal.Authorization, in original: ElectronicOriginal) -> Bool {
        original.kind == .pdf || authorization.fileEntryName != nil
    }

    /// The latest PAdES signatures of a file before `length` (nil for no limit), as indices
    /// into `original.authorizations`; several only when they share one signed revision.
    private static func latestPAdES(file: String?, before length: Int?, in original: ElectronicOriginal) -> [Int] {
        let candidates = original.authorizations.indices.filter { index in
            let other = original.authorizations[index]
            guard isPAdES(other, in: original), other.fileEntryName == file,
                  let otherLength = other.signedRevisionLength else { return false }
            return length.map { otherLength < $0 } ?? true
        }
        guard let latest = candidates.compactMap({ original.authorizations[$0].signedRevisionLength }).max() else { return [] }
        return candidates.filter { original.authorizations[$0].signedRevisionLength == latest }
    }

    /// The files (entry names) a container signature covers.
    private static func coveredFiles(_ authorization: ElectronicOriginal.Authorization,
                                     in original: ElectronicOriginal) -> [String] {
        (original.evidence.pdf?.dataObjects ?? []).filter { $0.coveredBy.contains(authorization.signatureID) }.map(\.name)
    }

    /// Indices of the authorizations one authorization covers (`AuthorizedAuthorization`), nested
    /// ones not repeated (the schema's annotation): a PAdES signature names only the immediately
    /// preceding PAdES signature of its file (by signed revision length); a container signature
    /// names only the latest PAdES signature of each file it covers.
    static func authorizedAuthorizations(of index: Int, in original: ElectronicOriginal) -> [Int] {
        let authorization = original.authorizations[index]
        if isPAdES(authorization, in: original) {
            guard let length = authorization.signedRevisionLength else { return [] }
            return latestPAdES(file: authorization.fileEntryName, before: length, in: original)
        }
        let files = Set(coveredFiles(authorization, in: original))
        return original.authorizations.indices.filter { other in
            guard let file = original.authorizations[other].fileEntryName, files.contains(file) else { return false }
            return latestPAdES(file: file, before: nil, in: original).contains(other)
        }
    }

    /// XAdES content timestamps a container signature carries in its signed properties, which it
    /// therefore authorizes (`AuthorizedTimeStamp`).
    static func authorizedContentTimestamps(of authorization: ElectronicOriginal.Authorization,
                                            in original: ElectronicOriginal) -> [ElectronicOriginal.ContentTimestamp] {
        guard !isPAdES(authorization, in: original) else { return [] }
        return original.contentTimestamps.filter { $0.signatureID == authorization.signatureID }
    }

    /// Document timestamps one authorization covers (`AuthorizedTimeStamp`), none named twice: a
    /// PAdES signature names those of its file from the preceding PAdES revision up to its own; a
    /// container signature names those of each covered file that no PAdES signature names (from
    /// the file's last PAdES revision on, or all of them when the file has no PAdES).
    static func authorizedTimestamps(of authorization: ElectronicOriginal.Authorization,
                                     in original: ElectronicOriginal) -> [ElectronicOriginal.DocumentTimestamp] {
        func revisionLength(_ indices: [Int]) -> Int {
            indices.compactMap { original.authorizations[$0].signedRevisionLength }.max() ?? 0
        }
        if isPAdES(authorization, in: original) {
            guard let length = authorization.signedRevisionLength else { return [] }
            let from = revisionLength(latestPAdES(file: authorization.fileEntryName, before: length, in: original))
            return original.documentTimestamps.filter {
                $0.fileEntryName == authorization.fileEntryName
                    && $0.coveredRevisionLength >= from && $0.coveredRevisionLength < length
            }
        }
        let files = coveredFiles(authorization, in: original)
        return original.documentTimestamps.filter { stamp in
            guard let file = stamp.fileEntryName, files.contains(file) else { return false }
            return stamp.coveredRevisionLength >= revisionLength(latestPAdES(file: file, before: nil, in: original))
        }
    }

    // MARK: Rendering

    public func render(_ m: E2EFormModel) throws -> String {
        let original = m.original
        let timestampName = Self.timestampNames(original)

        var x = "<ConversionRecord xmlns=\"\(OfficialForm.recordE2E_1_2.namespace)\">"
        for (index, document) in original.documents.enumerated() {
            x += "<OriginalDocumentInfo>"
            x += element("OriginalDocumentName", document.name)
            x += element("OriginalDocumentType", m.originalDocumentTypes[index])
            let format = Self.originalDocumentFormat(document)
            x += "<OriginalDocumentFormat>\(codelist(ZakoCodelists.record12OriginalFormatCode, format?.item))</OriginalDocumentFormat>"
            if let other = format?.other { x += element("OriginalDocumentFormatOther", other) }
            x += element("ElectronicFingerprintValue", Self.hex(document.sha256))
            x += "<ElectronicFingerprintCalculationMethod>\(codelist(ZakoCodelists.record12FingerprintMethodCode, ZakoCodelists.record12SHA256Item))</ElectronicFingerprintCalculationMethod>"
            x += "</OriginalDocumentInfo>"
        }
        for stamp in original.documentTimestamps {
            x += "<OriginalDocumentTimestamp>"
            x += element("TimeStampName", try timestampName(stamp.fileEntryName, stamp.id, nil))
            x += "<OriginalDocumentInfo>\(element("OriginalDocumentName", stamp.documentName))</OriginalDocumentInfo>"
            x += timestampBody(stamp.timestamp, publisherLimit: 255)
            x += "</OriginalDocumentTimestamp>"
        }
        for stamp in original.contentTimestamps {
            x += "<OriginalDocumentTimestamp>"
            x += element("TimeStampName", try timestampName(nil, stamp.id, nil))
            for name in stamp.documentNames {
                x += "<OriginalDocumentInfo>\(element("OriginalDocumentName", name))</OriginalDocumentInfo>"
            }
            x += timestampBody(stamp.timestamp, publisherLimit: 255)
            x += "</OriginalDocumentTimestamp>"
        }
        let names = Self.authorizationNames(original.authorizations)
        for (index, authorization) in original.authorizations.enumerated() {
            x += "<Authorization>"
            x += element("AuthorizationName", names[index])
            x += element("AuthorizationType", Self.authorizationType(qualification: authorization.qualification,
                                                                     qcType: authorization.qcType) ?? "")
            x += "<OriginalDocumentAuthorization>"
            for name in authorization.documentNames {
                x += "<OriginalDocumentInfo>\(element("OriginalDocumentName", name))</OriginalDocumentInfo>"
            }
            for stamp in Self.authorizedTimestamps(of: authorization, in: original) {
                x += "<AuthorizedTimeStamp>\(element("AuthorizedTimeStampName", try timestampName(stamp.fileEntryName, stamp.id, nil)))</AuthorizedTimeStamp>"
            }
            for stamp in Self.authorizedContentTimestamps(of: authorization, in: original) {
                x += "<AuthorizedTimeStamp>\(element("AuthorizedTimeStampName", try timestampName(nil, stamp.id, nil)))</AuthorizedTimeStamp>"
            }
            for other in Self.authorizedAuthorizations(of: index, in: original) {
                x += "<AuthorizedAuthorization>\(element("AuthorizationName", names[other]))</AuthorizedAuthorization>"
            }
            x += element("AuthorizationState", Self.state(authorization.state))
            if let time = authorization.signingTime {
                x += element("AuthorizationTime", ConversionFormModel.bratislavaDateTime(time))
            }
            // Obligatory for every signature and seal type; `E2EDeliveryBuilder` refuses an empty value.
            x += element("ElectronicSignature", authorization.signatureValue.base64EncodedString())
            x += element("ValidityVerificationResult", m.validityVerificationResult(authorization))
            x += element("AuthorizationValidationTime", ConversionFormModel.bratislavaDateTime(authorization.validationTime))
            x += "<AuthorizationPerson>"
            x += element("PersonID", String(authorization.personID.prefix(255)))
            x += element("Mandant", Self.nonEmpty(authorization.mandant) ?? "Žiadna")
            x += element("Mandate", Self.nonEmpty(authorization.mandate) ?? "Žiaden")
            x += "</AuthorizationPerson>"
            if let timestamp = authorization.timestamp {
                x += "<TimeStamp>"
                x += element("TimeStampName", try timestampName(authorization.fileEntryName, timestamp.id, index))
                x += timestampBody(timestamp, publisherLimit: 2047)
                x += "</TimeStamp>"
            }
            if let certificate = Self.certificateType(qualification: authorization.qualification) {
                x += element("CertificateType", certificate)
            }
            x += element("OtherAuthorizationInfo", authorization.otherInfo)
            x += "</OriginalDocumentAuthorization></Authorization>"
        }
        x += "<NewDocumentInfo>"
        x += element("NewDocumentName", m.newDocument.name)
        x += element("NewDocumentType", m.originalDocumentType)
        x += element("ContentType", "application/pdf")
        x += "<NewDocumentFormat>\(codelist(ZakoCodelists.record12NewDocumentFormatCode, Self.newDocumentFormat(m.newDocument)))</NewDocumentFormat>"
        x += element("ElectronicFingerprintValue", Self.hex(m.newDocument.sha256))
        x += "<ElectronicFingerprintCalculationMethod>\(codelist(ZakoCodelists.record12FingerprintMethodCode, ZakoCodelists.record12SHA256Item))</ElectronicFingerprintCalculationMethod>"
        x += "</NewDocumentInfo>"
        x += element("ConversionRecordEvidenceNumber", m.evidenceNumberURI)
        x += element("UsedDevice", m.usedDevice)
        x += element("ConversionExecutionDateTime", m.conversionTimeText)
        x += "<PersonPerformingConversion><PersonData><PhysicalPerson><PersonName>"
        x += element("GivenName", m.person.givenName)
        x += element("FamilyName", m.person.familyName)
        x += "</PersonName></PhysicalPerson>"
        x += "<LegalSubject>\(element("Name", String(m.person.legalSubjectName.prefix(255))))</LegalSubject>"
        if let uri = m.person.legalSubjectURI, ConversionRecordRenderer.recordAcceptsIdentifier(uri) {
            x += "<ID><IdentifierType>\(codelist(ZakoCodelists.record12IdentifierTypeCode, ZakoCodelists.icoIdentifierItem))</IdentifierType>"
            x += element("IdentifierValue", uri) + "</ID>"
        }
        x += "</PersonData></PersonPerformingConversion></ConversionRecord>"
        return x
    }

    /// Timestamp names, per element as each annotation says. `Authorization/TimeStamp` is always
    /// "Casova-peciatka-<N>"; an `OriginalDocumentTimestamp` is "Elektronicka casova peciatka"
    /// when the record holds exactly one (a document or content timestamp) and no authorization
    /// lists it as its `TimeStamp` (one timestamp keeps one name), else "Casova-peciatka-<N>". N
    /// counts in order of appearance (document timestamps, content timestamps, then each
    /// authorization's own). One timestamp, by file and DSS id, keeps one name; a timestamp
    /// without an id is its authorization's own. The lookup throws on a timestamp it was not
    /// built from, so a miss never yields a duplicate.
    static func timestampNames(_ original: ElectronicOriginal) -> (String?, String?, Int?) throws -> String {
        func key(_ file: String?, _ id: String?, _ authorization: Int?) -> String {
            id.map { "\(file ?? "")\u{0}\($0)" } ?? "authorization\u{0}\(authorization ?? -1)"
        }
        var documentKeys: [String] = []
        for stamp in original.documentTimestamps where !documentKeys.contains(key(stamp.fileEntryName, stamp.id, nil)) {
            documentKeys.append(key(stamp.fileEntryName, stamp.id, nil))
        }
        for stamp in original.contentTimestamps where !documentKeys.contains(key(nil, stamp.id, nil)) {
            documentKeys.append(key(nil, stamp.id, nil))
        }
        var authorizationKeys: [String] = []
        for (index, authorization) in original.authorizations.enumerated() {
            guard let timestamp = authorization.timestamp else { continue }
            let k = key(authorization.fileEntryName, timestamp.id, index)
            if !documentKeys.contains(k) && !authorizationKeys.contains(k) { authorizationKeys.append(k) }
        }
        let sharedWithAuthorization = original.authorizations.enumerated().contains { index, authorization in
            authorization.timestamp.map { documentKeys.contains(key(authorization.fileEntryName, $0.id, index)) } ?? false
        }
        var names: [String: String] = [:]
        if documentKeys.count == 1 && !sharedWithAuthorization {
            names[documentKeys[0]] = "Elektronicka casova peciatka"
        }
        var counter = 0
        for k in documentKeys + authorizationKeys where names[k] == nil {
            counter += 1
            names[k] = "Casova-peciatka-\(counter)"
        }
        return { file, id, authorization in
            guard let name = names[key(file, id, authorization)] else {
                throw E2EDeliveryBuilder.Failure.unnamedTimestamp
            }
            return name
        }
    }

    /// The elements after a timestamp's name, the same in `OriginalDocumentTimestamp` and `TimeStamp`.
    private func timestampBody(_ timestamp: ElectronicOriginal.Timestamp, publisherLimit: Int) -> String {
        var x = element("TimeStampType", Self.timestampType(qualified: timestamp.qualified))
        x += element("TimeStampState", Self.state(timestamp.state))
        x += element("TimeStampCreated", ConversionFormModel.bratislavaDateTime(timestamp.created))
        x += element("TimeStampPublisher", String(timestamp.publisherCommonName.prefix(publisherLimit)))
        x += element("TimeStampValidationTime", ConversionFormModel.bratislavaDateTime(timestamp.validationTime))
        return x
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func element(_ name: String, _ value: String) -> String {
        "<\(name)>\(AttestationClauseGenerator.escape(value))</\(name)>"
    }

    /// An unknown item is written with empty code and name, which the schema refuses.
    private func codelist(_ code: String, _ item: ZakoCodelistItem?) -> String {
        "<Codelist><CodelistCode>\(AttestationClauseGenerator.escape(code))</CodelistCode><CodelistItem><ItemCode>\(AttestationClauseGenerator.escape(item?.code ?? ""))</ItemCode><ItemName Language=\"sk\">\(AttestationClauseGenerator.escape(item?.skName ?? ""))</ItemName></CodelistItem></Codelist>"
    }
}
