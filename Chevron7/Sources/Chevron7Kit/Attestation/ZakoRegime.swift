// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// The order of a paper to electronic guaranteed conversion. Until 31. 12. 2026 the clause and
/// the document are signed first and the record follows (zákon č. 305/2013 Z. z. § 36 ods. 3 in
/// the version until then). From 1. 1. 2027 the record is created and sent to the central
/// register first and the clause is built from what the register returns (§ 36 ods. 3 as amended
/// by zákon č. 325/2022 Z. z., Čl. I body 73 až 82, postponed by 239/2025 Z. z.). Findings:
/// `docs/ZAKO-2027-FINDINGS-2026-10-16.md`.
public enum ZakoRegime: String, Codable, Sendable {
    case clauseFirst
    case recordFirst

    /// 1. 1. 2027 00:00 in Europe/Bratislava (CET, UTC+01:00). The 2027 change has been
    /// postponed three times, so this one constant moves it; the two P→E form packs split here.
    public static let recordFirstFrom = Date(timeIntervalSince1970: 1_798_758_000)

    public struct Resolution: Equatable, Sendable {
        public let regime: ZakoRegime
        /// The instant the form pack is chosen for: the conversion time, or the switch itself
        /// when the test preview forces the 2027 forms before the date.
        public let formPackDate: Date
        /// Why this conversion may not run, or nil.
        public let refusal: String?
    }

    /// The regime of a conversion performed at `conversionTime` (EZZK's server time, never the
    /// Mac's clock) in `mode`. `preview` (`AppSettings.zakoRecordFirstPreview`) makes a Demo or
    /// Testovacia evidencia conversion record-first with the 2027 forms before the date;
    /// production ignores it. `ZakoRecordFirstPolicy` may refuse a record-first conversion
    /// outside Demo.
    public static func resolve(conversionTime: Date, mode: AppSettings.EZZKMode, preview: Bool,
                               refusesOutsideDemo: Bool = ZakoRecordFirstPolicy.refusesOutsideDemo) -> Resolution {
        let byDate = conversionTime >= recordFirstFrom
        let previewed = !byDate && preview && mode != .production
        let regime: ZakoRegime = byDate || previewed ? .recordFirst : .clauseFirst
        let refusal = regime == .recordFirst && mode != .demo && refusesOutsideDemo
            ? ZakoRecordFirstPolicy.refusalMessage : nil
        return Resolution(regime: regime,
                          formPackDate: previewed ? recordFirstFrom : conversionTime,
                          refusal: refusal)
    }
}

/// The owner's switch for the 2027 flow (decision of 2026-10-16). EZZK 2.0, the register the
/// 2027 decree is written for, has no published API; Chevron7 performs the record-first order on
/// today's EZZK SOAP. If EZZK stops accepting that, setting `refusesOutsideDemo` stops every
/// record-first conversion outside Demo before an evidence number is allocated.
public enum ZakoRecordFirstPolicy {
    public static let refusesOutsideDemo = false

    public static let refusalMessage = "Od 1. 1. 2027 sa zaručená konverzia vykonáva novým postupom (najprv záznam do centrálnej evidencie, potom doložka). Táto verzia Chevron7 ho mimo skúšobného režimu zatiaľ nevykonáva, kým ho EZZK nepodporuje. Aktualizujte Chevron7, keď bude nová verzia dostupná."
}
