// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class ZakoRegimeTests: XCTestCase {
    private let before = ZakoRegime.recordFirstFrom.addingTimeInterval(-1)
    private let at = ZakoRegime.recordFirstFrom

    func testSwitchIsMidnightInBratislava() {
        XCTAssertEqual(ConversionFormModel.bratislavaDateTime(ZakoRegime.recordFirstFrom), "2027-01-01T00:00:00+01:00")
        XCTAssertEqual(ConversionFormModel.bratislavaDateTime(before), "2026-12-31T23:59:59+01:00")
    }

    func testEveryModeFollowsTheDateWithoutPreview() {
        for mode in AppSettings.EZZKMode.allCases {
            let old = ZakoRegime.resolve(conversionTime: before, mode: mode, preview: false, refusesOutsideDemo: false)
            XCTAssertEqual(old, .init(regime: .clauseFirst, formPackDate: before, refusal: nil), "\(mode)")
            let new = ZakoRegime.resolve(conversionTime: at, mode: mode, preview: false, refusesOutsideDemo: false)
            XCTAssertEqual(new, .init(regime: .recordFirst, formPackDate: at, refusal: nil), "\(mode)")
        }
    }

    func testPreviewForcesTheNewRegimeAndFormsOutsideProductionOnly() {
        for mode in [AppSettings.EZZKMode.demo, .test] {
            let resolution = ZakoRegime.resolve(conversionTime: before, mode: mode, preview: true, refusesOutsideDemo: false)
            XCTAssertEqual(resolution.regime, .recordFirst)
            XCTAssertEqual(resolution.formPackDate, ZakoRegime.recordFirstFrom)
        }
        let production = ZakoRegime.resolve(conversionTime: before, mode: .production, preview: true, refusesOutsideDemo: false)
        XCTAssertEqual(production.regime, .clauseFirst)
        XCTAssertEqual(production.formPackDate, before)
        // After the date the preview changes nothing: the real conversion time picks the pack.
        let after = ZakoRegime.resolve(conversionTime: at.addingTimeInterval(60), mode: .test, preview: true, refusesOutsideDemo: false)
        XCTAssertEqual(after.formPackDate, at.addingTimeInterval(60))
    }

    func testRefusalSwitchStopsRecordFirstOutsideDemoOnly() {
        XCTAssertNil(ZakoRegime.resolve(conversionTime: at, mode: .demo, preview: false, refusesOutsideDemo: true).refusal)
        XCTAssertEqual(ZakoRegime.resolve(conversionTime: at, mode: .test, preview: false, refusesOutsideDemo: true).refusal,
                       ZakoRecordFirstPolicy.refusalMessage)
        XCTAssertEqual(ZakoRegime.resolve(conversionTime: at, mode: .production, preview: false, refusesOutsideDemo: true).refusal,
                       ZakoRecordFirstPolicy.refusalMessage)
        XCTAssertNil(ZakoRegime.resolve(conversionTime: before, mode: .production, preview: false, refusesOutsideDemo: true).refusal)
    }

    func testShippedPolicyLetsTheNewFlowRun() {
        XCTAssertFalse(ZakoRecordFirstPolicy.refusesOutsideDemo)
    }

    func testFormPacksSplitAtTheSwitch() throws {
        let repository = FormPackRepository()
        let old = try repository.pack(for: .paperToElectronic, at: before)
        XCTAssertEqual(old.id, FormPackRepository.currentLegacyUnverified.id)
        XCTAssertEqual(FormPackRepository.recordForm(of: old), .record_1_0)
        let new = try repository.pack(for: .paperToElectronic, at: at)
        XCTAssertEqual(new.id, FormPackRepository.record12Unverified.id)
        XCTAssertEqual(new.recordVersion, "1.2")
        XCTAssertEqual(new.clauseVersion, "1.3")
        XCTAssertEqual(FormPackRepository.recordForm(of: new), .record_1_2)
        XCTAssertFalse(new.isProductionEligible)
    }
}
