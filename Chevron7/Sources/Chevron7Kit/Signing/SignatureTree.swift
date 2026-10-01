// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// One level of a document's signatures: its own signatures and, for an ASiC container,
/// its data objects, some of which carry signatures of their own.
public struct SignatureTree: Sendable, Equatable {
    public var signatures: [DocumentSignatureInfo]
    public var documents: [SignedDataObject]

    public init(signatures: [DocumentSignatureInfo] = [], documents: [SignedDataObject] = []) {
        self.signatures = signatures
        self.documents = documents
    }

    public var isContainer: Bool { !documents.isEmpty }
}

public struct SignedDataObject: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case pdf = "PDF"
        case asic = "ASIC"
    }

    public enum SkipReason: String, Sendable, Equatable {
        case depthLimit = "DEPTH_LIMIT"
        case tooLarge = "TOO_LARGE"
    }

    public enum Content: Sendable, Equatable {
        /// No signatures of its own (XML, XDCF, text, images).
        case plain
        case signed(Kind, SignatureTree)
        case skipped(SkipReason)
        case failed
    }

    public var name: String
    public var content: Content
    public var id: String { name }

    public init(name: String, content: Content) {
        self.name = name
        self.content = content
    }
}

public enum SignatureTreeResult: Sendable, Equatable {
    case tree(SignatureTree)
    case failed(String)
}

/// Worst-of summary over the whole tree. Indeterminate and unknown count together and
/// never as valid; a data object that could not be verified counts as indeterminate.
public struct SignatureTreeSummary: Sendable, Equatable {
    public private(set) var valid = 0
    public private(set) var invalid = 0
    public private(set) var indeterminateSignatures = 0
    public private(set) var unverifiedDocuments = 0
    /// Name of the top-level data object holding the worst result; nil for the top level.
    public private(set) var worstLocation: String?

    public var indeterminate: Int { indeterminateSignatures + unverifiedDocuments }
    public var total: Int { valid + invalid + indeterminateSignatures }

    public var overall: DocumentSignatureInfo.State {
        if invalid > 0 { return .invalid }
        if indeterminate > 0 { return .indeterminate }
        return valid > 0 ? .valid : .unknown
    }

    public init(tree: SignatureTree) {
        var firstInvalid: String??
        var firstIndeterminate: String??
        add(tree, location: nil, firstInvalid: &firstInvalid, firstIndeterminate: &firstIndeterminate)
        worstLocation = (firstInvalid ?? firstIndeterminate) ?? nil
    }

    private mutating func add(_ tree: SignatureTree, location: String?,
                              firstInvalid: inout String??, firstIndeterminate: inout String??) {
        for signature in tree.signatures {
            switch signature.state {
            case .valid:
                valid += 1
            case .invalid:
                invalid += 1
                if firstInvalid == nil { firstInvalid = .some(location) }
            case .indeterminate, .unknown:
                indeterminateSignatures += 1
                if firstIndeterminate == nil { firstIndeterminate = .some(location) }
            }
        }
        for document in tree.documents {
            let childLocation = location ?? document.name
            switch document.content {
            case .plain:
                break
            case .signed(_, let nested):
                add(nested, location: childLocation, firstInvalid: &firstInvalid,
                    firstIndeterminate: &firstIndeterminate)
            case .skipped, .failed:
                unverifiedDocuments += 1
                if firstIndeterminate == nil { firstIndeterminate = .some(childLocation) }
            }
        }
    }
}
