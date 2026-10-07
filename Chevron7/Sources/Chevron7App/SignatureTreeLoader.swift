// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Observation
import Chevron7Kit

/// A file's signature tree: the structural tree first (awaited), then full validation in
/// the background, so signing and document switches never wait for the trusted lists.
/// A run token drops results that arrive after `reset` or a newer `load`.
@MainActor
@Observable
final class SignatureTreeLoader {
    private(set) var state = SignatureTreeState()
    private(set) var validationTask: Task<Void, Never>?
    @ObservationIgnored private var run = UUID()
    @ObservationIgnored private let provider: any QualifiedSigningProviding

    init(provider: any QualifiedSigningProviding) {
        self.provider = provider
    }

    func load(_ url: URL) async {
        let run = UUID()
        self.run = run
        state = SignatureTreeState(tree: SignatureTree(), phase: .inspecting)
        let inspected = await provider.inspectSignatureTree(in: url)
        guard self.run == run else { return }
        switch inspected {
        case .failed(let reason):
            state = SignatureTreeState(tree: SignatureTree(), phase: .failed(reason))
            setValidationTask(nil)
        case .tree(let tree):
            let summary = SignatureTreeSummary(tree: tree)
            guard summary.total > 0 || summary.unverifiedDocuments > 0 else {
                // No signatures and nothing unverified: there is nothing to validate.
                state = SignatureTreeState(tree: tree, phase: .validated)
                setValidationTask(nil)
                return
            }
            state = SignatureTreeState(tree: tree, phase: .structural)
            setValidationTask(Task { [weak self] in
                await self?.validate(url, run: run, keptTreeWasValidated: false)
            })
        }
    }

    func revalidate(_ url: URL) async {
        // A failed inspection left no tree to validate; validating it would turn the
        // failure into an empty tree, which reads as an unsigned document.
        if case .failed = state.phase {
            await load(url)
            await validationTask?.value
            return
        }
        let run = UUID()
        self.run = run
        let wasValidated = state.phase == .validated
        state.phase = .structural
        let task = Task<Void, Never> { [weak self] in
            await self?.validate(url, run: run, keptTreeWasValidated: wasValidated)
        }
        setValidationTask(task)
        await task.value
    }

    func reset() {
        run = UUID()
        state = SignatureTreeState()
        setValidationTask(nil)
    }

    /// `keptTreeWasValidated`: the tree shown while this runs came from an earlier validation,
    /// so a failure must not leave its verdicts (green) under "the result is only structural".
    private func validate(_ url: URL, run: UUID, keptTreeWasValidated: Bool) async {
        let validated = await provider.validateSignatureTree(in: url)
        guard self.run == run else { return }
        switch validated {
        case .tree(let tree):
            state = SignatureTreeState(tree: tree, phase: .validated)
        case .failed(let reason):
            if keptTreeWasValidated {
                state.tree = state.tree.withoutValidationVerdicts()
            }
            state.phase = .validationUnavailable(reason)
        }
    }

    /// Cancels the validation being replaced, which also ends its engine request.
    private func setValidationTask(_ task: Task<Void, Never>?) {
        if validationTask != task { validationTask?.cancel() }
        validationTask = task
    }
}
