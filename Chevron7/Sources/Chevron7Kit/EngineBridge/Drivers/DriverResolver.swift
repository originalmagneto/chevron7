// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

enum DriverRequirementError: Error, Sendable, Equatable, LocalizedError {
    case arm64Required
    case architectureInspectionFailed

    var errorDescription: String? {
        switch self {
        case .arm64Required:
            String(localized: "The selected signing component must include an ARM64 slice.")
        case .architectureInspectionFailed:
            String(localized: "The selected signing component could not be inspected.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .arm64Required:
            String(localized: "Install an ARM64-compatible signing component and try again.")
        case .architectureInspectionFailed:
            String(localized: "Reinstall the signing component and try again.")
        }
    }
}

/// Checks that the helper and each PKCS#11 driver can run natively on Apple Silicon.
/// The helper is required: without it nothing signs. A driver is checked on its own,
/// so one Intel-only middleware on the Mac never hides the cards of the others.
/// The engine's DRIVERS payload carries only id, name and path, so no middleware
/// version is checked here.
struct DriverResolver: Sendable {
    private let inspector: MachOInspector

    init(lipo: any LipoProcess = SystemLipoProcess()) {
        inspector = MachOInspector(lipo: lipo)
    }

    func requireNativeHelper(at helperURL: URL) throws {
        guard try inspector.containsArm64Slice(at: helperURL) else {
            throw DriverRequirementError.arm64Required
        }
    }

    /// Nil when the driver can load in the arm64 helper, otherwise a Slovak reason for the person.
    func unavailableReason(driverURL: URL, displayName: String) -> String? {
        do {
            if try inspector.containsArm64Slice(at: driverURL) { return nil }
            return "Ovládač karty „\(displayName)“ nemá verziu pre Apple Silicon (ARM64). "
                + "Nainštalujte aktuálnu verziu od výrobcu karty."
        } catch {
            return "Ovládač karty „\(displayName)“ sa nepodarilo overiť. Preinštalujte ho od výrobcu karty."
        }
    }
}
