// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// The card step the view shows while a guarded ZaKo action waits for it.
enum ZakoCardPrompt: String, Identifiable, Equatable {
    case insertCard
    case enterPIN

    var id: String { rawValue }
}

/// What the card flow does once the mandate certificate is confirmed.
enum ZakoCardAction: Equatable {
    case evidenceNumber
    case authorization
}

/// Whether the card in the reader can carry a guaranteed conversion.
enum ZakoMandateGate: Equatable {
    /// The Demo signing provider: no card, no MQC.
    case notRequired
    case ready(label: String)
    /// A card is there, but its certificates show only after the PIN or BOK (an eID, or
    /// a card macOS cannot read without its driver).
    case needsUnlock
    case insertCard
    case noMandate

    /// Why a real evidence number is not allocated yet, or nil when it may be. A card
    /// that still needs its PIN is refused here; `requestEvidenceNumber` asks for it.
    var evidenceNumberRefusal: String? {
        switch self {
        case .notRequired, .ready: nil
        case .insertCard: ZakoSessionStore.insertMandateCardMessage
        case .noMandate: ZakoSessionStore.noMandateMessage
        case .needsUnlock: ZakoSessionStore.unlockCardMessage
        }
    }
}

extension ZakoSessionStore {
    nonisolated static let noMandateMessage =
        "Na vloženej karte nie je mandátny certifikát (MQC). Zaručenú konverziu možno vykonať iba s mandátnym certifikátom advokáta, bez neho sa nepridelí ani evidenčné číslo."
    nonisolated static let insertMandateCardMessage =
        "Vložte do čítačky kartu s mandátnym certifikátom (MQC). Bez nej sa evidenčné číslo nepridelí a konverzia sa nedá autorizovať."
    nonisolated static let unlockCardMessage =
        "Mandátny certifikát na tejto karte sa overí až po zadaní PIN alebo BOK."

    var mandateGate: ZakoMandateGate {
        if signingProviderIsDemo { return .notRequired }
        if hasResolvedCertificate {
            if let mandate = identities.first(where: { $0.isMandateCertificate }) {
                return .ready(label: mandate.label)
            }
            return .noMandate
        }
        switch mandateCardState {
        case .mandate(let label): return .ready(label: label)
        case .noMandate: return .noMandate
        case .noCard: return identities.isEmpty ? .insertCard : .needsUnlock
        }
    }

    /// "Získať číslo": outside Demo the card with its MQC comes first.
    func requestEvidenceNumber() async {
        guard !fetchingEvidenceNumber, cardPrompt == nil else { return }
        guard settingsStore.ezzkAccountController.mode != .demo, !signingProviderIsDemo else {
            await fetchEvidenceNumber()
            return
        }
        pendingCardAction = .evidenceNumber
        await advanceCardFlow()
    }

    /// "Autorizovať konverziu": card, PIN or BOK, the MQC, then the signature.
    func beginAuthorization() async {
        guard !isAuthorizing, cardPrompt == nil else { return }
        lastError = nil
        guard !signingProviderIsDemo else {
            await authorizeAndSign()
            return
        }
        pendingCardAction = .authorization
        await advanceCardFlow()
    }

    /// The authorize button is live before a card is in: the card is a step of the flow.
    var canBeginAuthorization: Bool {
        if signingProviderIsDemo, selectedIdentityID == nil || requiresMandateOverride { return false }
        if direction == .electronicToElectronic { return e2eReadyToAuthorize }
        let result = AttestationPreflight.evaluate(
            attestation,
            securityElements: securityElements,
            hasSelectedIdentity: true,
            mandateRequirementSatisfied: true,
            inputSignatureInspection: inputSignatureInspection,
            unreviewedNonEmptyPages: unreviewedNonEmptyPages, documentPageCount: analysis.totalPages)
        // The evidence number is allocated by the authorization itself.
        return result.errors.allSatisfy { $0 == .missingEvidenceNumber }
            && result.unreviewedNonEmptyPages.isEmpty && preflightErrors.isEmpty
    }

    /// Moves the pending action on as far as the card allows: it stops at a prompt, at a
    /// refusal, or runs the action.
    func advanceCardFlow() async {
        guard let action = pendingCardAction else { return }
        cardPrompt = nil
        // Only what the reader reports: `refreshIdentities` would also try a remembered PIN,
        // and the resolution below would then send a wrong one to the card a second time.
        await readCard()
        gate: switch mandateGate {
        case .notRequired:
            break
        case .insertCard:
            cardPrompt = .insertCard
            return
        case .noMandate:
            finishCardFlow(refusal: Self.noMandateMessage)
            return
        case .ready, .needsUnlock:
            // A number needs only to know the MQC is there; a signature needs the
            // certificates read from the card.
            if action == .evidenceNumber, case .ready = mandateGate { break gate }
            if !hasResolvedCertificate {
                if cardNeedsTypedPIN, signingPIN.isEmpty {
                    cardPrompt = .enterPIN
                    return
                }
                await resolveCertificateForAuthorization(force: true)
                guard hasResolvedCertificate else {
                    if cardNeedsTypedPIN {
                        // A refused PIN is never tried again on its own: it would burn a retry.
                        signingPIN = ""
                        cardPrompt = .enterPIN
                    } else {
                        finishCardFlow(refusal: certificateLoadError ?? Self.unlockCardMessage)
                    }
                    return
                }
            }
            guard let mandate = identities.first(where: { $0.isMandateCertificate }) else {
                finishCardFlow(refusal: Self.noMandateMessage)
                return
            }
            selectedIdentityID = mandate.id
        }
        pendingCardAction = nil
        switch action {
        case .evidenceNumber: await fetchEvidenceNumber()
        case .authorization: await authorizeAndSign()
        }
    }

    func submitCardPIN(_ pin: String) async {
        guard cardPrompt == .enterPIN, !pin.isEmpty else { return }
        signingPIN = pin
        await advanceCardFlow()
    }

    func cancelCardFlow() {
        pendingCardAction = nil
        cardPrompt = nil
    }

    /// Runs while the "insert the card" prompt is up and goes on once a card is there.
    func waitForCard() async {
        while cardPrompt == .insertCard, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard cardPrompt == .insertCard, !Task.isCancelled else { return }
            await readCard()
            if mandateGate != .insertCard {
                await advanceCardFlow()
                return
            }
        }
    }

    private func readCard() async {
        applyReaderIdentities(await signingProvider.availableIdentities())
    }

    private func finishCardFlow(refusal: String) {
        let action = pendingCardAction
        pendingCardAction = nil
        cardPrompt = nil
        lastError = refusal
        if action == .evidenceNumber {
            evidenceNumberError = refusal
            recomputePreflight()
        }
    }
}
