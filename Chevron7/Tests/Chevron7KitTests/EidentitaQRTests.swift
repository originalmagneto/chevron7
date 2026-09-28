// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class EidentitaQRTests: XCTestCase {
    private static let link = "sk.minv.sca://sign?qr=true&linkUrl=https://agp.dev.slovensko.digital/c/1/s/2/parameters?session_token=abc"

    func testParsesEscapedHref() {
        let html = #"<a href="sk.minv.sca://sign?qr=true&amp;linkUrl=https://agp.dev.slovensko.digital/c/1/s/2/parameters?session_token=abc">QR</a>"#
        XCTAssertEqual(EidentitaQR.url(fromHTML: html)?.absoluteString, Self.link)
    }

    func testParsesPlainHref() {
        let html = #"<div>scan <a href="\#(Self.link)">open</a></div>"#
        XCTAssertEqual(EidentitaQR.url(fromHTML: html)?.absoluteString, Self.link)
    }

    func testUnescapesDoubleEscapedHref() {
        let html = #"<a href="sk.minv.sca://sign?qr=true&amp;amp;linkUrl=https://x.test/p?t=1">QR</a>"#
        XCTAssertEqual(EidentitaQR.url(fromHTML: html)?.absoluteString,
                       "sk.minv.sca://sign?qr=true&linkUrl=https://x.test/p?t=1")
    }

    func testReturnsNilWithoutScheme() {
        XCTAssertNil(EidentitaQR.url(fromHTML: "<p>no QR here</p>"))
        XCTAssertNil(EidentitaQR.url(fromHTML: ""))
    }
}
