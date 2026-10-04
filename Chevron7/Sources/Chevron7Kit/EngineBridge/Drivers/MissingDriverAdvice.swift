// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// A vendor PKCS#11 driver the signing engine loads on macOS. Chevron7 cannot ship
/// these (proprietary installers that need an administrator), so a card whose
/// driver is missing is named from its ATR and the person is sent to the vendor.
public struct CardDriver: Sendable, Hashable {
    public let name: String
    /// The library `DefaultDriverDetector.getMacDrivers()` loads; its presence on disk
    /// is all the engine checks before it offers the driver.
    public let libraryPath: String
    public let downloadURL: URL

    public static let eIDKlient = CardDriver(
        name: "eID klient",
        libraryPath: "/Applications/eID_klient.app/Contents/Frameworks/libPkcs11.dylib",
        downloadURL: URL(string: "https://www.slovensko.sk/sk/na-stiahnutie")!)

    public static let icaSecureStore = CardDriver(
        name: "I.CA SecureStore",
        libraryPath: "/usr/local/lib/pkcs11/libICASecureStorePkcs11.dylib",
        downloadURL: URL(string: "https://www.ica.cz/sk/secure-store")!)

    public static let all: [CardDriver] = [.eIDKlient, .icaSecureStore]

    /// ATRs of Slovak eIDs measured on real cards. Exact matches only: an eID
    /// generation not listed here falls back to the advice naming every driver.
    static let slovakEIDATRs: Set<[UInt8]> = [
        // IDEMIA Cosmo, the owner's eID, read 2026-10-04.
        [0x3B, 0xDF, 0x18, 0xFF, 0x81, 0xB1, 0xFE, 0x45, 0x1F, 0x87, 0x00, 0x31, 0xB9, 0x64,
         0x09, 0x37, 0x72, 0x13, 0x73, 0x84, 0x01, 0xE0, 0x00, 0x00, 0x00, 0x8E]
    ]

    /// I.CA's STARCOS cards carry "ICA" in their historical bytes ("XICA V2.0" on the
    /// SAK card), so every applet version matches without a table of exact ATRs.
    private static let icaMarker: [UInt8] = Array("ICA".utf8)

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: libraryPath)
    }

    /// The driver that reads the card with this ATR, nil when the card is unknown.
    public static func forCard(atr: [UInt8]) -> CardDriver? {
        if slovakEIDATRs.contains(atr) { return .eIDKlient }
        if atr.count >= icaMarker.count,
           (0...(atr.count - icaMarker.count)).contains(where: { atr[$0..<$0 + icaMarker.count].elementsEqual(icaMarker) }) {
            return .icaSecureStore
        }
        return nil
    }
}

/// What the reader badge says when a card sits in the reader and no installed
/// driver can read it.
public struct MissingDriverAdvice: Sendable, Equatable {
    public let label: String
    public let detail: String
    /// The drivers to offer for download, one for a recognised card.
    public let drivers: [CardDriver]

    public init(label: String, detail: String, drivers: [CardDriver]) {
        self.label = label
        self.detail = detail
        self.drivers = drivers
    }

    /// A known card whose driver is missing wins. An unknown card counts only when no
    /// driver at all is installed, since an installed one may well read it. Advice is
    /// never given for a card whose driver is installed: the engine has not read a
    /// freshly inserted card yet, and that must not flash "missing driver".
    public static func evaluate(cardATRs: [[UInt8]], isInstalled: (CardDriver) -> Bool) -> MissingDriverAdvice? {
        guard !cardATRs.isEmpty else { return nil }
        let known = cardATRs.compactMap(CardDriver.forCard(atr:))
        if let driver = known.first(where: { !isInstalled($0) }) {
            return MissingDriverAdvice(label: label, detail: cardDetail(for: driver), drivers: [driver])
        }
        let hasUnknownCard = known.count < cardATRs.count
        if hasUnknownCard, !CardDriver.all.contains(where: isInstalled) {
            return MissingDriverAdvice(label: label, detail: "Karta je v čítačke", drivers: CardDriver.all)
        }
        return nil
    }

    private static let label = "Chýba ovládač karty"

    private static func cardDetail(for driver: CardDriver) -> String {
        driver == .eIDKlient ? "Občiansky preukaz je v čítačke" : "Karta I.CA je v čítačke"
    }
}
