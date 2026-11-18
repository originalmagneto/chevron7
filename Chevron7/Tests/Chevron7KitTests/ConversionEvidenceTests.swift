// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import XCTest
import Chevron7TestSupport
@testable import Chevron7Kit

final class ConversionEvidenceTests: XCTestCase {
    func testDecodesPadesEvidence() throws {
        var signature = E2EEvidenceFixtures.Signature()
        signature.signedRevisionLength = 4096
        signature.mandate = "1042 OPRÁVNENIE 1042"
        signature.policies = [["oid": "1.3.158.36061701.1.1.1042", "explicitText": "OPRÁVNENIE 1042"]]
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [signature]))

        XCTAssertEqual(evidence.dssVersion, "6.4")
        XCTAssertEqual(evidence.validationTime, ISO8601DateFormatter().date(from: E2EEvidenceFixtures.validationTime))
        XCTAssertEqual(evidence.tree.signatures.map(\.id), ["S-1"])
        XCTAssertEqual(evidence.tree.signatures.first?.state, .valid)
        let facts = try XCTUnwrap(evidence.signature(id: "S-1"))
        XCTAssertEqual(facts.signedRevisionLength, 4096)
        XCTAssertEqual(facts.signatureValue, Data("signature-value-1".utf8))
        XCTAssertEqual(facts.mandate, "1042 OPRÁVNENIE 1042")
        XCTAssertEqual(facts.policies.first?.explicitText, "OPRÁVNENIE 1042")
        XCTAssertEqual(facts.timestamps.first?.producerCommonName, "Sectigo Qualified Time Stamping Signer #2")
        XCTAssertEqual(facts.timestamps.first?.qualification, "QTSA")
        XCTAssertFalse(evidence.etsiReport.isEmpty)
        XCTAssertEqual(evidence.pdf?.pdfaCompliant, false)
    }

    func testDecodesTrustedListUnavailable() throws {
        var signature = E2EEvidenceFixtures.Signature()
        signature.indication = "INDETERMINATE"
        signature.trustedListUnavailable = true
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [signature]))
        XCTAssertEqual(evidence.signatures.first?.trustedListUnavailable, true)
        XCTAssertEqual(evidence.tree.signatures.first?.state, .indeterminate)
    }

    func testDecodesDataObjectsInOrder() throws {
        var pdf = E2EEvidenceFixtures.DataObject(name: "zmluva.pdf")
        pdf.pages = 3
        pdf.embeddedFileNames = ["priloha.xml"]
        var image = E2EEvidenceFixtures.DataObject(name: "sken.png", bytes: Data([0x89, 0x50, 0x4E, 0x47]))
        image.kind = "png"
        image.widthPx = 1240
        image.heightPx = 1754
        image.coveredBy = ["S-1"]
        var other = E2EEvidenceFixtures.DataObject(name: "poznamka.txt", bytes: Data("x".utf8))
        other.kind = "other"
        other.problem = "UNREADABLE"
        var container = E2EEvidenceFixtures.PDF()
        container.asicDataObjectCount = 3
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [E2EEvidenceFixtures.Signature()], pdf: container, dataObjects: [pdf, image, other]))

        let objects = try XCTUnwrap(evidence.pdf?.dataObjects)
        XCTAssertEqual(objects.map(\.name), ["zmluva.pdf", "sken.png", "poznamka.txt"])
        XCTAssertEqual(objects.map(\.kind), [.pdf, .png, .other])
        XCTAssertEqual(objects[0].size, pdf.bytes.count)
        XCTAssertEqual(objects[0].sha256, Data(SHA256.hash(data: pdf.bytes)))
        XCTAssertEqual(objects[0].pages, 3)
        XCTAssertEqual(objects[0].embeddedFileNames, ["priloha.xml"])
        XCTAssertNotNil(objects[0].pdf)
        XCTAssertNil(objects[0].nested)
        XCTAssertEqual(objects[1].widthPx, 1240)
        XCTAssertEqual(objects[1].heightPx, 1754)
        XCTAssertEqual(objects[1].coveredBy, ["S-1"])
        XCTAssertNil(objects[1].pdf)
        XCTAssertEqual(objects[2].problem, "UNREADABLE")
    }

    func testDecodesNestedEvidenceSignatures() throws {
        var nested = E2EEvidenceFixtures.Signature()
        nested.id = "N-1"
        nested.signedRevisionLength = 2048
        nested.signatureValue = Data("nested-value".utf8)
        var object = E2EEvidenceFixtures.DataObject(name: "podpisana.pdf")
        object.nestedSignatures = [nested]
        var nestedFacts = E2EEvidenceFixtures.PDF()
        nestedFacts.changesAfterLastSignature = ["FORM_FILL"]
        object.nestedPDF = nestedFacts
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [E2EEvidenceFixtures.Signature()], dataObjects: [object]))

        let decoded = try XCTUnwrap(evidence.pdf?.dataObjects.first)
        let inner = try XCTUnwrap(decoded.nested)
        XCTAssertEqual(inner.validationTime, ISO8601DateFormatter().date(from: E2EEvidenceFixtures.validationTime))
        XCTAssertEqual(inner.signatures.map(\.id), ["N-1"])
        XCTAssertEqual(inner.signatures.first?.signatureValue, Data("nested-value".utf8))
        XCTAssertEqual(inner.signatures.first?.signedRevisionLength, 2048)
        XCTAssertEqual(inner.signatures.first?.slimReport, Data("<ValidationReport id=\"N-1\"/>".utf8))
        XCTAssertFalse(inner.etsiReport.isEmpty)
        XCTAssertEqual(inner.pdf.changesAfterLastSignature, ["FORM_FILL"])
        XCTAssertEqual(decoded.pdf?.changesAfterLastSignature, ["FORM_FILL"])
    }

    func testOldPayloadHasNoDataObjects() throws {
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [E2EEvidenceFixtures.Signature()]))
        XCTAssertEqual(evidence.pdf?.dataObjects, [])
    }

    func testDecodesSignatureFilenameAndDocumentTimestamps() throws {
        var signature = E2EEvidenceFixtures.Signature()
        signature.signatureFilename = "META-INF/signatures001.xml"
        var stamp = E2EEvidenceFixtures.DocumentTimestamp()
        stamp.coveredRevisionLength = 52_000
        var nested = E2EEvidenceFixtures.Signature()
        nested.id = "N-1"
        var object = E2EEvidenceFixtures.DataObject(name: "podpisana.pdf")
        object.nestedSignatures = [nested]
        var nestedStamp = E2EEvidenceFixtures.DocumentTimestamp()
        nestedStamp.id = "T-DOC-N"
        nestedStamp.coveredRevisionLength = 8_192
        object.nestedDocumentTimestamps = [nestedStamp]
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [signature], dataObjects: [object], documentTimestamps: [stamp]))

        XCTAssertEqual(evidence.signatures.first?.signatureFilename, "META-INF/signatures001.xml")
        let decoded = try XCTUnwrap(evidence.documentTimestamps.first)
        XCTAssertEqual(evidence.documentTimestamps.count, 1)
        XCTAssertEqual(decoded.id, "T-DOC-1")
        XCTAssertEqual(decoded.productionTime, ISO8601DateFormatter().date(from: "2026-10-11T07:00:00Z"))
        XCTAssertEqual(decoded.producerCommonName, "BOSA TSA")
        XCTAssertEqual(decoded.indication, "PASSED")
        XCTAssertEqual(decoded.qualification, "QTSA")
        XCTAssertEqual(decoded.coveredRevisionLength, 52_000)
        let inner = try XCTUnwrap(evidence.pdf?.dataObjects.first?.nested)
        XCTAssertNil(inner.signatures.first?.signatureFilename)
        XCTAssertEqual(inner.documentTimestamps.map(\.id), ["T-DOC-N"])
        XCTAssertEqual(inner.documentTimestamps.first?.coveredRevisionLength, 8_192)
    }

    func testOldPayloadHasNoDocumentTimestamps() throws {
        var object = E2EEvidenceFixtures.DataObject(name: "podpisana.pdf")
        object.nestedSignatures = [E2EEvidenceFixtures.Signature()]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: E2EEvidenceFixtures.payload(
            signatures: [E2EEvidenceFixtures.Signature()], dataObjects: [object])) as? [String: Any])
        var evidence = try XCTUnwrap(json["evidence"] as? [String: Any])
        evidence.removeValue(forKey: "documentTimestamps")
        var pdf = try XCTUnwrap(evidence["pdf"] as? [String: Any])
        var objects = try XCTUnwrap(pdf["dataObjects"] as? [[String: Any]])
        var nested = try XCTUnwrap(objects[0]["evidence"] as? [String: Any])
        nested.removeValue(forKey: "documentTimestamps")
        objects[0]["evidence"] = nested
        pdf["dataObjects"] = objects
        evidence["pdf"] = pdf
        json["evidence"] = evidence
        let decoded = try ConversionEvidence.decode(payloadJSON: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(decoded.documentTimestamps, [])
        XCTAssertNil(decoded.signatures.first?.signatureFilename)
        let inner = try XCTUnwrap(decoded.pdf?.dataObjects.first?.nested)
        XCTAssertEqual(inner.documentTimestamps, [])
    }

    func testMalformedNestedDocumentTimestampDegradesOnlyItsDataObject() throws {
        var signature = E2EEvidenceFixtures.Signature()
        signature.signatureFilename = "META-INF/signatures001.xml"
        var object = E2EEvidenceFixtures.DataObject(name: "podpisana.pdf")
        object.nestedSignatures = [E2EEvidenceFixtures.Signature()]
        object.nestedDocumentTimestamps = [E2EEvidenceFixtures.DocumentTimestamp()]
        let other = E2EEvidenceFixtures.DataObject(name: "druha.pdf")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: E2EEvidenceFixtures.payload(
            signatures: [signature], dataObjects: [object, other])) as? [String: Any])
        var evidence = try XCTUnwrap(json["evidence"] as? [String: Any])
        var pdf = try XCTUnwrap(evidence["pdf"] as? [String: Any])
        var objects = try XCTUnwrap(pdf["dataObjects"] as? [[String: Any]])
        var nested = try XCTUnwrap(objects[0]["evidence"] as? [String: Any])
        var stamps = try XCTUnwrap(nested["documentTimestamps"] as? [[String: Any]])
        stamps[0].removeValue(forKey: "id")
        nested["documentTimestamps"] = stamps
        objects[0]["evidence"] = nested
        pdf["dataObjects"] = objects
        evidence["pdf"] = pdf
        json["evidence"] = evidence

        let decoded = try ConversionEvidence.decode(payloadJSON: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.signatures.first?.signatureFilename, "META-INF/signatures001.xml")
        let list = try XCTUnwrap(decoded.pdf?.dataObjects)
        XCTAssertNil(list[0].nested)
        XCTAssertEqual(list[0].problem, "NESTED_UNREADABLE")
        XCTAssertEqual(list[0].kind, .pdf)
        XCTAssertNil(list[1].problem)
    }

    func testTolerantOfUnknownKeys() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: E2EEvidenceFixtures.payload(
            signatures: [E2EEvidenceFixtures.Signature()])) as? [String: Any])
        var evidence = try XCTUnwrap(json["evidence"] as? [String: Any])
        var pdf = try XCTUnwrap(evidence["pdf"] as? [String: Any])
        pdf["pages"] = 2
        pdf["embeddedFileNames"] = ["a.xml"]
        pdf["somethingNew"] = true
        evidence["pdf"] = pdf
        json["evidence"] = evidence
        XCTAssertNoThrow(try ConversionEvidence.decode(payloadJSON: JSONSerialization.data(withJSONObject: json)))
    }

    func testNestedSignatureWithoutValueDegradesOnlyItsDataObject() throws {
        var object = E2EEvidenceFixtures.DataObject(name: "podpisana.pdf")
        object.nestedSignatures = [E2EEvidenceFixtures.Signature()]
        let other = E2EEvidenceFixtures.DataObject(name: "druha.pdf")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: E2EEvidenceFixtures.payload(
            signatures: [E2EEvidenceFixtures.Signature()], dataObjects: [object, other])) as? [String: Any])
        var evidence = try XCTUnwrap(json["evidence"] as? [String: Any])
        var pdf = try XCTUnwrap(evidence["pdf"] as? [String: Any])
        var objects = try XCTUnwrap(pdf["dataObjects"] as? [[String: Any]])
        var nested = try XCTUnwrap(objects[0]["evidence"] as? [String: Any])
        var signatures = try XCTUnwrap(nested["signatures"] as? [[String: Any]])
        signatures[0].removeValue(forKey: "signatureValueBase64")
        nested["signatures"] = signatures
        objects[0]["evidence"] = nested
        pdf["dataObjects"] = objects
        evidence["pdf"] = pdf
        json["evidence"] = evidence
        let decoded = try ConversionEvidence.decode(payloadJSON: JSONSerialization.data(withJSONObject: json))
        let list = try XCTUnwrap(decoded.pdf?.dataObjects)
        XCTAssertNil(list[0].nested)
        XCTAssertEqual(list[0].problem, "NESTED_UNREADABLE")
        XCTAssertEqual(list[0].kind, .pdf)
        XCTAssertNil(list[1].problem)
    }

    func testDecodesTooLargeAndNestedUnreadableObjects() throws {
        var large = E2EEvidenceFixtures.DataObject(name: "velky.bin", bytes: Data("big".utf8))
        large.kind = "other"
        large.problem = "TOO_LARGE"
        var broken = E2EEvidenceFixtures.DataObject(name: "rozbity.pdf")
        broken.problem = "NESTED_UNREADABLE"
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [E2EEvidenceFixtures.Signature()], dataObjects: [large, broken]))
        let list = try XCTUnwrap(evidence.pdf?.dataObjects)
        XCTAssertEqual(list.map(\.problem), ["TOO_LARGE", "NESTED_UNREADABLE"])
        XCTAssertEqual(list.map(\.name), ["velky.bin", "rozbity.pdf"])
        XCTAssertEqual(list[0].size, 3)
        XCTAssertEqual(list[0].sha256, Data(SHA256.hash(data: large.bytes)))
        XCTAssertEqual(list[1].kind, .pdf)
        XCTAssertEqual(list[1].sha256, Data(SHA256.hash(data: broken.bytes)))
        XCTAssertTrue(list.allSatisfy { $0.nested == nil })
    }

    func testMissingEvidenceIsMalformed() {
        XCTAssertThrowsError(try ConversionEvidence.decode(payloadJSON: Data(#"{"signatures":[]}"#.utf8)))
    }

    func testRunnerMapsExitCodeThreeToNotCompliant() {
        let runner = PdfaFromSignedRunner(launch: { _ in (3, "font a\nfont b\n") })
        XCTAssertThrowsError(try runner.convert(Data("%PDF".utf8), title: "Zmluva", raster: false)) { error in
            XCTAssertEqual(error as? PdfaFromSignedRunner.Failure, .notCompliant(["font a", "font b"]))
        }
    }

    func testRunnerPassesRasterFlagAndReadsOutput() throws {
        let runner = PdfaFromSignedRunner(launch: { arguments in
            XCTAssertEqual(arguments.first, "digital.slovensko.autogram.core.PdfaFromSigned")
            XCTAssertEqual(arguments.last, "--raster")
            try Data("%PDF-converted".utf8).write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        XCTAssertEqual(try runner.convert(Data("%PDF".utf8), title: "", raster: true), Data("%PDF-converted".utf8))
    }

    func testRunnerMapsUnreadableInput() {
        let runner = PdfaFromSignedRunner(launch: { _ in (2, "") })
        XCTAssertThrowsError(try runner.convert(Data("x".utf8), title: "Zmluva", raster: false)) { error in
            XCTAssertEqual(error as? PdfaFromSignedRunner.Failure, .unreadable)
        }
    }
}
