// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit

/// What the signing screens know about a file's signatures right now.
struct SignatureTreeState: Equatable {
    enum Phase: Equatable {
        case idle
        /// Structural inspection is running; nothing to show yet.
        case inspecting
        /// The structural tree is shown; full validation is running.
        case structural
        /// The tree was validated against the EU trusted lists.
        case validated
        /// Full validation failed; the structural tree stays.
        case validationUnavailable(String)
        /// Even structural inspection failed. Never shown as "no signature".
        case failed(String)
    }

    var tree = SignatureTree()
    var phase: Phase = .idle

    var isValidating: Bool { phase == .structural }
}

extension SignatureTree {
    /// The tree as structural knowledge only, for when a validation that confirmed it can no
    /// longer be relied on: every signature at every level becomes indeterminate and keeps no
    /// qualification nor qualified timestamp, which only full validation can confirm.
    func withoutValidationVerdicts() -> SignatureTree {
        SignatureTree(
            signatures: signatures.map { signature in
                var signature = signature
                signature.state = .indeterminate
                signature.hasQualifiedTimestamp = false
                signature.certificateQualification = nil
                return signature
            },
            documents: documents.map { document in
                guard case .signed(let kind, let nested) = document.content else { return document }
                return SignedDataObject(name: document.name,
                                        content: .signed(kind, nested.withoutValidationVerdicts()))
            })
    }
}
