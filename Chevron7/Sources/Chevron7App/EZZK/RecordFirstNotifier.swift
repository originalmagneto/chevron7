// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Foundation
import Observation
import UserNotifications

/// A stored record-first conversion the advocate asked to finish (a notification, the sidebar,
/// the Register). Kept until the main window takes it, as `ExternalDocumentOpen` does for files.
@MainActor
@Observable
final class PendingConversionOpen {
    private(set) var requestCount = 0
    private var requested: UUID?

    func request(_ id: UUID) {
        requested = id
        requestCount += 1
    }

    func take() -> UUID? {
        defer { requested = nil }
        return requested
    }
}

/// macOS notifications for the record-first watcher. Created only by the app model: the
/// notification center cannot be used from the test process.
@MainActor
final class RecordFirstNotifier: NSObject, RecordFirstNotifying, UNUserNotificationCenterDelegate {
    nonisolated static let categoryIdentifier = "record-first"
    nonisolated static let recordIDKey = "recordID"

    private let center = UNUserNotificationCenter.current()
    private let open: PendingConversionOpen
    private var askedForAuthorization = false

    init(open: PendingConversionOpen) {
        self.open = open
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !askedForAuthorization else { return }
        askedForAuthorization = true
        let center = center
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func recordProcessed(_ pending: RecordFirstPending) {
        let text = RecordFirstPendingPresentation.processedNotification(pending)
        post(id: pending.recordID, title: text.title, body: text.body)
    }

    func recordRejected(_ pending: RecordFirstPending, code: Int?, description: String?) {
        let text = RecordFirstPendingPresentation.rejectedNotification(pending, code: code, description: description)
        post(id: pending.recordID, title: text.title, body: text.body)
    }

    private func post(id: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.recordIDKey: id.uuidString]
        let request = UNNotificationRequest(identifier: "record-first-\(id.uuidString)", content: content, trigger: nil)
        let center = center
        Task {
            // Asked here too, for a conversion that waited across a restart.
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[Self.recordIDKey] as? String, let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            AppDelegate.becomeRegularApp()
            AppDelegate.openMainWindowIfNeeded(bringToFront: true)
            NSApp.activate()
            self.open.request(id)
        }
    }
}
