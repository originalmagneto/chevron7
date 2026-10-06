// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation
import Observation

/// The one place that moves conversion-register rows through EZZK: ZaKo after
/// authorization, the Register's "Odoslať" and "Overiť v EZZK", and a check every five
/// minutes while the app runs. Every path applies `EZZKSubmissionCoordinator`'s rules and
/// goes through here, so one row is never sent or looked up by two paths at once (EZZK
/// stores a second copy of a record sent twice, result 106).
///
/// A row is only handled by the EZZK that allocated its number. It is sent only while that
/// mode is the current one (another mode's row is refused by "Odoslať" and skipped by the
/// periodic send), but looked up in its own mode's EZZK whatever the current mode, since a
/// lookup only reads. A row without a stored mode was
/// written before part B2 and has no signed record: no path sends or looks it up (R15).
@MainActor
@Observable
final class EZZKStatusChecker {
    /// The result of a manual action on one row.
    enum RowResult {
        /// The row as it is now, changed or not.
        case row(EvidenceRecord)
        /// Nothing was done; the Slovak reason says why.
        case refused(String)

        var record: EvidenceRecord? {
            if case .row(let record) = self { return record }
            return nil
        }

        var refusal: String? {
            if case .refused(let reason) = self { return reason }
            return nil
        }
    }

    /// What "Odoslať" in the Register did to the pending rows.
    struct PendingSummary: Equatable {
        /// Accepted for processing or processed.
        var accepted = 0
        /// Still unknown: waiting for a lookup, never resent.
        var unknown = 0
        /// Not sent (nothing reached EZZK); they wait for the next attempt.
        var waiting = 0
        var rejected = 0
        var unsigned = 0
        /// Rows of another EZZK mode or rows another action is handling.
        var skipped = 0
        /// Rows written before part B2 (no EZZK mode): never sent.
        var legacy = 0
        /// Production rows: not sent while the production policy refuses submission (B3).
        var production = 0
        /// Set when nothing could be done at all (the register is unreadable).
        var refusal: String?

        /// True only when every pending row was accepted.
        var isSuccess: Bool {
            refusal == nil && accepted > 0 && unknown + waiting + rejected + unsigned + skipped + legacy + production == 0
        }

        /// One Slovak line for the Register header.
        var feedback: String {
            if let refusal { return refusal }
            let parts = [
                (accepted, "Prijaté na spracovanie v EZZK"),
                (unknown, "Výsledok neznámy, overí sa v EZZK"),
                (waiting, "Čaká na odoslanie"),
                (rejected, "Odmietnuté v EZZK"),
                (unsigned, "Záznam nepodpísaný"),
                (skipped, "Preskočené (iný režim EZZK alebo prebieha iná akcia)")
            ].filter { $0.0 > 0 }.map { "\($0.1): \($0.0)." }
            var notes: [String] = []
            if legacy > 0 {
                notes.append("Záznamy spred odosielania do EZZK: \(legacy). \(EZZKStatusChecker.preB2RowMessage)")
            }
            if production > 0 {
                notes.append("Záznamy v ostrej evidencii: \(production). \(EZZKStatusChecker.productionRefusal)")
            }
            let all = parts + notes
            return all.isEmpty ? "Žiadny záznam nečaká na odoslanie." : all.joined(separator: " ")
        }
    }

    static let checkInterval: TimeInterval = 5 * 60
    /// Automatic sends of one row per Bratislava day. After that the row waits for
    /// "Odoslať" in the Register, so a request EZZK keeps refusing before its operation
    /// runs is not sent every five minutes.
    static let automaticAttemptsPerDay = 3

    nonisolated static let recordFromOtherModeMessage =
        "Záznam bol vytvorený v inom prostredí EZZK, preto sa v tomto prostredí neodošle. Prepnite prostredie EZZK späť (Nastavenia, EZZK, Rozšírené nastavenia) a odošlite ho znova."
    nonisolated static let rowBusyMessage =
        "Záznam sa práve odosiela alebo overuje v EZZK. Skúste to o chvíľu."
    /// Ruling R15: a row written before part B2 has no EZZK mode and no signed record.
    nonisolated static let preB2RowMessage =
        "Záznam vznikol pred odosielaním do EZZK v Chevron7, preto ho aplikácia neodosiela."
    /// Why production rows are left alone while the production policy refuses consequential
    /// calls (the adapter refuses them too).
    nonisolated static let productionRefusal = EZZKError.submissionUnavailable.errorDescription ?? ""
    nonisolated static let missingRowMessage = "Záznam sa v Registri konverzií nenašiel."
    /// Shown when "Vymazať z evidencie" is refused because ZaKo still signs the row's record
    /// or the checker still sends it.
    nonisolated static let busyDeleteMessage =
        "Riadok sa práve spracúva (podpis alebo odoslanie záznamu). Vymažte ho, keď sa spracovanie skončí."

    /// Increases whenever a row is stored, so views that read rows from the register
    /// (which is not observable itself) redraw.
    private(set) var changeCount = 0

    @ObservationIgnored private let evidenceStore: LocalEvidenceStore
    @ObservationIgnored private let numberPool: EvidenceNumberPool
    @ObservationIgnored private let currentMode: () -> AppSettings.EZZKMode
    /// Builds the coordinator for one EZZK mode: its submitter and lookup target that
    /// mode's environment, whatever the controller's mode is by the time they run.
    @ObservationIgnored private let makeCoordinator: (AppSettings.EZZKMode) -> EZZKSubmissionCoordinator
    @ObservationIgnored private let now: @Sendable () -> Date
    /// The production policy of the account controller: while it is false, production rows
    /// are neither sent nor looked up by any path, and carry `productionRefusal`.
    @ObservationIgnored private let sendsInProduction: Bool
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var automaticAttempts: [UUID: [Date]] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(evidenceStore: LocalEvidenceStore,
         numberPool: EvidenceNumberPool,
         currentMode: @escaping () -> AppSettings.EZZKMode,
         makeCoordinator: @escaping (AppSettings.EZZKMode) -> EZZKSubmissionCoordinator,
         now: @escaping @Sendable () -> Date = { Date() },
         sendsInProduction: Bool = false) {
        self.sendsInProduction = sendsInProduction
        self.evidenceStore = evidenceStore
        self.numberPool = numberPool
        self.currentMode = currentMode
        self.makeCoordinator = makeCoordinator
        self.now = now
    }

    /// The app's checker: submits with the account controller's service for the current
    /// mode. Demo sends to the local `MockEZZKService` and has nothing to look up, so a
    /// lookup there answers "processed" (ruling R4); outside Demo the lookup is the
    /// controller's public `GetConversionRecord`. Production rows follow the controller's
    /// production policy.
    convenience init(evidenceStore: LocalEvidenceStore,
                     numberPool: EvidenceNumberPool,
                     controller: EZZKAccountController) {
        self.init(
            evidenceStore: evidenceStore,
            numberPool: numberPool,
            currentMode: { controller.mode },
            makeCoordinator: { mode in
                let lookup: EZZKRecordLookupFunction
                if mode == .demo {
                    lookup = EZZKRecordLookupFunction { _, _ in EZZKRecordLookup(isProcessed: true, info: nil) }
                } else {
                    lookup = EZZKRecordLookupFunction { number, time in
                        try await controller.lookUp(evidenceNumber: number, in: mode, executionTime: time)
                    }
                }
                return EZZKSubmissionCoordinator(submitter: controller.service(for: mode), lookup: lookup)
            },
            sendsInProduction: controller.productionPolicy.allowsConsequentialCalls)
    }

    /// The reason the checker leaves rows of this mode alone, or nil when it may act on them.
    func refusalReason(forMode mode: AppSettings.EZZKMode) -> String? {
        mode == .production && !sendsInProduction ? Self.productionRefusal : nil
    }

    // MARK: - Periodic check

    /// Ruling R13: the check runs in a regular Chevron7 only. Started by Safari for a
    /// portal signature (`--web-signing`, an accessory app without a window), the app does
    /// not talk to EZZK in the background until the advocate opens it and it turns regular.
    nonisolated static func shouldRun(launchMode: AppLaunchMode, isRegularApp: Bool) -> Bool {
        launchMode == .normal || isRegularApp
    }

    /// Starts the check when `shouldRun` allows it: at launch from the app model, and
    /// again when an accessory app becomes regular (reopen, Settings).
    func startIfAllowed(launchMode: AppLaunchMode, isRegularApp: Bool) {
        guard Self.shouldRun(launchMode: launchMode, isRegularApp: isRegularApp) else { return }
        start()
    }

    var isRunning: Bool { loop != nil }

    /// Starts the check every five minutes, after dropping pooled evidence numbers that
    /// lapsed at an earlier midnight. Does nothing while the check already runs.
    func start() {
        guard loop == nil else { return }
        numberPool.prune(before: now())
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOnce()
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One pass over the register: late rows are marked, pending rows of this mode are
    /// sent (at most `automaticAttemptsPerDay` a day each), and unknown or accepted rows
    /// of every mode are looked up when their next check is due, each in the EZZK of its
    /// own mode: a lookup only reads, so a row accepted in Production is still seen as
    /// processed while the advocate works in Demo. Rows without an evidence number,
    /// without a mode, of a mode the production policy refuses, or already being handled
    /// are left alone. A row resolved in this pass is sent in the next one at the
    /// earliest, and only in its own mode. Sending targets the pass's mode and stops when
    /// the controller's mode changes.
    func runOnce() async {
        guard evidenceStore.loadError == nil else { return }
        let mode = currentMode()
        var coordinators: [AppSettings.EZZKMode: EZZKSubmissionCoordinator] = [:]
        func coordinator(for rowMode: AppSettings.EZZKMode) -> EZZKSubmissionCoordinator {
            if let existing = coordinators[rowMode] { return existing }
            let made = makeCoordinator(rowMode)
            coordinators[rowMode] = made
            return made
        }
        for snapshot in evidenceStore.records {
            guard Self.hasEvidenceNumber(snapshot), let rowMode = snapshot.ezzkMode,
                  refusalReason(forMode: rowMode) == nil,
                  !inFlight.contains(snapshot.id) else { continue }
            switch snapshot.status {
            case .signed, .queuedForSubmission, .submissionFailed, .late:
                // The advocate may switch the EZZK mode while a lookup or a send of this
                // pass waits; a send then belongs to the old mode and is skipped.
                guard rowMode == mode, currentMode() == mode else { continue }
                let sender = coordinator(for: mode)
                guard takeAutomaticAttempt(for: snapshot.id) else {
                    // Still marked late when its day has passed, even without a send.
                    await perform(snapshot.id) { record in sender.markLateIfNeeded(record) }
                    continue
                }
                await perform(snapshot.id) { record in
                    await Self.send(record, with: sender, store: self.evidenceStore)
                }
            case .outcomeUnknown, .acceptedForProcessing:
                let checker = coordinator(for: rowMode)
                guard let due = checker.nextStatusCheck(for: snapshot), due <= now() else { continue }
                await perform(snapshot.id) { record in
                    record.status == .outcomeUnknown
                        ? await checker.resolveUnknown(record)
                        : await checker.refreshStatus(record)
                }
            default:
                continue
            }
        }
    }

    // MARK: - Manual actions

    /// Sends one row now ("Odoslať", and ZaKo right after authorization): a row whose day
    /// has passed is marked late first, an unknown outcome is looked up first and only
    /// sent when EZZK does not know the number.
    func submit(id: UUID) async -> RowResult {
        if let refusal = refusal(for: id) { return .refused(refusal) }
        let coordinator = makeCoordinator(currentMode())
        let result = await perform(id) { record in
            await Self.send(record, with: coordinator, store: self.evidenceStore)
        }
        return result.map(RowResult.row) ?? .refused(Self.missingRowMessage)
    }

    /// Sends a record EZZK refused at submission again ("Odoslať znova" in the Register,
    /// after the advocate confirmed it). Only `EZZKSubmissionCoordinator.canResend` rows are
    /// sent; any other row comes back unchanged. The periodic check never calls this.
    func resend(id: UUID) async -> RowResult {
        if let refusal = refusal(for: id) { return .refused(refusal) }
        let coordinator = makeCoordinator(currentMode())
        let result = await perform(id) { record in
            await coordinator.resend(record, container: self.evidenceStore.recordContainerData(for: record))
        }
        return result.map(RowResult.row) ?? .refused(Self.missingRowMessage)
    }

    /// Looks one row up now ("Overiť v EZZK"): an unknown outcome is resolved (no sooner
    /// than five minutes after the attempt, see `nextStatusCheck(for:)`), an accepted row
    /// is refreshed. Nothing is sent, so a row of another mode is looked up too, in the
    /// EZZK of its own mode.
    func verify(id: UUID) async -> RowResult {
        if let refusal = refusal(for: id, allowingOtherMode: true) { return .refused(refusal) }
        guard let mode = evidenceStore.record(id: id)?.ezzkMode else { return .refused(Self.preB2RowMessage) }
        let coordinator = makeCoordinator(mode)
        let result = await perform(id) { record in
            switch record.status {
            case .outcomeUnknown: return await coordinator.resolveUnknown(record)
            case .acceptedForProcessing: return await coordinator.refreshStatus(record)
            default: return record
            }
        }
        return result.map(RowResult.row) ?? .refused(Self.missingRowMessage)
    }

    /// "Odoslať" in the Register: every pending row of the current mode goes through
    /// `submit(id:)`, unknown outcomes included (they are only looked up).
    func submitPending() async -> PendingSummary {
        var summary = PendingSummary()
        if let loadError = evidenceStore.loadError {
            summary.refusal = loadError
            return summary
        }
        let pending = evidenceStore.records.filter(\.status.isSubmissionPendingState)
        for row in pending {
            switch await submit(id: row.id) {
            case .refused(let reason) where reason == Self.preB2RowMessage:
                summary.legacy += 1
            case .refused(let reason) where reason == Self.productionRefusal:
                summary.production += 1
            case .refused:
                summary.skipped += 1
            case .row(let record):
                switch record.status {
                case .acceptedForProcessing, .processed: summary.accepted += 1
                case .outcomeUnknown: summary.unknown += 1
                case .rejected: summary.rejected += 1
                case .recordUnsigned: summary.unsigned += 1
                default: summary.waiting += 1
                }
            }
        }
        return summary
    }

    /// When the row's next automatic lookup is due, or nil when none is planned.
    func nextStatusCheck(for record: EvidenceRecord) -> Date? {
        makeCoordinator(record.ezzkMode ?? currentMode()).nextStatusCheck(for: record)
    }

    func isBusy(_ id: UUID) -> Bool {
        inFlight.contains(id)
    }

    /// ZaKo holds its row from the moment it is registered (`.signed`, no record container)
    /// until its record is signed or has failed, so neither the periodic check nor a manual
    /// action marks it unsigned or sends it meanwhile. The hold lives in memory only: after
    /// a crash or force-quit during the record signature the row is a crash orphan, and the
    /// next pass treats it like any row without a signed record (`.recordUnsigned`, via
    /// `EZZKSubmissionCoordinator.submit`). A signature waiting for a PIN or BOK can take
    /// any time, which a fixed age window would not cover. Returns false when the row is
    /// already held or in flight; `release` must then not be called for it.
    @discardableResult
    func hold(_ id: UUID) -> Bool {
        inFlight.insert(id).inserted
    }

    func release(_ id: UUID) {
        inFlight.remove(id)
    }

    /// Deletes a register row ("Vymazať z evidencie") and drops its number from the pool,
    /// so a deleted row's number is never offered to a new conversion. A row ZaKo still
    /// signs or the checker still sends is refused: its later write would bring it back.
    @discardableResult
    func delete(id: UUID) -> Bool {
        guard !isBusy(id) else { return false }
        if let number = evidenceStore.record(id: id)?.evidenceNumber {
            numberPool.remove(number)
        }
        evidenceStore.delete(id: id)
        changeCount += 1
        return true
    }

    // MARK: - Internals

    /// Why a manual action on the row is refused, or nil. `allowingOtherMode` is for a
    /// lookup, which only reads and goes to the row's own EZZK whatever the current mode.
    private func refusal(for id: UUID, allowingOtherMode: Bool = false) -> String? {
        if let loadError = evidenceStore.loadError { return loadError }
        guard let record = evidenceStore.record(id: id) else { return Self.missingRowMessage }
        guard let mode = record.ezzkMode else { return Self.preB2RowMessage }
        if !allowingOtherMode, mode != currentMode() { return Self.recordFromOtherModeMessage }
        if let reason = refusalReason(forMode: mode) { return reason }
        if inFlight.contains(id) { return Self.rowBusyMessage }
        return nil
    }

    /// Runs `change` on the stored row while no other path may touch it, stores what it
    /// returns when something changed, and returns the row as it is afterwards. Nil when
    /// the row is gone or busy.
    @discardableResult
    private func perform(_ id: UUID,
                         _ change: (EvidenceRecord) async -> EvidenceRecord) async -> EvidenceRecord? {
        guard !inFlight.contains(id), let record = evidenceStore.record(id: id) else { return nil }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let updated = await change(record)
        guard updated.updatedAt != record.updatedAt || updated.status != record.status else { return record }
        if updated.status != record.status,
           updated.status == .acceptedForProcessing || updated.status == .processed,
           let number = updated.evidenceNumber {
            // EZZK consumed the number with the record, so it is never offered again, even
            // when the row was deleted meanwhile.
            numberPool.remove(number)
        }
        // A row the advocate deleted meanwhile is not brought back.
        guard evidenceStore.record(id: id) != nil else { return updated }
        evidenceStore.upsert(updated)
        changeCount += 1
        return updated
    }

    /// Marks a row late when its day has passed, looks an unknown outcome up first, then
    /// sends the row with its stored record container.
    private static func send(_ record: EvidenceRecord, with coordinator: EZZKSubmissionCoordinator,
                             store: LocalEvidenceStore) async -> EvidenceRecord {
        var updated = coordinator.markLateIfNeeded(record)
        if updated.status == .outcomeUnknown {
            updated = await coordinator.resolveUnknown(updated)
        }
        return await coordinator.submit(updated, container: store.recordContainerData(for: updated))
    }

    /// Counts an automatic send of the row today (Bratislava), or returns false when the
    /// row already had `automaticAttemptsPerDay` of them.
    private func takeAutomaticAttempt(for id: UUID) -> Bool {
        let current = now()
        let today = (automaticAttempts[id] ?? []).filter {
            EZZKEvidenceNumberPolicy.isUsable(allocatedAt: $0, at: current)
        }
        guard today.count < Self.automaticAttemptsPerDay else {
            automaticAttempts[id] = today
            return false
        }
        automaticAttempts[id] = today + [current]
        return true
    }

    private static func hasEvidenceNumber(_ record: EvidenceRecord) -> Bool {
        !(record.evidenceNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
}
