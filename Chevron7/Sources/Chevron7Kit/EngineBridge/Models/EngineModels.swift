// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

struct EngineCapabilities: Sendable, Equatable {
    let protocolVersion: Int
    let supportsQualifiedTimestamp: Bool

    init(protocolVersion: Int, supportsQualifiedTimestamp: Bool) {
        self.protocolVersion = protocolVersion
        self.supportsQualifiedTimestamp = supportsQualifiedTimestamp
    }
}

struct SigningDriver: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let tokenPresent: Bool?
    /// Why this driver cannot be used (Slovak, for the person), nil when it can.
    let unavailableReason: String?

    init(id: String, displayName: String, tokenPresent: Bool? = nil, unavailableReason: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.tokenPresent = tokenPresent
        self.unavailableReason = unavailableReason
    }
}

struct SigningCertificate: Sendable, Equatable, Identifiable {
    let serialNumber: String
    let displayName: String
    let issuer: String
    let validFrom: Date
    let validUntil: Date
    let certificateKey: String
    let holderKey: String
    let certificateQualification: String?

    var id: String {
        certificateKey.isEmpty ? serialNumber : certificateKey
    }

    init(serialNumber: String, displayName: String) {
        self.serialNumber = serialNumber
        self.displayName = displayName
        issuer = ""
        validFrom = .distantPast
        validUntil = .distantFuture
        certificateKey = ""
        holderKey = ""
        certificateQualification = nil
    }

    init(
        serialNumber: String,
        displayName: String,
        issuer: String,
        validFrom: Date,
        validUntil: Date,
        certificateKey: String,
        holderKey: String,
        certificateQualification: String? = nil
    ) {
        self.serialNumber = serialNumber
        self.displayName = displayName
        self.issuer = issuer
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.certificateKey = certificateKey
        self.holderKey = holderKey
        self.certificateQualification = certificateQualification
    }
}
