// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// One condition of the authorize step's checklist. Pure value: the view only draws it.
struct ZakoChecklistItem: Equatable, Identifiable {
    /// Whether the condition holds.
    let met: Bool
    let title: String
    /// The SF Symbol naming the condition (not its state; `ChecklistMarker` draws that).
    let symbol: String
    /// What the advocate does about an unmet item, or where it comes from. Nil when met.
    let hint: String?
    /// An unmet item that stops the authorization before the card is asked (the EZZK login).
    let blocksBeforeCard: Bool

    init(met: Bool, title: String, symbol: String, hint: String? = nil, blocksBeforeCard: Bool = false) {
        self.met = met
        self.title = title
        self.symbol = symbol
        self.hint = met ? nil : hint
        self.blocksBeforeCard = blocksBeforeCard
    }

    var id: String { title }
}

/// The line under the authorize button.
struct ZakoAuthorizeNote: Equatable {
    let text: String
    let symbol: String
    let isRefusal: Bool
}

/// The card line above the authorize checklist. Pure value: the view only draws it.
enum ZakoTokenStatus: Equatable {
    case demo
    case noCard
    case typePending
    /// A card is in, but it holds no mandate certificate: a warning, never a green line.
    case noMandate
    case loaded

    static func make(isDemo: Bool, hasIdentities: Bool, certificateTypePending: Bool,
                     gate: ZakoMandateGate) -> ZakoTokenStatus {
        if isDemo { return .demo }
        if gate == .noMandate { return .noMandate }
        if !hasIdentities { return .noCard }
        if certificateTypePending { return .typePending }
        return .loaded
    }

    var text: String {
        switch self {
        case .demo: "Demo režim: kvalifikovaná karta nie je pripojená."
        case .noCard: "Karta nie je detegovaná: vložte eID alebo advokátsky preukaz."
        case .typePending: "Karta je pripojená. Typ certifikátu sa overí po zadaní PIN."
        case .noMandate: "Na vloženej karte nie je mandátny certifikát SAK."
        case .loaded: "Karta je pripojená, certifikáty načítané."
        }
    }

    var symbol: String {
        switch self {
        case .demo, .noCard: "creditcard.and.123"
        case .typePending, .loaded: "creditcard.fill"
        case .noMandate: "creditcard.trianglebadge.exclamationmark"
        }
    }

    var isWarning: Bool { self == .noMandate }
    var isReady: Bool { self == .loaded }
}

/// The checklist as the authorize step shows it: met items fold into one row
/// ("N z M pripravené"), unmet items stay visible one by one with their hint.
struct ZakoChecklistSummary: Equatable {
    let items: [ZakoChecklistItem]

    var met: [ZakoChecklistItem] { items.filter(\.met) }
    var unmet: [ZakoChecklistItem] { items.filter { !$0.met } }
    var allMet: Bool { unmet.isEmpty }

    /// The folded row's title.
    var foldedTitle: String { "\(met.count) z \(items.count) pripravené" }
}

extension ZakoSessionStore {
    /// Shown under the authorize button and as the checklist hint when a card is in the reader
    /// but holds no mandate certificate: the button is off, so the card check never starts.
    nonisolated static let authorizeNoMandateReason =
        "Na vloženej karte nie je mandátny certifikát SAK. Vložte kartu advokáta s mandátnym certifikátom."

    /// Shown under the authorize button when the next authorization uses the PIN typed earlier.
    nonisolated static let rememberedPINMessage =
        "Použije sa PIN zadaný skôr. Aplikácia ho drží do zatvorenia alebo vybratia karty."

    /// Why the authorize button is off because of the card itself, or nil. Only a card that is
    /// in the reader and known to lack the mandate refuses; an empty reader keeps the button
    /// live, since the card flow asks for the card itself.
    nonisolated static func authorizeCardRefusal(for gate: ZakoMandateGate) -> String? {
        gate == .noMandate ? authorizeNoMandateReason : nil
    }

    var authorizeCardRefusal: String? {
        Self.authorizeCardRefusal(for: mandateGate)
    }

    /// The line under the authorize button: why a card is refused, else the remembered PIN
    /// note; nothing while the card check runs, since that check is what decides.
    nonisolated static func authorizeButtonNote(cardRefusal: String?, rememberedPINNote: String?,
                                                checkingCard: Bool) -> ZakoAuthorizeNote? {
        guard !checkingCard else { return nil }
        if let cardRefusal {
            return ZakoAuthorizeNote(text: cardRefusal, symbol: "creditcard.trianglebadge.exclamationmark",
                                     isRefusal: true)
        }
        if let rememberedPINNote {
            return ZakoAuthorizeNote(text: rememberedPINNote, symbol: "key.horizontal", isRefusal: false)
        }
        return nil
    }

    var authorizeButtonNote: ZakoAuthorizeNote? {
        Self.authorizeButtonNote(cardRefusal: authorizeCardRefusal, rememberedPINNote: rememberedPINNoteText,
                                 checkingCard: cardPrompt == .checkingCard)
    }

    /// The card line above the checklist.
    var tokenStatus: ZakoTokenStatus {
        ZakoTokenStatus.make(isDemo: signingProvider is DemoSigningProvider, hasIdentities: !identities.isEmpty,
                             certificateTypePending: isCertificateTypePending, gate: mandateGate)
    }

    /// A card flow is running ("Kontrolujem kartu…", the PIN or the card prompt): the step's
    /// other controls stay off as they do while authorizing, since the flow may go on to sign.
    var isCardFlowActive: Bool { pendingCardAction != nil }

    /// The remembered PIN note, when the next authorization will use `signingPIN`.
    static func rememberedPINNote(isDemo: Bool, pinHeld: Bool, cardNeedsTypedPIN: Bool,
                                  hasCard: Bool, isBusy: Bool, cardRefused: Bool) -> String? {
        guard !isDemo, pinHeld, cardNeedsTypedPIN, hasCard, !isBusy, !cardRefused else { return nil }
        return rememberedPINMessage
    }

    var rememberedPINNoteText: String? {
        Self.rememberedPINNote(isDemo: signingProviderIsDemo,
                               pinHeld: !signingPIN.isEmpty,
                               cardNeedsTypedPIN: cardNeedsTypedPIN,
                               hasCard: !identities.isEmpty,
                               isBusy: isAuthorizing || isCardFlowActive,
                               cardRefused: authorizeCardRefusal != nil)
    }

    /// The checklist of the authorize step for the current direction, the EZZK login last.
    var authorizeChecklist: ZakoChecklistSummary {
        let items = direction == .electronicToElectronic ? e2eChecklistItems : p2eChecklistItems
        return ZakoChecklistSummary(items: items + ezzkChecklistItems)
    }

    /// The hint of the card items: a card without the mandate is named as such, an empty
    /// reader asks for the card, and a card still to be unlocked is read at authorization.
    nonisolated static let insertMandateCardHint = "Vložte kartu s mandátnym certifikátom SAK."
    nonisolated static let readAtAuthorizationHint = "Načíta sa z karty pri autorizácii."

    nonisolated static func cardItemHint(for gate: ZakoMandateGate) -> String {
        switch gate {
        case .noMandate: authorizeNoMandateReason
        case .insertCard: insertMandateCardHint
        case .notRequired, .ready, .needsUnlock: readAtAuthorizationHint
        }
    }

    private var cardItemHint: String {
        Self.cardItemHint(for: mandateGate)
    }

    private var identityChecklistItem: ZakoChecklistItem {
        ZakoChecklistItem(met: selectedIdentityID != nil && selectedIdentity != nil,
                          title: "Identita pre podpis vybraná", symbol: "person.badge.key",
                          hint: cardItemHint)
    }

    private var mandateChecklistItem: ZakoChecklistItem {
        ZakoChecklistItem(met: mandateRequirementSatisfied,
                          title: "Mandátny certifikát SAK pripravený", symbol: "checkmark.seal",
                          hint: cardItemHint)
    }

    private var evidenceNumberChecklistItem: ZakoChecklistItem {
        // Authorization allocates the number itself, so this item never blocks.
        ZakoChecklistItem(met: true,
                          title: attestation.evidenceNumber.map { "Evidenčné číslo z EZZK: \($0)" }
                              ?? "Evidenčné číslo pridelí EZZK pri autorizácii",
                          symbol: "number.square.fill")
    }

    private var performingPersonChecklistItem: ZakoChecklistItem {
        ZakoChecklistItem(met: !attestation.performingPerson.fullName.trimmingCharacters(in: .whitespaces).isEmpty,
                          title: "Osoba vykonávajúca konverziu vyplnená", symbol: "person.crop.circle",
                          hint: "Vyplňte ju v doložke.")
    }

    private var e2eChecklistItems: [ZakoChecklistItem] {
        [
            ZakoChecklistItem(met: canLeaveVerification,
                              title: e2eRecordFirstRefusal == nil ? "Podpisy a časové pečiatky klienta overené"
                                  : "Kvalifikácia podpisu neurčená: postup od 1. 1. 2027 ju nepripúšťa",
                              symbol: "signature.badge.checkmark",
                              hint: "Pozrite krok Overenie."),
            ZakoChecklistItem(met: !e2eNeedsQualifiedReport || qualifiedReport != nil,
                              title: e2eNeedsQualifiedReport ? "Výsledok kvalifikovanej služby validácie pripojený"
                                  : "Overenie aplikáciou Chevron7 (\(settingsStore.ezzkAccountController.mode.label))",
                              symbol: "checkmark.seal",
                              hint: "Pripojte ho v kroku Overenie."),
            ZakoChecklistItem(met: e2eDocumentTypesFilled
                                && !attestation.originalDocumentTypeLabel.trimmingCharacters(in: .whitespaces).isEmpty,
                              title: e2eFileDocumentTypes.isEmpty ? "Druh dokumentu vyplnený"
                                  : "Druh dokumentu vyplnený pri každom súbore",
                              symbol: "text.badge.checkmark",
                              hint: "Vyplňte ho v kroku Overenie."),
            ZakoChecklistItem(met: !attestation.newDocumentName.trimmingCharacters(in: .whitespaces).isEmpty,
                              title: "Názov nového dokumentu vyplnený", symbol: "doc.badge.gearshape",
                              hint: "Vyplňte ho v doložke."),
            evidenceNumberChecklistItem,
            performingPersonChecklistItem,
            identityChecklistItem,
            mandateChecklistItem,
            ZakoChecklistItem(met: true, title: "QTS z kvalifikovaných autorít časových pečiatok",
                              symbol: "clock.badge.checkmark")
        ]
    }

    private var p2eChecklistItems: [ZakoChecklistItem] {
        // Outside Demo the switch is hidden and the qualified built-in authorities always stamp.
        let qtsReady = showsQualifiedTimestampToggle
            ? (!usesQualifiedTimestamp
               || !settings.selectedTSAURL.trimmingCharacters(in: .whitespaces).isEmpty)
            : !TimestampAuthority.qualifiedURLs.isEmpty
        let qtsLabel = !showsQualifiedTimestampToggle
            ? "QTS z kvalifikovaných autorít časových pečiatok"
            : (usesQualifiedTimestamp ? "QTS pripravená s TSA službou" : "QTS nepoužitá")
        let pendingElements = pendingSecurityElementCount
        let unreviewed = unreviewedNonEmptyPages.count
        return [
            inputSignatureChecklistItem,
            ZakoChecklistItem(met: attestation.originConfirmed,
                              title: "Originál alebo úradne osvedčená kópia potvrdená", symbol: "checkmark.seal",
                              hint: "Potvrďte to v doložke."),
            ZakoChecklistItem(met: !attestation.originalDocumentName.trimmingCharacters(in: .whitespaces).isEmpty,
                              title: "Názov pôvodného dokumentu vyplnený", symbol: "text.badge.checkmark",
                              hint: "Vyplňte ho v doložke."),
            ZakoChecklistItem(met: !attestation.newDocumentName.trimmingCharacters(in: .whitespaces).isEmpty,
                              title: "Názov elektronického dokumentu vyplnený", symbol: "doc.badge.gearshape",
                              hint: "Vyplňte ho v doložke."),
            ZakoChecklistItem(met: effectiveSheetCount > 0,
                              title: "Počet listov určený (\(effectiveSheetCount))", symbol: "rectangle.stack",
                              hint: "Určte ho v doložke."),
            ZakoChecklistItem(met: confirmedSecurityElements.count > 0 && pendingElements == 0,
                              title: "Bezpečnostné prvky potvrdené (\(confirmedSecurityElements.count))",
                              symbol: "shield.checkerboard",
                              hint: pendingElements > 0
                                  ? "Rozhodnite o návrhoch v analýze (\(pendingElements))."
                                  : "Potvrďte bezpečnostné prvky v analýze."),
            ZakoChecklistItem(met: unreviewedNonEmptyPages.isEmpty && analysis.nonEmptyPages > 0,
                              title: "Všetky neprázdne strany skontrolované", symbol: "doc.text.magnifyingglass",
                              hint: unreviewed > 0 ? "Skontrolujte zvyšné strany v analýze (\(unreviewed))."
                                  : "Skontrolujte strany v analýze."),
            evidenceNumberChecklistItem,
            performingPersonChecklistItem,
            ZakoChecklistItem(met: !attestation.performingPerson.registrationNumber.trimmingCharacters(in: .whitespaces).isEmpty,
                              title: "Evidenčné číslo advokáta vyplnené", symbol: "building.columns",
                              hint: "Vyplňte ho v doložke."),
            identityChecklistItem,
            mandateChecklistItem,
            ZakoChecklistItem(met: qtsReady, title: qtsLabel, symbol: "clock.badge.checkmark",
                              hint: "Vyberte službu časových pečiatok v Nastaveniach.")
        ]
    }

    /// Outside Demo the number comes from EZZK, so the saved login is a condition too. It stops
    /// the authorization before the card, so an unmet one looks like the warning above the list.
    private var ezzkChecklistItems: [ZakoChecklistItem] {
        guard settingsStore.ezzkAccountController.mode != .demo else { return [] }
        return [ZakoChecklistItem(met: ezzkSignInRefusal == nil, title: "Prihlásenie do EZZK",
                                  symbol: "person.badge.shield.checkmark",
                                  hint: "Prihláste sa v Nastaveniach, časť EZZK.", blocksBeforeCard: true)]
    }

    private var inputSignatureChecklistItem: ZakoChecklistItem {
        switch inputSignatureInspection.state {
        case .valid:
            ZakoChecklistItem(met: true, title: "Vstupné podpisy overené", symbol: "signature.badge.checkmark")
        case .invalid:
            ZakoChecklistItem(met: false, title: "Vstup obsahuje neplatný elektronický podpis", symbol: "xmark.seal",
                              hint: "Podrobnosti sú v správe o podpisoch nižšie.")
        case .unknown:
            ZakoChecklistItem(met: false, title: "Vstupné podpisy sa nepodarilo jednoznačne overiť",
                              symbol: "questionmark.diamond", hint: "Podrobnosti sú v správe o podpisoch nižšie.")
        case .unavailable:
            ZakoChecklistItem(met: false, title: "Overenie vstupných podpisov nie je dostupné",
                              symbol: "exclamationmark.triangle", hint: "Podrobnosti sú v správe o podpisoch nižšie.")
        }
    }
}
