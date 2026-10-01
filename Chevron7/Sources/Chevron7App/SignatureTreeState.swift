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
