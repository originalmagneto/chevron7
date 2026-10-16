// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import XCTest
import Chevron7TestSupport
@testable import Chevron7Kit

final class ElectronicOriginalTests: XCTestCase {
    private let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x41, count: 200)

    private func original(_ signatures: [E2EEvidenceFixtures.Signature], pdf facts: E2EEvidenceFixtures.PDF = .init(),
                          name: String = "zmluva.pdf", data: Data? = nil) throws -> ElectronicOriginal {
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: signatures, pdf: facts))
        return try ElectronicOriginal.make(sourceName: name, sourceData: data ?? pdf, evidence: evidence)
    }

    private func signature(_ id: String = "S-1", revision: Int? = nil) -> E2EEvidenceFixtures.Signature {
        var signature = E2EEvidenceFixtures.Signature()
        signature.id = id
        signature.signedRevisionLength = revision ?? pdf.count
        return signature
    }

    func testSingleSignaturePdfUsesFileName() throws {
        let original = try original([signature()])
        XCTAssertEqual(original.documents.map(\.name), ["zmluva.pdf"])
        XCTAssertEqual(original.documents[0].sha256, Data(SHA256.hash(data: pdf)))
        XCTAssertEqual(original.authorizations[0].documentNames, ["zmluva.pdf"])
        XCTAssertEqual(original.kind, .pdf)
    }

    func testTwoRevisionsAreNamedWithSuffixes() throws {
        let original = try original([signature("S-2", revision: pdf.count), signature("S-1", revision: 120)])
        XCTAssertEqual(original.documents.map(\.name), ["zmluva-1", "zmluva-2"])
        XCTAssertEqual(original.documents[0].sha256, Data(SHA256.hash(data: pdf.prefix(120))))
        XCTAssertEqual(original.documents[1].sha256, Data(SHA256.hash(data: pdf)))
        let byID = Dictionary(uniqueKeysWithValues: original.authorizations.map { ($0.signatureID, $0.documentNames) })
        XCTAssertEqual(byID["S-1"], ["zmluva-1"])
        XCTAssertEqual(byID["S-2"], ["zmluva-2"])
    }

    func testAsicUsesEntryNameAndItsBytes() throws {
        let container = try ASiCEPackager().package(files: [.init(path: "zmluva.pdf", data: pdf)])
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = 1
        facts.asicDataObjectName = "zmluva.pdf"
        var xades = signature()
        xades.signedRevisionLength = nil
        let original = try original([xades], pdf: facts, name: "zmluva.asice", data: container)
        XCTAssertEqual(original.kind, .asicE(entryName: "zmluva.pdf"))
        XCTAssertEqual(original.pdfData, pdf)
        XCTAssertEqual(original.documents.map(\.name), ["zmluva.pdf"])
    }

    func testQualificationMapsToCodelist54() {
        XCTAssertEqual(ElectronicOriginal.authorizationType(qualification: "QESIG", qcType: "esign").item.code, "2")
        XCTAssertEqual(ElectronicOriginal.authorizationType(qualification: "QESEAL", qcType: "eseal").item.code, "5")
        XCTAssertEqual(ElectronicOriginal.authorizationType(qualification: "ADESIG_QC", qcType: nil).item.code, "3")
        XCTAssertEqual(ElectronicOriginal.authorizationType(qualification: "ADESEAL", qcType: nil).item.code, "6")
        XCTAssertEqual(ElectronicOriginal.authorizationType(qualification: "NOT_ADES", qcType: "eseal").item.code, "7")
        let undetermined = ElectronicOriginal.authorizationType(qualification: "INDETERMINATE_QESIG", qcType: nil)
        XCTAssertEqual(undetermined.item.code, "Iny")
        XCTAssertTrue(undetermined.other?.contains("INDETERMINATE_QESIG") == true)
    }

    func testSignerFactsReachTheAuthorization() throws {
        var facts = signature()
        facts.mandate = "1042 OPRÁVNENIE 1042"
        facts.mandants = ["MANDANT Kancelária s.r.o."]
        facts.productionPlace = "Bratislava"
        let authorization = try original([facts]).authorizations[0]
        XCTAssertEqual(authorization.personID, "PNOSK-1234567890")
        XCTAssertEqual(authorization.mandate, "1042 OPRÁVNENIE 1042")
        XCTAssertEqual(authorization.mandant, "MANDANT Kancelária s.r.o.")
        XCTAssertEqual(authorization.location, "Bratislava")
        XCTAssertEqual(authorization.otherInfo, "Kvalifikovaný certifikát: áno")
        var unnamed = signature()
        unnamed.serialNumber = nil
        XCTAssertEqual(try original([unnamed]).authorizations[0].personID, "Ján Klient")
        XCTAssertEqual(try original([unnamed]).authorizations[0].location, "Neuvedené")
    }

    func testOldestValidTimestampIsChosen() throws {
        var facts = signature()
        var later = E2EEvidenceFixtures.Timestamp()
        later.id = "T-later"
        later.productionTime = "2026-10-12T08:00:00Z"
        var failedEarliest = E2EEvidenceFixtures.Timestamp()
        failedEarliest.id = "T-failed"
        failedEarliest.productionTime = "2026-10-01T08:00:00Z"
        failedEarliest.indication = "FAILED"
        var earliestValid = E2EEvidenceFixtures.Timestamp()
        earliestValid.id = "T-valid"
        earliestValid.productionTime = "2026-10-05T08:00:00Z"
        earliestValid.qualification = "TSA"
        facts.timestamps = [later, failedEarliest, earliestValid]
        let timestamp = try XCTUnwrap(try original([facts]).authorizations[0].timestamp)
        XCTAssertEqual(timestamp.created, ISO8601DateFormatter().date(from: "2026-10-05T08:00:00Z"))
        XCTAssertEqual(timestamp.state, .valid)
        XCTAssertEqual(timestamp.typeItem.code, "NEKVAL")
    }

    func testRefusesUnsigned() {
        XCTAssertThrowsError(try original([])) { XCTAssertEqual($0 as? ElectronicOriginalError, .unsigned) }
    }

    func testRefusesTwoDataObjects() {
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = 2
        XCTAssertThrowsError(try original([signature()], pdf: facts, name: "a.asice", data: Data("PK".utf8))) {
            XCTAssertEqual($0 as? ElectronicOriginalError, .unsupportedContainer(dataObjects: 2))
        }
    }

    func testRefusesSignedPDFInsideContainer() throws {
        let container = try ASiCEPackager().package(files: [.init(path: "zmluva.pdf", data: pdf)])
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = 1
        facts.asicDataObjectName = "zmluva.pdf"
        facts.asicDataObjectSigned = true
        XCTAssertThrowsError(try original([signature()], pdf: facts, name: "a.asice", data: container)) {
            XCTAssertEqual($0 as? ElectronicOriginalError, .signedPDFInsideContainer)
        }
    }

    func testRefusesChangesAfterLastSignature() {
        var facts = E2EEvidenceFixtures.PDF()
        facts.changesAfterLastSignature = ["ANNOTATION"]
        XCTAssertThrowsError(try original([signature()], pdf: facts)) { error in
            XCTAssertEqual(error as? ElectronicOriginalError, .changedAfterLastSignature(["ANNOTATION"]))
            XCTAssertTrue(error.localizedDescription.contains("poznámky"))
        }
    }

    func testPdfaWithoutAttachmentsIsKept() throws {
        var facts = E2EEvidenceFixtures.PDF()
        facts.declaredPdfaPart = 2
        facts.declaredPdfaConformance = "B"
        facts.pdfaCompliant = true
        let original = try original([signature()], pdf: facts)
        XCTAssertEqual(original.plan, .keep(format: E2ECodelists.pdfa2Format, formatOther: nil))
        XCTAssertEqual(original.documents[0].format, E2ECodelists.pdfa2Format)
    }

    func testPdfa3WithAttachmentIsConverted() throws {
        var facts = E2EEvidenceFixtures.PDF()
        facts.declaredPdfaPart = 3
        facts.pdfaCompliant = true
        facts.hasEmbeddedFiles = true
        let original = try original([signature()], pdf: facts)
        XCTAssertEqual(original.plan, .convert(reason: "PDF obsahuje vložené súbory (prílohy)"))
        XCTAssertEqual(original.documents[0].format, E2ECodelists.otherFormat)
        XCTAssertEqual(original.documents[0].formatOther, "PDF/A-3")
    }

    func testPlainPdfIsConverted() throws {
        XCTAssertEqual(try original([signature()]).plan, .convert(reason: "PDF nie je platné PDF/A"))
    }

    // MARK: Gate

    func testAllValidIsReady() throws {
        XCTAssertEqual(E2EVerificationGate.decide(try original([signature()])), .ready)
    }

    func testInvalidBlocks() throws {
        var invalid = signature()
        invalid.indication = "TOTAL_FAILED"
        guard case .blocked(let message) = E2EVerificationGate.decide(try original([invalid])) else {
            return XCTFail("an invalid signature must block")
        }
        XCTAssertTrue(message.contains("neplatný"))
    }

    func testUnloadedTrustedListBlocks() throws {
        var unloaded = signature()
        unloaded.indication = "INDETERMINATE"
        unloaded.trustedListUnavailable = true
        XCTAssertEqual(E2EVerificationGate.decide(try original([unloaded])),
                       .blocked("Overenie sa nepodarilo dokončiť, lebo sa nenačítal dôveryhodný zoznam. Skúste overenie znova."))
    }

    func testUndeterminedNeedsConfirmation() throws {
        var undetermined = signature()
        undetermined.indication = "INDETERMINATE"
        undetermined.subIndication = "TRY_LATER"
        let original = try original([undetermined])
        XCTAssertEqual(original.authorizations[0].state, .undetermined)
        guard case .needsConfirmation(let list) = E2EVerificationGate.decide(original) else {
            return XCTFail("an undetermined signature needs confirmation")
        }
        XCTAssertEqual(list.map(\.signatureID), ["S-1"])
    }

    func testInvalidTimestampBlocks() throws {
        var facts = signature()
        var failed = E2EEvidenceFixtures.Timestamp()
        failed.indication = "FAILED"
        facts.timestamps = [failed]
        guard case .blocked = E2EVerificationGate.decide(try original([facts])) else {
            return XCTFail("an invalid timestamp must block")
        }
    }
}
