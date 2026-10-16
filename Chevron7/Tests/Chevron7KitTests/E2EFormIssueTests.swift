// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class E2EFormIssueTests: XCTestCase {
    func testUsedDeviceErrorFromTheOwnersLiveTestBecomesAdvice() {
        let libxml = "riadok 1: element UsedDevice: Schemas validity error : Element '{https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfElectronicDocumentToElectronicDocument.sk/1.0}UsedDevice': [facet 'minLength'] The value has a length of '0'"
        let issue = E2EFormIssue.from(FormSchemaValidator.Failure.invalid(details: libxml))
        XCTAssertTrue(issue.advice.contains("Použitý prostriedok"))
        XCTAssertTrue(issue.advice.contains("Evidenčné číslo sa nepoužilo"))
        XCTAssertFalse(issue.advice.contains("Schemas validity error"))
        XCTAssertEqual(issue.technicalDetail, libxml)
    }

    func testDocumentTypeErrorNamesTheStep() {
        let issue = E2EFormIssue.from(schemaDetails: "Element '{urn:x}OriginalDocumentType': [facet 'minLength'] The value has a length of '0'")
        XCTAssertEqual(issue.advice, "Údaj „Druh dokumentu“ chýba: v kroku Osvedčovacia doložka. Evidenčné číslo sa nepoužilo.")
    }

    func testUnknownElementGetsAGenericAdvice() {
        let issue = E2EFormIssue.from(schemaDetails: "Element '{urn:x}Something': bad")
        XCTAssertTrue(issue.advice.hasPrefix("Osvedčovaciu doložku alebo záznam sa nepodarilo vytvoriť"))
    }

    func testDefaultUsedDeviceNamesTheProduct() {
        XCTAssertTrue(E2EFormModel.defaultUsedDevice.hasPrefix("Chevron7"))
    }
}
