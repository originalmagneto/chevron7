// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// The card step the view shows while a guarded ZaKo action waits for it.
enum ZakoCardPrompt: String, Identifiable, Equatable {
    /// Shown at once while the drivers are asked which card is in the reader (seconds).
    case checkingCard
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
        await startCardFlow(.evidenceNumber)
    }

    /// "Autorizovať konverziu": card, PIN or BOK, the MQC, then the signature.
    func beginAuthorization() async {
        guard !externalSigningIsBusy() else { return }
        guard !isAuthorizing, cardPrompt == nil else { return }
        lastError = nil
        // A one PDF that cannot be delivered (Ostrá evidencia, no engine) is refused before the
        // card, its PIN or its certificates are asked for. A record-first resume is decided by the
        // output it started with, so a changed setting never stops it here.
        if recordFirstPending == nil, settings.zakoClientOutput == .singlePDF,
           let refusal = ZakoSinglePDFDelivery.refusal(mode: settingsStore.ezzkAccountController.mode,
                                                       viaMobile: false, provider: signingProvider) {
            lastError = refusal
            return
        }
        guard !signingProviderIsDemo else {
            await authorizeAndSign()
            return
        }
        await startCardFlow(.authorization)
    }

    /// Starts the card flow with feedback at once: asking the drivers which card is there takes
    /// seconds, so "Kontrolujem kartu…" shows before the first await. When the reader slots
    /// report no card at all, the prompt to insert one comes without asking the drivers.
    private func startCardFlow(_ action: ZakoCardAction) async {
        pendingCardAction = action
        cardPrompt = .checkingCard
        if await readerSlotsHaveCard() == false {
            guard pendingCardAction == action, cardPrompt == .checkingCard else { return }
            cardPrompt = .insertCard
            return
        }
        await advanceCardFlow()
    }

    nonisolated static let ezzkSignedOutMessage = "Prihláste sa do EZZK v Nastaveniach (EZZK)."

    /// Outside Demo the number comes from EZZK, which needs the login saved in Settings. Said
    /// before the card and its PIN, so a signed-out account never costs a typed PIN.
    var ezzkSignInRefusal: String? {
        let controller = settingsStore.ezzkAccountController
        guard controller.mode != .demo, !controller.hasStoredCredentials else { return nil }
        return Self.ezzkSignedOutMessage
    }

    /// The authorize button is live before a card is in: the card is a step of the flow.
    var canBeginAuthorization: Bool {
        if signingProviderIsDemo, selectedIdentityID == nil || requiresMandateOverride { return false }
        if ezzkSignInRefusal != nil { return false }
        // A stored conversion signs its stored clause and document; there is no form to check.
        // The sign-in check stays first: finishing it still sends and looks up the record in EZZK.
        if isLoadedPendingConversion, recordFirstPending != nil { return true }
        if recordFirstPending == nil, settings.zakoClientOutput == .singlePDF,
           singlePDFProductionRefusal != nil { return false }
        if direction == .electronicToElectronic {
            return e2eReadyToAuthorize && e2eRecordFirstRefusal == nil
        }
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
        guard !externalSigningIsBusy() else { return }
        guard let action = pendingCardAction else { return }
        cardPrompt = .checkingCard
        // Only what the reader reports: `refreshIdentities` would also try a remembered PIN,
        // and the resolution below would then send a wrong one to the card a second time.
        await readCard()
        // Cancelled while the drivers answered: the late result changes nothing.
        guard pendingCardAction == action else { return }
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
                guard pendingCardAction == action else { return }
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
        cardPrompt = nil
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
