// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

final class EZZKSOAPRequestTests: XCTestCase {
    private let person = EZZKPerson(corporateBodyFullName: "Advokátska kancelária A & B <s.r.o.>", ico: "42249180")

    func testEnvironmentSOAPEndpointsAndPin() {
        XCTAssertEqual(EZZKEnvironment.sandbox.soapLoginURL.absoluteString,
                       "https://ezzk-test.iomo.sk/Iam.Core3.Svc.Wcf/LogInService.svc")
        XCTAssertEqual(EZZKEnvironment.sandbox.soapServiceURL.absoluteString,
                       "https://ezzk-test.iomo.sk/EZZK.Svc.Wcf/EZZKService.svc")
        XCTAssertEqual(EZZKEnvironment.production.soapLoginURL.absoluteString,
                       "https://ezzk.iomo.sk/Iam.Core3.Svc.Wcf/LogInService.svc")
        XCTAssertEqual(EZZKEnvironment.production.soapServiceURL.absoluteString,
                       "https://ezzk.iomo.sk/EZZK.Svc.Wcf/EZZKService.svc")
        XCTAssertEqual(EZZKEnvironment.sandbox.pinnedCertificateSHA256,
                       "c644c9fcf80417880eecc8fdffccc19d9e495d878e6473e04d9c3a366f8cca09")
        XCTAssertNil(EZZKEnvironment.production.pinnedCertificateSHA256)
    }

    func testURLRequestCarriesSOAP12ContentTypeAndAddressingHeaders() throws {
        let messageID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let request = EZZKSOAPRequest.serverTime().urlRequest(in: .sandbox, messageID: messageID)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ezzk-test.iomo.sk/EZZK.Svc.Wcf/EZZKService.svc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "application/soap+xml; charset=utf-8; action=\"http://www.ditec.sk/IEZZKService/IEZZKService/GetOptions\"")
        let document = try XMLDocument(data: try XCTUnwrap(request.httpBody), options: [.nodeLoadExternalEntitiesNever])
        XCTAssertEqual(try value(document, "Action"), "http://www.ditec.sk/IEZZKService/IEZZKService/GetOptions")
        XCTAssertEqual(try value(document, "MessageID"), "urn:uuid:11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(try value(document, "To"), "https://ezzk-test.iomo.sk/EZZK.Svc.Wcf/EZZKService.svc")
    }

    func testLoginTargetsLoginServiceAndEscapesCredentials() throws {
        let request = EZZKSOAPRequest.login(login: "user<1>", password: "p&ss\"word")

        XCTAssertEqual(request.url(in: .production).absoluteString,
                       "https://ezzk.iomo.sk/Iam.Core3.Svc.Wcf/LogInService.svc")
        XCTAssertEqual(request.action, "http://ditec/2017/06/iam/core/ILogInService/LogIn")
        XCTAssertFalse(request.requiresAuthentication)
        let document = try XMLDocument(xmlString: request.body, options: [.nodeLoadExternalEntitiesNever])
        XCTAssertEqual(try value(document, "Login"), "user<1>")
        XCTAssertEqual(try value(document, "Password"), "p&ss\"word")
    }

    func testAuthenticationAndConsequenceFlags() {
        let now = Date()
        XCTAssertFalse(EZZKSOAPRequest.serverTime().requiresAuthentication)
        XCTAssertFalse(EZZKSOAPRequest.publicRecord(evidenceNumber: "1", executionTime: nil, at: now).requiresAuthentication)
        XCTAssertFalse(EZZKSOAPRequest.publicRecord(evidenceNumber: "1", executionTime: nil, at: now).isConsequential)
        XCTAssertTrue(EZZKSOAPRequest.record(evidenceNumber: "1", purpose: .xml, executionTime: nil, at: now).requiresAuthentication)
        XCTAssertFalse(EZZKSOAPRequest.record(evidenceNumber: "1", purpose: .xml, executionTime: nil, at: now).isConsequential)
        XCTAssertTrue(EZZKSOAPRequest.evidenceNumbers(person: person).isConsequential)
        XCTAssertTrue(EZZKSOAPRequest.consume(evidenceNumber: "1", person: person).isConsequential)
        XCTAssertTrue(EZZKSOAPRequest.receive(records: [], person: person).isConsequential)
    }

    func testRequestBodiesValidateAgainstProductionSchemaSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_789_653_359)
        let attachment = EZZKRecordAttachment(evidenceNumber: "1563-260824-1",
                                              mimeType: "application/vnd.etsi.asic-e+zip",
                                              data: Data("zip".utf8))
        let cases: [(String, EZZKSOAPRequest, String)] = [
            ("login", .login(login: "ucet", password: "heslo"), "LogInService-xsd0.xsd"),
            ("options", .serverTime(), "EZZKService-xsd0.xsd"),
            ("numbers", .evidenceNumbers(person: person), "EZZKService-xsd0.xsd"),
            ("consume", .consume(evidenceNumber: "260917-dD9DbFE4f7", person: person), "EZZKService-xsd0.xsd"),
            ("consume-oldest", .consume(evidenceNumber: nil, person: person), "EZZKService-xsd0.xsd"),
            ("public-record", .publicRecord(evidenceNumber: "1563-260824-1", executionTime: now, at: now), "EZZKService-xsd0.xsd"),
            ("record", .record(evidenceNumber: "1563-260824-1", purpose: .original, executionTime: nil, at: now), "EZZKService-xsd0.xsd"),
            ("receive", .receive(records: [attachment], person: person), "EZZKService-xsd0.xsd")
        ]
        for (name, request, schema) in cases {
            let result = try xmllint(request.body, schema: schema)
            XCTAssertEqual(result.status, 0, "\(name): \(result.message)")
        }
    }

    func testMissingRequiredElementFailsSchemaValidation() throws {
        let body = EZZKSOAPRequest.evidenceNumbers(person: person).body
            .replacingOccurrences(of: "<w:EvidenceNumberAmount i:nil=\"true\"/>", with: "")
        let result = try xmllint(body, schema: "EZZKService-xsd0.xsd")
        XCTAssertNotEqual(result.status, 0)
    }

    func testSOAPDateParsesWCFValues() {
        XCTAssertEqual(EZZKSOAPDate.date(from: "2026-08-24T16:37:43Z"), Date(timeIntervalSince1970: 1_787_589_463))
        XCTAssertEqual(EZZKSOAPDate.date(from: "2026-08-24T18:35:44+02:00"), Date(timeIntervalSince1970: 1_787_589_344))
        let fractional = EZZKSOAPDate.date(from: "2019-06-10T08:39:37.3150021Z")
        XCTAssertEqual(try XCTUnwrap(fractional).timeIntervalSince1970, 1_560_155_977.3150021, accuracy: 0.001)
        XCTAssertNil(EZZKSOAPDate.date(from: ""))
        XCTAssertNil(EZZKSOAPDate.date(from: "17. 9. 2026"))
        XCTAssertEqual(EZZKSOAPDate.string(from: Date(timeIntervalSince1970: 1_789_653_359)), "2026-09-17T13:55:59Z")
    }

    private func value(_ document: XMLDocument, _ localName: String) throws -> String? {
        try document.nodes(forXPath: "//*[local-name()='\(localName)']").first?.stringValue
    }

    private func xmllint(_ body: String, schema: String) throws -> (status: Int32, message: String) {
        let executable = URL(fileURLWithPath: "/usr/bin/xmllint")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("xmllint is needed to validate EZZK request bodies.")
        }
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schemaURL = package.appendingPathComponent("docs/reference/ezzk-soap/2026-09-17/production/\(schema)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ezzk-\(UUID().uuidString).xml")
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--nonet", "--noout", "--schema", schemaURL.path, file.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, message)
    }
}
