// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit
import AppKit

public extension View {
    func glassCard(cornerRadius: CGFloat = 12, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    /// Lighter container for inspector panels that avoids multiple frosted material layers.
    func inspectorCard(cornerRadius: CGFloat = 12, padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

// MARK: - Sticky Bottom Action Bar
struct StickyActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.5)
            HStack(spacing: 12) {
                content()
            }
            .padding(12)
        }
        .background(.regularMaterial)
    }
}

// MARK: - Smartcard HUD Status
struct SmartcardHUDStatus: View {
    let isConnected: Bool
    let label: String
    let detail: String?
    /// A card is in the reader but its driver is missing: a warning with download links.
    var needsDriver: Bool = false
    var drivers: [CardDriver] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.callout)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(detail ?? "")

            if needsDriver {
                ForEach(drivers, id: \.self) { driver in
                    Button("Stiahnuť \(driver.name)…") {
                        NSWorkspace.shared.open(driver.downloadURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 24)
                    .help("Otvorí stránku výrobcu ovládača. Po inštalácii kartu vyberte a znova vložte do čítačky.")
                }
            }
        }
    }

    private var symbol: String {
        if needsDriver { return "exclamationmark.triangle.fill" }
        return isConnected ? "creditcard.fill" : "creditcard"
    }

    private var tint: Color {
        if needsDriver { return .orange }
        return isConnected ? .green : .secondary
    }
}

// MARK: - eIDAS Verified Badge
struct EIDASBadge: View {
    enum Status {
        case qualified
        case warning
        case invalid
        case demo

        var label: String {
            switch self {
            case .qualified: return "eIDAS KEP"
            case .warning: return "Pozor (bez TSA)"
            case .invalid: return "Neplatný"
            case .demo: return "DEMO režim"
            }
        }

        var icon: String {
            switch self {
            case .qualified: return "checkmark.seal.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .invalid: return "xmark.seal.fill"
            case .demo: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .qualified: return .green
            case .warning: return .orange
            case .invalid: return .red
            case .demo: return .blue
            }
        }
    }

    let status: Status

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.icon)
                .font(.caption2.weight(.bold))
            Text(status.label)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.15), in: Capsule())
        .foregroundStyle(status.color)
        .overlay(
            Capsule()
                .strokeBorder(status.color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Flow Step Subheader Bar (Clean, transparent, no dark gray strip)
struct FlowStepBar: View {
    let steps: [(title: String, symbol: String)]
    let currentStepIndex: Int

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let isComplete = index < currentStepIndex
                let isActive = index == currentStepIndex

                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(stepFill(isComplete: isComplete, isActive: isActive))
                            .frame(width: 22, height: 22)
                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: step.symbol)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(isActive ? .white : .secondary)
                        }
                    }

                    Text(step.title)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : (isComplete ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.8)))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if isActive {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1))
                    }
                }

                if index < steps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func stepFill(isComplete: Bool, isActive: Bool) -> AnyShapeStyle {
        if isComplete {
            return AnyShapeStyle(Color.green)
        } else if isActive {
            return AnyShapeStyle(Color.accentColor)
        } else {
            return AnyShapeStyle(Color.secondary.opacity(0.18))
        }
    }
}

// MARK: - Dropzone Artwork
struct DropzoneArtwork: View {
    let icon: String
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [tint.opacity(0.3), tint.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: 130, height: 130)

            // Inner material circle
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 104, height: 104)
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

            // Center Symbol
            Image(systemName: icon)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(tint)
        }
    }
}

struct StatChip: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint.gradient)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

struct ConfidenceBar: View {
    let confidence: Double

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 44, height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill((confidence > 0.75 ? Color.green : confidence > 0.5 ? Color.orange : Color.red).gradient)
                    .frame(width: max(min(confidence, 1), 0.05) * 44, height: 5)
            }
            .accessibilityLabel(UXLabels.confidenceLabel(for: confidence))
            .help(UXLabels.confidenceLabel(for: confidence))
    }
}

/// One fixed colour per element kind for canvas boxes and the Nálezy row icons.
/// Grey is reserved for rejected findings. The first four keep their original system
/// colours; the other twelve are explicit mid-luminance sRGB values chosen to stay
/// apart from each other (CIEDE2000 at least 17.5) and to reach 3:1 both on white
/// scanned paper and on a dark inspector (#1E1E1E).
struct ElementKindColor {
    /// One fixed colour per kind, each at least 3:1 on white paper and on the dark
    /// inspector (the system green and orange were only about 2.2:1 on paper).
    static let explicitRGB: [SecurityElement.Kind: UInt32] = [
        .officialStamp: 0x2F6FDB,      // blue
        .handwrittenSignature: 0x2E9E4F, // green
        .embossedSeal: 0xC8650A,       // orange
        .initial: 0x8A4FD6,            // purple
        .other: 0xD6718A,              // dusty rose
        .certifiedSignature: 0x17823C, // dark green
        .roundOfficialStamp: 0xAE8932, // gold
        .waxSeal: 0xD01124,            // red
        .bindingCord: 0xE07552,        // coral
        .securityTape: 0x829C1C,       // olive green
        .permanentBinding: 0xA35A00,   // brown
        .watermark: 0x229FBF,          // sky
        .securityPattern: 0x007A7A,    // teal
        .opticallyVariable: 0xCC0085,  // magenta
        .securityFoil: 0x30A689,       // sea green
        .lamination: 0x706B00          // dark olive
    ]

    static func color(for kind: SecurityElement.Kind) -> Color {
        let rgb = explicitRGB[kind] ?? 0xD6718A
        return Color(.sRGB,
                     red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }
}
