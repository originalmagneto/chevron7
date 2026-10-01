// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

struct EmbeddedDocumentPreview: Sendable, Equatable {
    let displayName: String
    let mediaType: String
    let url: URL
}

enum SignatureValidationProgress: Sendable, Equatable {
    case provisional
    case validating
    case complete
    case incomplete(String)
}

struct PDFInspection: Sendable, Equatable {
    let files: [InspectedPDF]

    init(files: [InspectedPDF]) {
        self.files = files
    }
}

struct InspectedPDF: Sendable, Equatable, Identifiable {
    let id: String
    let isSignable: Bool
    let signatures: [ExistingPDFSignature]
    let documents: [String]
    /// The whole signature tree, including signatures inside embedded documents.
    let tree: SignatureTree

    init(id: String, isSignable: Bool, signatures: [ExistingPDFSignature] = [], documents: [String] = [],
         tree: SignatureTree = SignatureTree()) {
        self.id = id
        self.isSignable = isSignable
        self.signatures = signatures
        self.documents = documents
        self.tree = tree
    }
}

struct ExistingPDFSignature: Sendable, Equatable, Identifiable {
    let id: String
    let signerDisplayName: String?
    let validationState: SignatureValidationState
    let signingTime: Date?
    let format: String?
    let hasQualifiedTimestamp: Bool
    let subIndication: String?
    let validationReason: String?
    let documents: [String]

    init(
        id: String,
        signerDisplayName: String?,
        validationState: SignatureValidationState,
        signingTime: Date?,
        format: String?,
        hasQualifiedTimestamp: Bool,
        subIndication: String? = nil,
        validationReason: String? = nil,
        documents: [String] = []
    ) {
        self.id = id
        self.signerDisplayName = signerDisplayName
        self.validationState = validationState
        self.signingTime = signingTime
        self.format = format
        self.hasQualifiedTimestamp = hasQualifiedTimestamp
        self.subIndication = subIndication
        self.validationReason = validationReason
        self.documents = documents
    }
}

enum SignatureValidationState: Sendable, Equatable {
    case valid
    case invalid
    case indeterminate
}
