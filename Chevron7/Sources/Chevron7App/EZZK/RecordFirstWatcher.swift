// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// Tells the advocate what EZZK did with a record-first record waiting in the background.
@MainActor
protocol RecordFirstNotifying: AnyObject {
    /// Asked when a conversion first goes to the background.
    func requestAuthorizationIfNeeded()
    func recordProcessed(_ pending: RecordFirstPending)
    func recordRejected(_ pending: RecordFirstPending, code: Int?, description: String?)
}

/// Watches the record-first conversions of `RecordFirstPendingStore` while ZaKo does other
/// work. Every tick compares each conversion with its register row, whoever moved the row (this
/// watcher, the five-minute `EZZKStatusChecker`, "Overiť v EZZK"): a processed record readies the
/// clause signature and notifies; a rejected one notifies and drops the conversion (its row stays
/// in the Register). Only the EZZK calls are spaced (`checkInterval`): a conversion awaiting EZZK
/// is looked up every 30 s for 30 minutes after its record was signed, then every 2 minutes, and
/// after 24 hours the hourly check of the status checker alone. A record not sent yet is sent
/// once; a send that failed is left to the status checker's daily attempts. Nothing is signed
/// here: the advocate finishes the conversion in ZaKo (owner's decision of 2026-11-19).
@MainActor
@Observable
final class RecordFirstWatcher {
    static let tick: Duration = .seconds(10)

    @ObservationIgnored private let pendingStore: RecordFirstPendingStore
    @ObservationIgnored private let evidenceStore: LocalEvidenceStore
    @ObservationIgnored private let submit: (UUID) async -> EZZKStatusChecker.RowResult
    @ObservationIgnored private let verify: (UUID) async -> EZZKStatusChecker.RowResult
    @ObservationIgnored private let isBusy: (UUID) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored weak var notifier: RecordFirstNotifying?
    @ObservationIgnored private var lastCheck: [UUID: Date] = [:]
    @ObservationIgnored private var submitted: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isRunningPass = false

    init(pendingStore: RecordFirstPendingStore,
         evidenceStore: LocalEvidenceStore,
         submit: @escaping (UUID) async -> EZZKStatusChecker.RowResult,
         verify: @escaping (UUID) async -> EZZKStatusChecker.RowResult,
         isBusy: @escaping (UUID) -> Bool = { _ in false },
         notifier: RecordFirstNotifying?,
         now: @escaping () -> Date = { Date() }) {
        self.pendingStore = pendingStore
        self.evidenceStore = evidenceStore
        self.submit = submit
        self.verify = verify
        self.isBusy = isBusy
        self.notifier = notifier
        self.now = now
    }

    /// The app's watcher: sends and looks up through the status checker.
    convenience init(settingsStore: AppSettingsStore, isBusy: @escaping (UUID) -> Bool,
                     notifier: RecordFirstNotifying?) {
        let checker = settingsStore.statusChecker
        self.init(pendingStore: settingsStore.recordFirstPendingStore,
                  evidenceStore: settingsStore.evidenceStore,
                  submit: { await checker.submit(id: $0) },
                  verify: { await checker.verify(id: $0) },
                  isBusy: isBusy,
                  notifier: notifier)
    }

    /// Seconds between two EZZK calls for a conversion whose record was signed at `signedAt`,
    /// or nil once the hourly status check alone looks after it.
    nonisolated static func checkInterval(signedAt: Date, now: Date) -> TimeInterval? {
        let age = now.timeIntervalSince(signedAt)
        if age < 30 * 60 { return 30 }
        if age < 24 * 60 * 60 { return 120 }
        return nil
    }

    var isRunning: Bool { loop != nil }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOnce()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One pass over every pending conversion.
    func runOnce() async {
        guard !isRunningPass, evidenceStore.loadError == nil else { return }
        isRunningPass = true
        defer { isRunningPass = false }
        for snapshot in pendingStore.all {
            let id = snapshot.recordID
            // ZaKo is finishing it (or sending it right after the record signature).
            guard !isBusy(id), let pending = pendingStore.pending(id: id) else { continue }
            guard reconcile(pending), pending.stage == .awaitingEZZK, isDue(pending) else { continue }
            guard let row = evidenceStore.record(id: id) else { continue }
            lastCheck[id] = now()
            switch row.status {
            case .signed, .queuedForSubmission:
                guard !submitted.contains(id) else { continue }
                submitted.insert(id)
                _ = await submit(id)
            case .acceptedForProcessing, .outcomeUnknown:
                _ = await verify(id)
            default:
                continue
            }
            if !isBusy(id), let current = pendingStore.pending(id: id) {
                _ = reconcile(current)
            }
        }
    }

    /// Brings the conversion in line with its row. Returns false when it was dropped.
    private func reconcile(_ pending: RecordFirstPending) -> Bool {
        let id = pending.recordID
        guard let row = evidenceStore.record(id: id) else {
            // The row was deleted in the Register: nothing is left to finish.
            forget(id)
            return false
        }
        switch row.status {
        case .processed where pending.stage == .awaitingEZZK:
            var ready = pending
            ready.stage = .signingClientContainer
            // Kept in memory even when the write fails, so the notification stays true.
            try? pendingStore.save(ready)
            notifier?.recordProcessed(ready)
            return true
        case .rejected, .recordUnsigned:
            notifier?.recordRejected(pending, code: row.ezzkResultCode, description: row.ezzkResultDescription)
            forget(id)
            return false
        default:
            return true
        }
    }

    private func isDue(_ pending: RecordFirstPending) -> Bool {
        let current = now()
        guard let interval = Self.checkInterval(signedAt: pending.recordSignedAt, now: current) else { return false }
        guard let last = lastCheck[pending.recordID] else { return true }
        return current >= last.addingTimeInterval(interval)
    }

    private func forget(_ id: UUID) {
        pendingStore.remove(id: id)
        lastCheck[id] = nil
        submitted.remove(id)
    }
}
