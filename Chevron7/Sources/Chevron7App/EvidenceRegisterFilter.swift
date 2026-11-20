// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// The Register's filters: status, EZZK environment and the search text. Pure, so the
/// filtering is tested without the table.
enum EvidenceRegisterFilter {
    enum Environment: String, CaseIterable, Identifiable {
        case all
        case production
        case test
        case demo

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "Všetky prostredia"
            case .production: "Ostrá evidencia"
            case .test: "Testovacia evidencia"
            case .demo: "Skúšobný režim"
            }
        }

        /// A row written before EZZK modes were stored matches only "Všetky prostredia":
        /// its environment is not known.
        func matches(_ mode: AppSettings.EZZKMode?) -> Bool {
            switch self {
            case .all: true
            case .production: mode == .production
            case .test: mode == .test
            case .demo: mode == .demo
            }
        }
    }

    static func isActive(status: EvidenceRecord.Status?, environment: Environment, text: String) -> Bool {
        status != nil || environment != .all || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func apply(_ records: [EvidenceRecord], status: EvidenceRecord.Status?,
                      environment: Environment, text: String) -> [EvidenceRecord] {
        var result = records
        if let status {
            result = result.filter { $0.status == status }
        }
        if environment != .all {
            result = result.filter { environment.matches($0.ezzkMode) }
        }
        guard !text.isEmpty else { return result }
        let query = text.lowercased()
        return result.filter {
            $0.originalName.lowercased().contains(query) ||
            $0.newDocumentName.lowercased().contains(query) ||
            ($0.evidenceNumber ?? "").lowercased().contains(query)
        }
    }
}
