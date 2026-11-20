// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

/// The "Prehľad" step of the training window: one readiness statement with
/// its requirement and meters, a compact table of kinds, and the privacy
/// note and import kept small at the bottom. Sized to fit the window's
/// default size without scrolling for a typical bank.
struct DetectorTrainingOverviewView: View {
    let overview: DetectorTrainingOverview
    let onImport: () -> Void
    @State private var importExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readinessCard
            kindsCard
            secondaryNotes
        }
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(overview.headline)
                    .font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: overview.readiness == .ready ? "checkmark.circle.fill" : "hourglass")
                    .foregroundStyle(overview.readiness == .ready ? Color.green : Color.secondary)
            }
            Text(overview.requirement)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                ForEach(overview.meters, id: \.title) { meter in
                    meterView(meter)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
    }

    private func meterView(_ meter: DetectorTrainingOverview.Meter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(meter.title)
                    .font(.callout)
                Spacer(minLength: 8)
                if meter.isMet {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                        .accessibilityLabel("splnené")
                }
                Text(meter.valueText)
                    .font(.body.monospacedDigit().weight(.medium))
            }
            ProgressView(value: meter.fraction)
                .tint(meter.isMet ? .green : .accentColor)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private var kindsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Druhy prvkov", systemImage: "square.grid.2x2")
                    .font(.headline)
                Spacer()
            }
            Text(overview.kindsExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            if overview.kinds.isEmpty {
                Text("Zatiaľ žiadne označené prvky.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)],
                          alignment: .leading, spacing: 6) {
                    ForEach(overview.kinds) { row in
                        kindRow(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func kindRow(_ row: DetectorTrainingOverview.KindRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(row.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(row.countText)
                .font(.callout.monospacedDigit())
            Label {
                Text(row.stateText)
            } icon: {
                Image(systemName: row.isEnough ? "checkmark" : "minus")
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(row.isEnough ? Color.green : Color.secondary)
            .frame(width: 74, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityText)
    }

    private var secondaryNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Iba na tomto Macu: detektor sa učí z vašich skontrolovaných strán, nič nikam neposiela a nové návrhy bude stále potvrdzovať človek.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $importExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dovezený detektor pochádza z cudzieho Macu a vašim dokumentom môže škodiť. Overím ho preto na vašich skontrolovaných stranách a aktivujem ho, len keď prejde rovnakou bránou ako vlastné trénovanie. Prenáša sa iba model, nikdy vaše skeny.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Importovať detektor zo súboru…", action: onImport)
                        .controlSize(.small)
                }
                .padding(.top, 4)
            } label: {
                Text("Detektor z iného Macu")
                    .font(.callout)
            }
        }
        .padding(.horizontal, 4)
    }
}
