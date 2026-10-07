// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

public enum EZZKEnvironment: String, Codable, CaseIterable, Sendable {
    case sandbox
    case production

    public var portalBaseURL: URL {
        switch self {
        case .sandbox:
            URL(string: "https://ezzk-test.iomo.sk")!
        case .production:
            URL(string: "https://ezzk.iomo.sk")!
        }
    }

    public var apiBaseURL: URL {
        portalBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("zzkservice")
            .appendingPathComponent("v1")
    }

    public var soapLoginURL: URL {
        portalBaseURL
            .appendingPathComponent("Iam.Core3.Svc.Wcf")
            .appendingPathComponent("LogInService.svc")
    }

    public var soapServiceURL: URL {
        portalBaseURL
            .appendingPathComponent("EZZK.Svc.Wcf")
            .appendingPathComponent("EZZKService.svc")
    }

    /// SHA-256 of the leaf certificate this environment must present, lowercase hex.
    /// Test uses a self-signed certificate (renewed 2026-09-28, valid until 2027-10-25); production uses system trust.
    public var pinnedCertificateSHA256: String? {
        switch self {
        case .sandbox:
            "c644c9fcf80417880eecc8fdffccc19d9e495d878e6473e04d9c3a366f8cca09"
        case .production:
            nil
        }
    }

    public var authorityID: String {
        switch self {
        case .sandbox:
            "ezzk-sandbox"
        case .production:
            "ezzk-production"
        }
    }
}
