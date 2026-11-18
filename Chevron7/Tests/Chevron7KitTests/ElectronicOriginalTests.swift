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

    func testLegacyPayloadWithTwoDataObjectsIsMalformed() {
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = 2
        XCTAssertThrowsError(try original([signature()], pdf: facts, name: "a.asice", data: Data("PK".utf8))) {
            XCTAssertEqual($0 as? ElectronicOriginalError, .malformedEvidence)
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

    // MARK: Containers with several files

    private typealias Object = E2EEvidenceFixtures.DataObject

    private func pdfBytes(_ fill: UInt8, count: Int = 200) -> Data {
        Data("%PDF-1.7\n".utf8) + Data(repeating: fill, count: max(0, count - 9))
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x50, count: 40)
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x4A, count: 40)

    private func object(_ name: String, _ bytes: Data, kind: String = "pdf",
                        coveredBy: [String] = ["C-1"]) -> Object {
        var object = Object(name: name, bytes: bytes)
        object.kind = kind
        object.coveredBy = coveredBy
        return object
    }

    private func containerSignature(_ id: String = "C-1") -> E2EEvidenceFixtures.Signature {
        var signature = E2EEvidenceFixtures.Signature()
        signature.id = id
        signature.format = "XAdES-BASELINE-T"
        signature.signatureValue = Data("container-\(id)".utf8)
        return signature
    }

    private func pades(_ id: String, revision: Int) -> E2EEvidenceFixtures.Signature {
        var signature = E2EEvidenceFixtures.Signature()
        signature.id = id
        signature.signer = "Podpisovateľ \(id)"
        signature.signedRevisionLength = revision
        signature.signatureValue = Data("pades-\(id)".utf8)
        return signature
    }

    private func container(_ objects: [Object], signatures: [E2EEvidenceFixtures.Signature]? = nil,
                           zipped: [Object]? = nil) throws -> ElectronicOriginal {
        let data = try ASiCEPackager().package(files: (zipped ?? objects).map { .init(path: $0.name, data: $0.bytes) })
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = objects.count
        facts.asicDataObjectName = objects.first { $0.kind == "pdf" }?.name
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: signatures ?? [containerSignature()], pdf: facts, dataObjects: objects))
        return try ElectronicOriginal.make(sourceName: "spis.asice", sourceData: data, evidence: evidence)
    }

    private func sha(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    func testTwoPdfsAndImagesBecomeDocumentsInContainerOrder() throws {
        let a = pdfBytes(0x41)
        let original = try container([object("a.pdf", a), object("b.png", png, kind: "png"),
                                      object("c.jpg", jpeg, kind: "jpeg")])
        XCTAssertEqual(original.kind, .asicEMultiple)
        XCTAssertEqual(original.documents.map(\.name), ["a.pdf", "b.png", "c.jpg"])
        XCTAssertEqual(original.documents.map(\.sha256), [sha(a), sha(png), sha(jpeg)])
        XCTAssertEqual(original.documents.map(\.format), [E2ECodelists.pdfFormat, E2ECodelists.pngFormat,
                                                          E2ECodelists.otherFormat])
        XCTAssertEqual(original.documents.map(\.formatOther), [nil, nil, E2ECodelists.jpegFormatOther])
        XCTAssertEqual(original.documents.map(\.fileEntryName), ["a.pdf", "b.png", "c.jpg"])
        XCTAssertEqual(original.authorizations.count, 1)
        XCTAssertEqual(original.authorizations[0].documentNames, ["a.pdf", "b.png", "c.jpg"])
        XCTAssertNil(original.authorizations[0].fileEntryName)
        XCTAssertEqual(original.files.map(\.entryName), ["a.pdf", "b.png", "c.jpg"])
        XCTAssertEqual(original.files.map(\.kind), [.pdf, .png, .jpeg])
        XCTAssertEqual(original.files[1].data, png)
        XCTAssertEqual(original.files[2].documentNames, ["c.jpg"])
        XCTAssertEqual(original.pdfData, a)
        guard case .convert = original.plan else { return XCTFail("several files are always converted") }
    }

    func testImageOnlyContainerHasNoPdfData() throws {
        let original = try container([object("b.png", png, kind: "png")])
        XCTAssertEqual(original.pdfData, Data())
        XCTAssertEqual(original.kind, .asicEMultiple)
    }

    func testSignatureCoveringOneFileListsOnlyIt() throws {
        let original = try container([object("a.pdf", pdfBytes(0x41), coveredBy: ["C-1"]),
                                      object("b.png", png, kind: "png", coveredBy: ["C-1", "C-2"])],
                                     signatures: [containerSignature("C-1"), containerSignature("C-2")])
        let byID = Dictionary(uniqueKeysWithValues: original.authorizations.map { ($0.signatureID, $0.documentNames) })
        XCTAssertEqual(byID["C-1"], ["a.pdf", "b.png"])
        XCTAssertEqual(byID["C-2"], ["b.png"])
    }

    func testUncoveredFileIsRefused() {
        XCTAssertThrowsError(try container([object("a.pdf", pdfBytes(0x41)),
                                            object("b.pdf", pdfBytes(0x42), coveredBy: [])])) { error in
            XCTAssertEqual(error as? ElectronicOriginalError, .uncoveredDataObject(name: "b.pdf"))
            XCTAssertEqual(error.localizedDescription,
                           "Súbor b.pdf nepokrýva žiadny podpis kontajnera. Neautorizovaný súbor nemožno zaručene konvertovať.")
        }
    }

    func testCoverageBySignatureOutsideTheTreeIsRefused() {
        XCTAssertThrowsError(try container([object("a.pdf", pdfBytes(0x41), coveredBy: ["X-9"])])) {
            XCTAssertEqual($0 as? ElectronicOriginalError, .uncoveredDataObject(name: "a.pdf"))
        }
    }

    func testDocxIsRefusedByName() {
        XCTAssertThrowsError(try container([object("a.pdf", pdfBytes(0x41)),
                                            object("zmluva.docx", Data("PK docx".utf8), kind: "other")])) { error in
            XCTAssertEqual(error as? ElectronicOriginalError, .unsupportedDataObject(name: "zmluva.docx"))
            XCTAssertEqual(error.localizedDescription,
                           "Súbor zmluva.docx nie je PDF ani obrázok PNG alebo JPEG. Chevron7 ho do nového dokumentu nevie zahrnúť.")
        }
    }

    func testUnreadableIsRefusedByName() {
        var broken = object("zlomene.pdf", Data("%PDF-broken".utf8), kind: "other")
        broken.problem = "UNREADABLE"
        XCTAssertThrowsError(try container([object("a.pdf", pdfBytes(0x41)), broken])) { error in
            XCTAssertEqual(error as? ElectronicOriginalError, .unreadableDataObject(name: "zlomene.pdf"))
            XCTAssertEqual(error.localizedDescription, "Súbor zlomene.pdf sa nepodarilo prečítať.")
        }
        var large = object("velke.pdf", pdfBytes(0x43))
        large.problem = "TOO_LARGE"
        XCTAssertThrowsError(try container([large])) {
            XCTAssertEqual($0 as? ElectronicOriginalError, .unreadableDataObject(name: "velke.pdf"))
        }
    }

    func testBytesThatDifferFromTheEvidenceAreRefused() {
        let evidenceObject = object("a.pdf", pdfBytes(0x41))
        let zipped = object("a.pdf", pdfBytes(0x42))
        XCTAssertThrowsError(try container([evidenceObject], zipped: [zipped])) {
            XCTAssertEqual($0 as? ElectronicOriginalError, .malformedEvidence)
        }
    }

    func testSignedPdfWholeFileIsItsOwnDocumentWhenBytesDiffer() throws {
        let bytes = pdfBytes(0x5A, count: 1000)
        var file = object("zmluva.pdf", bytes)
        file.nestedSignatures = [pades("P-1", revision: 900)]
        file.nestedValidationTime = "2026-10-16T09:45:00Z"
        let original = try container([file])
        XCTAssertEqual(original.documents.map(\.name), ["zmluva-1", "zmluva-2"])
        XCTAssertEqual(original.documents.map(\.sha256), [sha(bytes.prefix(900)), sha(bytes)])
        let pades = try XCTUnwrap(original.authorizations.first { $0.signatureID == "P-1" })
        XCTAssertEqual(pades.documentNames, ["zmluva-1"])
        XCTAssertEqual(pades.fileEntryName, "zmluva.pdf")
        XCTAssertEqual(pades.signerName, "Podpisovateľ P-1")
        XCTAssertEqual(pades.signatureValue, Data("pades-P-1".utf8))
        XCTAssertEqual(pades.slimReport, Data("<ValidationReport id=\"P-1\"/>".utf8))
        XCTAssertEqual(pades.validationTime, ISO8601DateFormatter().date(from: "2026-10-16T09:45:00Z"))
        XCTAssertEqual(pades.state, .valid)
        let outer = try XCTUnwrap(original.authorizations.first { $0.signatureID == "C-1" })
        XCTAssertEqual(outer.documentNames, ["zmluva-2"])
        XCTAssertEqual(outer.validationTime, ISO8601DateFormatter().date(from: E2EEvidenceFixtures.validationTime))
        XCTAssertEqual(original.files[0].documentNames, ["zmluva-1", "zmluva-2"])
    }

    func testSignedPdfCoveringWholeFileSharesOneDocument() throws {
        let bytes = pdfBytes(0x5A, count: 1000)
        var file = object("zmluva.pdf", bytes)
        file.nestedSignatures = [pades("P-1", revision: 1000)]
        let original = try container([file])
        XCTAssertEqual(original.documents.map(\.name), ["zmluva.pdf"])
        XCTAssertEqual(original.documents[0].sha256, sha(bytes))
        XCTAssertEqual(original.authorizations.map(\.documentNames), [["zmluva.pdf"], ["zmluva.pdf"]])
    }

    func testTwoRevisionsPlusTailGiveThreeDocuments() throws {
        let bytes = pdfBytes(0x5A, count: 1000)
        var file = object("zmluva.pdf", bytes)
        file.nestedSignatures = [pades("P-2", revision: 800), pades("P-1", revision: 500)]
        let original = try container([file])
        XCTAssertEqual(original.documents.map(\.name), ["zmluva-1", "zmluva-2", "zmluva-3"])
        XCTAssertEqual(original.documents.map(\.sha256), [sha(bytes.prefix(500)), sha(bytes.prefix(800)), sha(bytes)])
        let byID = Dictionary(uniqueKeysWithValues: original.authorizations.map { ($0.signatureID, $0.documentNames) })
        XCTAssertEqual(byID["P-1"], ["zmluva-1"])
        XCTAssertEqual(byID["P-2"], ["zmluva-2"])
        XCTAssertEqual(byID["C-1"], ["zmluva-3"])
    }

    func testSameFileNameInTwoFoldersUsesFullPaths() throws {
        let original = try container([object("a/zmluva.pdf", pdfBytes(0x41)), object("b/zmluva.pdf", pdfBytes(0x42)),
                                      object("prilohy/priloha.pdf", pdfBytes(0x43))])
        XCTAssertEqual(original.documents.map(\.name), ["a/zmluva.pdf", "b/zmluva.pdf", "priloha.pdf"])
        XCTAssertEqual(original.files.map(\.displayName), ["a/zmluva.pdf", "b/zmluva.pdf", "priloha.pdf"])
    }

    func testReorderedMovesDocumentsAndDataObjects() throws {
        let bytes = pdfBytes(0x5A, count: 1000)
        var signed = object("zmluva.pdf", bytes)
        signed.nestedSignatures = [pades("P-1", revision: 900)]
        let original = try container([signed, object("b.png", png, kind: "png"), object("c.pdf", pdfBytes(0x43))])
        let reordered = original.reordered(entryNames: ["c.pdf", "zmluva.pdf", "b.png"])
        XCTAssertEqual(reordered.files.map(\.entryName), ["c.pdf", "zmluva.pdf", "b.png"])
        XCTAssertEqual(reordered.documents.map(\.name), ["c.pdf", "zmluva-1", "zmluva-2", "b.png"])
        XCTAssertEqual(reordered.authorizations, original.authorizations)
    }

    func testEmbeddedFilesAreNamedOnTheFile() throws {
        let bytes = pdfBytes(0x5A, count: 1000)
        var file = object("zmluva.pdf", bytes)
        file.embeddedFileNames = ["faktura.xml"]
        file.nestedSignatures = [pades("P-1", revision: 900)]
        var facts = E2EEvidenceFixtures.PDF()
        facts.changesAfterLastSignature = ["ANNOTATION"]
        facts.hasEmbeddedFiles = true
        file.nestedPDF = facts
        let original = try container([file, object("b.png", png, kind: "png")])
        XCTAssertEqual(original.files[0].embeddedFileNames, ["faktura.xml"])
        XCTAssertEqual(original.files[0].changedAfterSignature, ["ANNOTATION"])
        XCTAssertEqual(original.files[1].embeddedFileNames, [])
        XCTAssertEqual(original.files[1].changedAfterSignature, [])
    }

    func testSingleUnsignedPdfContainerIsUnchanged() throws {
        let original = try container([object("zmluva.pdf", pdf)])
        XCTAssertEqual(original.kind, .asicE(entryName: "zmluva.pdf"))
        XCTAssertEqual(original.pdfData, pdf)
        XCTAssertEqual(original.documents.map(\.name), ["zmluva.pdf"])
        XCTAssertEqual(original.files, [])
        XCTAssertNil(original.documents[0].fileEntryName)

        let container = try ASiCEPackager().package(files: [.init(path: "zmluva.pdf", data: pdf)])
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = 1
        facts.asicDataObjectName = "zmluva.pdf"
        facts.declaredPdfaPart = 2
        facts.pdfaCompliant = true
        var only = object("zmluva.pdf", pdf)
        only.nestedPDF = facts
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [containerSignature()], pdf: facts, dataObjects: [only]))
        guard case .signed(.pdf, let nested)? = evidence.tree.documents.first?.content, nested.signatures.isEmpty else {
            return XCTFail("the engine lists an unsigned PDF data object with an empty nested tree")
        }
        let kept = try ElectronicOriginal.make(sourceName: "zmluva.asice", sourceData: container, evidence: evidence)
        XCTAssertEqual(kept.kind, .asicE(entryName: "zmluva.pdf"))
        XCTAssertEqual(kept.plan, .keep(format: E2ECodelists.pdfa2Format, formatOther: nil))
    }

    func testSingleSignedPdfContainerIsNowAccepted() throws {
        let bytes = pdfBytes(0x5A, count: 1000)
        var file = object("zmluva.pdf", bytes)
        file.nestedSignatures = [pades("P-1", revision: 900)]
        let original = try container([file])
        XCTAssertEqual(original.kind, .asicEMultiple)
        XCTAssertEqual(original.documents.map(\.name), ["zmluva-1", "zmluva-2"])
        guard case .convert = original.plan else { return XCTFail("a signed PDF in a container is converted") }
    }

    func testNestedSignaturesMissingFromTheTreeAreRefused() {
        var file = object("zmluva.pdf", pdfBytes(0x5A, count: 1000))
        file.nestedSignatures = [pades("P-1", revision: 900)]
        file.treeNested = false
        XCTAssertThrowsError(try container([file])) { error in
            XCTAssertEqual(error as? ElectronicOriginalError, .nestedSignaturesUnreadable(name: "zmluva.pdf"))
            XCTAssertEqual(error.localizedDescription,
                           "Podpisy v súbore zmluva.pdf sa nepodarilo overiť. Skúste overenie znova.")
        }
    }

    func testUnreadableNestedEvidenceIsRefused() {
        var file = object("zmluva.pdf", pdfBytes(0x5A, count: 1000))
        file.problem = "NESTED_UNREADABLE"
        XCTAssertThrowsError(try container([file])) {
            XCTAssertEqual($0 as? ElectronicOriginalError, .nestedSignaturesUnreadable(name: "zmluva.pdf"))
        }
    }

    func testNestedStateComesFromTheTreeAndReachesTheGate() throws {
        var file = object("zmluva.pdf", pdfBytes(0x5A, count: 1000))
        var nested = pades("P-1", revision: 1000)
        nested.indication = "TOTAL_FAILED"
        file.nestedSignatures = [nested]
        let original = try container([file])
        XCTAssertEqual(original.authorizations.first { $0.signatureID == "P-1" }?.state, .invalid)
        guard case .blocked = E2EVerificationGate.decide(original) else {
            return XCTFail("an invalid nested signature must block")
        }
    }

    func testTooManyAuthorizationsIsRefused() {
        let signatures = (1...100).map { signature("S-\($0)") }
        XCTAssertThrowsError(try original(signatures)) { error in
            XCTAssertEqual(error as? ElectronicOriginalError, .tooManyAuthorizations(100))
            XCTAssertEqual(error.localizedDescription,
                           "Dokument má 100 autorizácií. Formulár doložky ich pripúšťa najviac 99.")
        }
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
