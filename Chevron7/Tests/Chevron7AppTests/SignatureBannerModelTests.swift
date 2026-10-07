// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit

final class SignatureBannerModelTests: XCTestCase {
    private func sig(_ id: String, _ name: String, _ state: DocumentSignatureInfo.State = .valid,
                     time: Date? = nil, qualification: String? = nil, qts: Bool = false,
                     covers: [String] = []) -> DocumentSignatureInfo {
        DocumentSignatureInfo(id: id, signerDisplayName: name, signingTime: time, hasQualifiedTimestamp: qts,
                              state: state, coveredDocuments: covers, certificateQualification: qualification)
    }

    private func state(_ signatures: [DocumentSignatureInfo], _ phase: SignatureTreeState.Phase = .validated,
                       documents: [SignedDataObject] = []) -> SignatureTreeState {
        SignatureTreeState(tree: SignatureTree(signatures: signatures, documents: documents), phase: phase)
    }

    func testNoBannerWithoutSignaturesOrWhileInspecting() {
        XCTAssertNil(SignatureBannerModel.make(from: SignatureTreeState()))
        XCTAssertNil(SignatureBannerModel.make(from: state([], .inspecting)))
        XCTAssertNil(SignatureBannerModel.make(from: state([], .validated)))
    }

    func testStructuralPhaseIsChecking() throws {
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A", .indeterminate), sig("2", "B", .indeterminate)], .structural)))
        XCTAssertEqual(model.tone, .checking)
        XCTAssertEqual(model.headline, "Overujem 2 podpisy voči dôveryhodným zoznamom…")
    }

    func testAllValidHeadlinesUseSlovakForms() throws {
        let one = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "Marián Čuprík")])))
        XCTAssertEqual(one.tone, .valid)
        XCTAssertEqual(one.headline, "Podpísané 1 podpisom, platný · Marián Čuprík")
        let two = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "Marián Čuprík"), sig("2", "Ján Novák")])))
        XCTAssertEqual(two.headline, "Podpísané 2 podpismi, oba platné · Marián Čuprík, Ján Novák")
        let five = try XCTUnwrap(SignatureBannerModel.make(from: state((1...5).map { sig("\($0)", "P\($0)") })))
        XCTAssertEqual(five.headline, "Podpísané 5 podpismi, všetky platné · P1, P2 a 3 ďalší")
    }

    func testSameSignerTwiceIsNamedOnce() throws {
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "Marián Čuprík"), sig("2", "Marián Čuprík")])))
        XCTAssertEqual(model.headline, "Podpísané 2 podpismi, oba platné · Marián Čuprík")
    }

    func testIndeterminateIsWarningAndInvalidWins() throws {
        let warning = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A"), sig("2", "B", .indeterminate)])))
        XCTAssertEqual(warning.tone, .warning)
        XCTAssertEqual(warning.headline, "1 z 2 podpisov sa nedalo overiť · A, B")
        let invalid = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A", .invalid), sig("2", "B", .indeterminate)])))
        XCTAssertEqual(invalid.tone, .invalid)
        XCTAssertEqual(invalid.headline, "1 podpis je neplatný · A, B")
        let three = try XCTUnwrap(SignatureBannerModel.make(from: state((1...3).map { sig("\($0)", "P\($0)", .invalid) })))
        XCTAssertEqual(three.headline, "3 podpisy sú neplatné · P1, P2 a 1 ďalší")
    }

    func testValidationUnavailableAndFailureAreWarnings() throws {
        let unavailable = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A", .indeterminate)], .validationUnavailable("Zoznam CZ sa nenačítal."))))
        XCTAssertEqual(unavailable.tone, .warning)
        XCTAssertEqual(unavailable.headline, "Podpisy sa nepodarilo overiť · A")
        XCTAssertEqual(unavailable.note, "Zoznam CZ sa nenačítal.")
        let failed = try XCTUnwrap(SignatureBannerModel.make(from: state([], .failed("Engine zlyhal."))))
        XCTAssertEqual(failed.tone, .warning)
        XCTAssertEqual(failed.headline, "Podpisy sa nepodarilo skontrolovať")
        XCTAssertEqual(failed.note, "Engine zlyhal.")
        XCTAssertTrue(failed.rows.isEmpty)
    }

    func testRowsCarryBadgesDetailAndUnknownSigner() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 7; components.hour = 11; components.minute = 25
        let time = try XCTUnwrap(Calendar.current.date(from: components))
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([
            sig("1", "Marián Čuprík", time: time, qualification: "QESIG", qts: true, covers: ["Uznesenie.pdf"]),
            sig("2", "", .valid)])))
        // The timestamp has its own line now, and "pokrýva" only says something when the
        // container holds more than one file.
        XCTAssertEqual(model.rows[0].badges, ["KEP"])
        XCTAssertEqual(model.rows[0].detail, "Podpísané 7. 10. 2026 11:25")
        XCTAssertEqual(model.rows[1].title, "Neznámy podpisovateľ")
        XCTAssertEqual(model.rows[1].detail, "")
        XCTAssertEqual(model.note, "Informatívne overenie voči dôveryhodným zoznamom EÚ")
    }

    func testNestedAndUnverifiedDocumentsBecomeRows() throws {
        let nested = SignatureTree(signatures: [sig("n1", "Ján Novák")])
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A")], documents: [
            SignedDataObject(name: "zmluva.pdf", content: .signed(.pdf, nested)),
            SignedDataObject(name: "velky.asice", content: .skipped(.tooLarge)),
            SignedDataObject(name: "priloha.xml", content: .plain)])))
        XCTAssertEqual(model.tone, .warning)
        XCTAssertEqual(model.rows.map(\.title), ["A", "zmluva.pdf", "Ján Novák", "velky.asice"])
        XCTAssertEqual(model.rows.map(\.depth), [0, 0, 1, 0])
        XCTAssertNil(model.rows[1].verdict)
        XCTAssertEqual(model.rows[3].warning, "Podpisy v tomto súbore sa neoverovali (súbor je príliš veľký).")
    }

    func testNewSignatureIsFirstAndMarked() throws {
        let existing = SignatureTree(signatures: [sig("old", "Ján Novák")])
        let result = SignatureTree(signatures: [sig("old", "Ján Novák"), sig("new", "Marián Čuprík")])
        let ids = SignatureBannerModel.newSignatureIDs(existing: existing, result: result)
        XCTAssertEqual(ids, ["new"])
        let model = try XCTUnwrap(SignatureBannerModel.make(from: SignatureTreeState(tree: result, phase: .validated), newSignatureIDs: ids))
        XCTAssertEqual(model.rows.map(\.title), ["Marián Čuprík", "Ján Novák"])
        XCTAssertEqual(model.rows.map(\.isNew), [true, false])
    }

    func testNewSignatureFallsBackToTheLatestWhenIdsDiffer() {
        let existing = SignatureTree(signatures: [sig("a", "Ján Novák")])
        let result = SignatureTree(signatures: [
            sig("x", "Ján Novák", time: Date(timeIntervalSince1970: 100)),
            sig("y", "Marián Čuprík", time: Date(timeIntervalSince1970: 200))])
        XCTAssertEqual(SignatureBannerModel.newSignatureIDs(existing: existing, result: result), ["y"])
        XCTAssertEqual(SignatureBannerModel.newSignatureIDs(existing: result, result: result), [])
    }

    func testZakoInspectionMapsToTheSameTones() throws {
        XCTAssertNil(SignatureBannerModel.make(from: .unavailable(detail: "Bez podpisov.")))
        let valid = try XCTUnwrap(SignatureBannerModel.make(from: .completed(signatures: [sig("1", "A")])))
        XCTAssertEqual(valid.tone, .valid)
        XCTAssertEqual(valid.note, "Kontrola vstupných elektronických podpisov bola dokončená.")
        let unknown = try XCTUnwrap(SignatureBannerModel.make(from: .completed(signatures: [sig("1", "A", .unknown)])))
        XCTAssertEqual(unknown.tone, .warning)
        let invalid = try XCTUnwrap(SignatureBannerModel.make(from: .completed(signatures: [sig("1", "A", .invalid)])))
        XCTAssertEqual(invalid.tone, .invalid)
    }

    /// The engine lists every PDF data object, an unsigned one as a signed PDF without
    /// signatures; "x.pdf · 0 podpisov" read as if the document were unsigned.
    func testUnsignedDataObjectsAreNotListedAndNestedFailuresAre() throws {
        let nestedContainer = SignatureTree(signatures: [sig("n1", "Ján Novák")], documents: [
            SignedDataObject(name: "hlboko.asice", content: .skipped(.depthLimit))])
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A")], documents: [
            SignedDataObject(name: "dokument.pdf", content: .signed(.pdf, SignatureTree())),
            SignedDataObject(name: "vnutorny.asice", content: .signed(.asic, nestedContainer))])))
        XCTAssertEqual(model.rows.map(\.title), ["A", "vnutorny.asice", "Ján Novák", "hlboko.asice"])
        XCTAssertEqual(model.rows.map(\.depth), [0, 0, 1, 1])
        XCTAssertEqual(model.rows[3].warning, "Podpisy v tomto súbore sa neoverovali (ďalšie vnorenie).")
        XCTAssertEqual(Set(model.rows.map(\.id)).count, model.rows.count)
    }

    /// The same signed PDF under two names must not give two rows one id.
    func testNestedRowIdsAreUniquePerDocument() throws {
        let nested = SignatureTree(signatures: [sig("same", "Ján Novák")])
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([], documents: [
            SignedDataObject(name: "a.pdf", content: .signed(.pdf, nested)),
            SignedDataObject(name: "b.pdf", content: .signed(.pdf, nested))])))
        XCTAssertEqual(Set(model.rows.map(\.id)).count, model.rows.count)
    }

    /// The verdict in words and the validator's reason, which the inspector rows showed.
    func testRowsNameTheVerdictAndItsReason() throws {
        var invalid = sig("1", "A", .invalid)
        invalid.detail = "Dokument bol po podpise zmenený."
        invalid.format = "PAdES_BASELINE_B"
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([invalid, sig("2", "B")])))
        XCTAssertEqual(model.rows[0].verdictLabel, "Neplatný")
        XCTAssertEqual(model.rows[0].reason, "Dokument bol po podpise zmenený.")
        XCTAssertEqual(model.rows[0].detail, "PAdES Baseline B")
        XCTAssertEqual(model.rows[1].verdictLabel, "Platný")
        XCTAssertNil(model.rows[1].reason)
    }

    /// Only a source tree that was actually inspected tells which signatures are new; a
    /// failed or still running inspection leaves it empty and would mark every one.
    func testNewSignaturesOnlyFromAnInspectedSource() {
        let result = SignatureTree(signatures: [sig("old", "Ján Novák"), sig("new", "Marián Čuprík")])
        let existing = SignatureTree(signatures: [sig("old", "Ján Novák")])
        for phase: SignatureTreeState.Phase in [.idle, .inspecting, .failed("x")] {
            XCTAssertEqual(SignatureBannerModel.newSignatureIDs(
                existing: SignatureTreeState(tree: SignatureTree(), phase: phase), result: result), [], "\(phase)")
        }
        XCTAssertEqual(SignatureBannerModel.newSignatureIDs(
            existing: SignatureTreeState(tree: existing, phase: .structural), result: result), ["new"])
    }

    /// The owner asked for the timestamp in words: who issued it, whether it is qualified,
    /// and when. The authority and the qualification come only from full validation.
    func testTimestampLineAfterValidation() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 7
        components.hour = 11; components.minute = 18; components.second = 42
        let stamp = try XCTUnwrap(Calendar.current.date(from: components))
        let signature = DocumentSignatureInfo(id: "1", signerDisplayName: "A", format: "XAdES_BASELINE_T",
                                              hasQualifiedTimestamp: true, state: .valid,
                                              timestampAuthority: "Belgium BOSA", timestampTime: stamp)
        let validated = try XCTUnwrap(SignatureBannerModel.make(from: state([signature])))
        XCTAssertEqual(validated.rows[0].timestamp, "Časová pečiatka: Belgium BOSA, kvalifikovaná · 7. 10. 2026 11:18:42")

        var unqualified = signature
        unqualified.hasQualifiedTimestamp = false
        let plain = try XCTUnwrap(SignatureBannerModel.make(from: state([unqualified])))
        XCTAssertEqual(plain.rows[0].timestamp, "Časová pečiatka: Belgium BOSA, nekvalifikovaná · 7. 10. 2026 11:18:42")

        // The structural pass names the issuer DN, not the authority, and judges no qualification.
        var structural = unqualified
        structural.timestampAuthority = "CN=BOSA TSA, O=Belgium"
        structural.state = .indeterminate
        let checking = try XCTUnwrap(SignatureBannerModel.make(from: state([structural], .structural)))
        XCTAssertEqual(checking.rows[0].timestamp, "Časová pečiatka · 7. 10. 2026 11:18:42")

        let none = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("2", "B")])))
        XCTAssertNil(none.rows[0].timestamp)
    }

    func testCoverageOnlyInAContainerWithSeveralFiles() throws {
        let covering = sig("1", "A", covers: ["zmluva.pdf"])
        let single = try XCTUnwrap(SignatureBannerModel.make(from: state([covering], documents: [
            SignedDataObject(name: "zmluva.pdf", content: .plain)])))
        XCTAssertEqual(single.rows[0].detail, "")
        let several = try XCTUnwrap(SignatureBannerModel.make(from: state([covering], documents: [
            SignedDataObject(name: "zmluva.pdf", content: .plain),
            SignedDataObject(name: "dolozka.xml.xdcf", content: .plain)])))
        XCTAssertEqual(several.rows[0].detail, "pokrýva zmluva.pdf")
    }
}
