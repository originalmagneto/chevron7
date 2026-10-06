// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7WebBridge

/// The handler's failure reply is what ditec.js maps to a D.Bridge error code:
/// `cancelled: true` becomes ERROR_CANCELLED (1), which the portals keep silent.
final class WebSigningBridgeReplyTests: XCTestCase {
    func testACancellationIsMarkedForThePage() {
        let reply = WebSigningBridge.failureReply(error: WebSigningBridge.cancelledMessage, done: true)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["done"] as? Bool, true)
        XCTAssertEqual(reply["cancelled"] as? Bool, true)
        XCTAssertEqual(reply["error"] as? String, WebSigningBridge.cancelledMessage)
    }

    func testAnyOtherFailureIsNotACancellation() {
        let reply = WebSigningBridge.failureReply(error: "Nesprávny PIN.")
        XCTAssertNil(reply["cancelled"])
        XCTAssertNil(reply["done"])
        XCTAssertEqual(reply["error"] as? String, "Nesprávny PIN.")
    }
}
