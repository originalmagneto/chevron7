// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import CryptoKit
@testable import Chevron7Kit

final class OfficialFormTests: XCTestCase {
    private let formsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/reference/forms")

    func testRecordDigestsMatchTheRecordEZZKAccepted() {
        XCTAssertEqual(OfficialForm.record_1_0.schemaDigestBase64, "V8kKaM40HWD1QVmPG3ANlZWAylZk0wmzvg0ghiXptA8=")
        XCTAssertEqual(OfficialForm.record_1_0.presentationDigestBase64, "TYaNJLG/51TOIF8aFEcTQw72vudBAtYZUOkOfRG87as=")
        XCTAssertEqual(OfficialForm.record_1_0.schemaURI,
                       "https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0/form.xsd")
        XCTAssertEqual(OfficialForm.record_1_0.presentationMediaDestination, "TXT")
    }

    func testRecord12Identifiers() {
        let record = OfficialForm.record_1_2
        XCTAssertEqual(record.identifier, "http://data.gov.sk/doc/eform/50349287.ConversionRecordOfPaperToElectronicDocument_2021.sk/1.2")
        XCTAssertEqual(record.namespace, "http://schemas.gov.sk/form/50349287.ConversionRecordOfPaperToElectronicDocument_2021.sk/1.2")
        XCTAssertEqual(record.version, "1.2")
        XCTAssertEqual(record.presentationMediaDestination, "TXT")
        XCTAssertEqual(record.validationSchema, record.schema)
    }

    func testClauseIdentifiers() {
        let clause = OfficialForm.clause_1_3
        XCTAssertEqual(clause.identifier, "http://data.gov.sk/doc/eform/50349287.ConversionCertificateOfPaperToElectronicDocument.sk/1.3")
        XCTAssertEqual(clause.namespace, "http://schemas.gov.sk/form/50349287.ConversionCertificateOfPaperToElectronicDocument.sk/1.3")
        XCTAssertEqual(clause.version, "1.3")
        XCTAssertEqual(clause.presentationURI, clause.namespace + "/form.xslt")
        XCTAssertEqual(clause.presentationMediaDestination, "HTML")
    }

    func testE2EIdentifiers() {
        let clause = OfficialForm.clauseE2E_1_3
        XCTAssertEqual(clause.identifier,
                       "http://data.gov.sk/doc/eform/50349287.ConversionCertificateOfElectronicDocumentToElectronicDocument.sk/1.3")
        XCTAssertEqual(clause.schemaURI,
                       "http://schemas.gov.sk/form/50349287.ConversionCertificateOfElectronicDocumentToElectronicDocument.sk/1.3/form.xsd")
        XCTAssertEqual(clause.presentationMediaDestination, "HTML")
        XCTAssertTrue(String(decoding: clause.presentation, as: UTF8.self).contains("Osvedčujem, že tento elektronický dokument"))
        let record = OfficialForm.recordE2E_1_0
        XCTAssertEqual(record.identifier,
                       "http://data.gov.sk/doc/eform/50349287.ConversionRecordOfElectronicDocumentToElectronicDocument.sk/1.0")
        XCTAssertEqual(record.schemaURI,
                       "https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfElectronicDocumentToElectronicDocument.sk/1.0/form.xsd")
        XCTAssertEqual(record.presentationMediaDestination, "TXT")
    }

    func testE2ERecordValidationSchemaDiffersOnlyInTheIdentifierPattern() {
        let official = String(decoding: OfficialForm.recordE2E_1_0.schema, as: UTF8.self).components(separatedBy: "\n")
        let validation = String(decoding: OfficialForm.recordE2E_1_0.validationSchema, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(official.count, validation.count)
        let changed = zip(official, validation).filter { $0 != $1 }
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(changed.first?.1.contains("https://data\\.gov\\.sk/id/legal-subject/([0-9]{8}|[0-9]{12})") == true)
    }

    func testRecordValidationSchemaDiffersOnlyInTheIdentifierPattern() throws {
        let official = String(decoding: OfficialForm.record_1_0.schema, as: UTF8.self).components(separatedBy: "\n")
        let validation = String(decoding: OfficialForm.record_1_0.validationSchema, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(official.count, validation.count)
        let changed = zip(official, validation).filter { $0 != $1 }
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(changed.first?.1.contains("https://data\\.gov\\.sk/id/legal-subject/([0-9]{8}|[0-9]{12})") == true)
        XCTAssertEqual(OfficialForm.clause_1_3.validationSchema, OfficialForm.clause_1_3.schema)
    }

    func testEmbeddedFilesEqualTheReferenceCopiesAndProvenance() throws {
        let provenance = try JSONSerialization.jsonObject(
            with: Data(contentsOf: formsDirectory.appendingPathComponent("provenance.json"))) as? [String: Any]
        let files = try XCTUnwrap(provenance?["files"] as? [String: [String: String]])
        let embedded: [(String, Data)] = [
            ("record-1.0/schema.xsd", OfficialForm.record_1_0.schema),
            ("record-1.0/schema.validation.xsd", OfficialForm.record_1_0.validationSchema),
            ("record-1.0/form103.sb.xslt", OfficialForm.record_1_0.presentation),
            ("record-1.2/schema.xsd", OfficialForm.record_1_2.schema),
            ("record-1.2/form103.sb.xslt", OfficialForm.record_1_2.presentation),
            ("clause-1.3/schema.xsd", OfficialForm.clause_1_3.schema),
            ("clause-1.3/form.2.html2.xslt", OfficialForm.clause_1_3.presentation),
            ("record-e2e-1.0/schema.xsd", OfficialForm.recordE2E_1_0.schema),
            ("record-e2e-1.0/schema.validation.xsd", OfficialForm.recordE2E_1_0.validationSchema),
            ("record-e2e-1.0/form101.sb.xslt", OfficialForm.recordE2E_1_0.presentation),
            ("clause-e2e-1.3/schema.xsd", OfficialForm.clauseE2E_1_3.schema),
            ("clause-e2e-1.3/form.19.html2.xslt", OfficialForm.clauseE2E_1_3.presentation),
        ]
        for (path, data) in embedded {
            let reference = try Data(contentsOf: formsDirectory.appendingPathComponent(path))
            XCTAssertEqual(data, reference, "\(path) differs from the embedded copy; run scripts/embed-official-forms.sh")
            let hex = SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, files[path]?["sha256"], "\(path) differs from provenance.json")
        }
    }

    func testStoredDigestsRecomputeFromTheEmbeddedFiles() throws {
        for form in [OfficialForm.record_1_0, .record_1_2, .clause_1_3, .recordE2E_1_0, .clauseE2E_1_3] {
            XCTAssertEqual(try Self.canonicalDigest(form.schema), form.schemaDigestBase64, form.identifier)
            XCTAssertEqual(try Self.canonicalDigest(form.presentation), form.presentationDigestBase64, form.identifier)
        }
    }

    /// SHA-256 over Canonical XML 1.0 without comments, the XDC 1.1 digest rule.
    static func canonicalDigest(_ data: Data) throws -> String {
        let xmllint = URL(fileURLWithPath: "/usr/bin/xmllint")
        guard FileManager.default.isExecutableFile(atPath: xmllint.path) else {
            throw XCTSkip("xmllint is needed to canonicalise the form files.")
        }
        let text = String(decoding: data, as: UTF8.self)
        let stripped = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("form-\(UUID().uuidString).xml")
        try Data(stripped.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = xmllint
        process.arguments = ["--c14n", file.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let canonical = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return Data(SHA256.hash(data: canonical)).base64EncodedString()
    }
}
