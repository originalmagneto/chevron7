import Foundation
import XCTest
@testable import Chevron7Integration

final class IntegrationContractTests: XCTestCase {
    func testIndependentWireFixtureAndResponse() throws {
        let fixture = Data(#"{"apiVersion":1,"requestId":"fixture-1","session":"opaque-owner","method":"sign","arguments":{"path":"/klient/Žiadosť.pdf","enabled":true,"attachments":[],"missing":null}}"#.utf8)
        let request = try IntegrationRequest.decode(fixture)
        XCTAssertEqual(request.arguments["path"]?.string, "/klient/Žiadosť.pdf")
        XCTAssertEqual(request.arguments["enabled"]?.bool, true)
        XCTAssertEqual(request.arguments["attachments"]?.array, [])
        XCTAssertEqual(request.arguments["missing"], .null)
        let response = IntegrationResponse(requestId: request.requestId, result: .object(["state": .string("completed")]))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        XCTAssertEqual(wire["apiVersion"] as? Int, 1)
        XCTAssertEqual(wire["requestId"] as? String, "fixture-1")
        XCTAssertEqual(wire["ok"] as? Bool, true)
        XCTAssertNil(wire["error"])
        XCTAssertNil(wire["session"])
    }

    func testRejectsUnknownMajorVersionAndUnknownEnvelopeFields() throws {
        let base = IntegrationRequest(session: "session", method: "status")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        object["pin"] = "must-not-be-accepted"
        assertCode("INVALID_REQUEST") { _ = try IntegrationRequest.decode(JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "pin")
        object["apiVersion"] = 2
        assertCode("INCOMPATIBLE_VERSION") { _ = try IntegrationRequest.decode(JSONSerialization.data(withJSONObject: object)) }
        object["apiVersion"] = 1
        object["method"] = "zako.convert"
        assertCode("UNSUPPORTED_METHOD") { _ = try IntegrationRequest.decode(JSONSerialization.data(withJSONObject: object)) }
    }

    func testMalformedEnvelopeIsAStableError() {
        for fixture in ["null", "[]", "{", #"{"apiVersion":true}"#] {
            assertCode("INVALID_REQUEST") { _ = try IntegrationRequest.decode(Data(fixture.utf8)) }
        }
    }

    func testErrorEnvelopeHasStableExitSemantics() throws {
        let error = IntegrationError(code: "OUTPUT_DELIVERY_FAILED", message: "Cannot save", retryable: false)
        let response = IntegrationResponse(requestId: "delivery", error: error)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        XCTAssertNil(wire["result"])
        XCTAssertEqual((wire["error"] as? [String: Any])?["code"] as? String, "OUTPUT_DELIVERY_FAILED")
        XCTAssertEqual(error.exitCode, 7)
        XCTAssertEqual(IntegrationError(code: "OUTCOME_UNKNOWN", message: "uncertain").exitCode, 9)
        XCTAssertEqual(IntegrationError(code: "VALIDATION_NOT_VALID", message: "unknown").exitCode, 10)
    }
}

func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> Void) {
    XCTAssertThrowsError(try work(), file: file, line: line) { error in
        XCTAssertEqual((error as? IntegrationError)?.code, code, file: file, line: line)
    }
}
