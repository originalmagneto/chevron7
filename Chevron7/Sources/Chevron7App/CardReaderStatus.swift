// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Kit
import CryptoTokenKit

/// The one place the main window asks the signing provider which card sits in the
/// reader. `availableIdentities()` only probes the drivers (or returns certificates
/// already read), so polling it never reads a card or asks for a PIN. The sidebar
/// badge reads `identities` in every section; the signing store gets each result
/// through `onRefresh` instead of polling on its own. When no driver reads a card,
/// the reader slots' ATRs tell whether one sits there without its driver.
@MainActor
@Observable
final class CardReaderStatus {
    private(set) var identities: [SigningIdentityInfo] = []
    /// A card in the reader that no installed driver reads, nil otherwise.
    private(set) var missingDriver: MissingDriverAdvice?

    /// Receives every discovery, changed or not, so a store that cleared its own
    /// list (a reset, a failed batch) gets the card back on the next poll.
    @ObservationIgnored var onRefresh: (([SigningIdentityInfo]) -> Void)?
    /// True while something else talks to the card (signing, reading certificates,
    /// the browser signing panel's own watch), so the reader is left alone.
    @ObservationIgnored var isPaused: () -> Bool = { false }

    @ObservationIgnored private let discover: () async -> [SigningIdentityInfo]
    @ObservationIgnored private let readCardATRs: () async -> [[UInt8]]
    @ObservationIgnored private let isDriverInstalled: (CardDriver) -> Bool
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var isRefreshing = false

    init(interval: Duration = .seconds(3),
         discover: @escaping () async -> [SigningIdentityInfo],
         readCardATRs: @escaping () async -> [[UInt8]] = { [] },
         isDriverInstalled: @escaping (CardDriver) -> Bool = \.isInstalled) {
        self.interval = interval
        self.discover = discover
        self.readCardATRs = readCardATRs
        self.isDriverInstalled = isDriverInstalled
    }

    func refresh() async {
        guard !isRefreshing, !isPaused() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let discovered = await discover()
        guard !isPaused() else { return }
        if discovered != identities { identities = discovered }
        let advice = discovered.isEmpty
            ? MissingDriverAdvice.evaluate(cardATRs: await readCardATRs(), isInstalled: isDriverInstalled)
            : nil
        if advice != missingDriver { missingDriver = advice }
        onRefresh?(discovered)
    }

    /// Polls until the calling task is cancelled, but only while the app is active.
    func watch(isAppActive: () -> Bool = { NSApp.isActive }) async {
        while !Task.isCancelled {
            if isAppActive() { await refresh() }
            try? await Task.sleep(for: interval)
        }
    }
}

/// What the sidebar card badge shows. The reader decides whether a card is
/// connected; the section's store only picks which of its certificates to name.
struct SmartcardBadge: Equatable {
    let isConnected: Bool
    /// A card is in the reader but its driver is not installed.
    let needsDriver: Bool
    let label: String
    let detail: String
    /// Drivers the badge offers to download, empty unless `needsDriver`.
    let drivers: [CardDriver]

    init(section: RootView.SidebarSection,
         reader: [SigningIdentityInfo],
         signingSelectedID: String?,
         zakoSelectedID: String?,
         isDemo: Bool,
         missingDriver: MissingDriverAdvice? = nil) {
        let selectedID = section == .zako ? zakoSelectedID : signingSelectedID
        let identity = reader.first(where: { $0.id == selectedID })
            ?? reader.first(where: \.isMandateCertificate)
            ?? reader.first
        isConnected = identity != nil
        let advice = identity == nil && !isDemo ? missingDriver : nil
        needsDriver = advice != nil
        drivers = advice?.drivers ?? []
        if let identity {
            label = identity.label
            detail = [identity.cardKindLabel, "čítačka je pripravená"]
                .compactMap { $0 }.joined(separator: " · ")
        } else if let advice {
            label = advice.label
            detail = advice.detail
        } else {
            label = isDemo ? "DEMO režim" : "Karta nepripojená"
            detail = "Vložte eID alebo SAK kartu"
        }
    }
}

/// Reads the ATR of every card in the readers through CryptoTokenKit, which needs no
/// vendor driver (the reader's CCID driver is part of macOS). Only slot state and ATR:
/// no card session is opened, so it never competes with a driver talking to the card.
/// The slot manager exists only with the `com.apple.security.smartcard` entitlement
/// (`Config/Chevron7App.entitlements`); without it the reader reports no cards.
enum SmartcardSlotReader {
    static func cardATRs() async -> [[UInt8]] {
        guard let manager = TKSmartCardSlotManager.default else { return [] }
        var atrs: [[UInt8]] = []
        for name in manager.slotNames {
            guard let slot = await manager.getSlot(withName: name),
                  slot.state == .validCard,
                  let atr = slot.atr else { continue }
            atrs.append(Array(atr.bytes))
        }
        return atrs
    }
}
