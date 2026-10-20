// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CoreGraphics
import Foundation

public struct SignatureAsset: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case png
        case pdf
    }

    public let id: UUID
    public let kind: Kind
    public let managedFilename: String
}

public struct VisibleSignaturePlacement: Sendable, Equatable {
    public var pageIndex: Int
    public var pageRect: CGRect
    public var rotationDegrees: Double

    public init(pageIndex: Int, pageRect: CGRect, rotationDegrees: Double) {
        self.pageIndex = pageIndex
        self.pageRect = pageRect
        self.rotationDegrees = rotationDegrees
    }
}

/// How much of the visible stamp is the signature itself.
/// `.detailed` is the certificate card. `.compact` keeps the mark, with a seal and a clock beside it.
public enum VisibleSignatureLayout: String, Codable, Sendable, Equatable {
    case detailed
    case compact
}

public struct VisibleSignatureCardContent: Sendable, Equatable {
    public var signerName: String
    public var certificateName: String?
    public var certificateQualification: String?
    public var timestampAuthorityName: String?

    public init(
        signerName: String,
        certificateName: String? = nil,
        certificateQualification: String? = nil,
        timestampAuthorityName: String? = nil
    ) {
        self.signerName = signerName
        self.certificateName = certificateName
        self.certificateQualification = certificateQualification
        self.timestampAuthorityName = timestampAuthorityName
    }
}
