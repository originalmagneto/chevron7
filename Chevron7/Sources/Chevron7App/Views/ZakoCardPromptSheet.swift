// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

/// The card step of a guarded ZaKo action: waits for a card with the mandate certificate,
/// or takes its PIN. Cancelling drops the action; nothing is allocated or signed.
struct ZakoCardPromptSheet: View {
    @Bindable var store: ZakoSessionStore
    let prompt: ZakoCardPrompt
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch prompt {
            case .checkingCard: checkingCard
            case .insertCard: insertCard
            case .enterPIN: enterPIN
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var purpose: String {
        store.pendingCardAction == .evidenceNumber
            ? "Evidenčné číslo sa pridelí až po overení mandátneho certifikátu."
            : "Konverzia sa autorizuje mandátnym certifikátom z karty."
    }

    private var checkingCard: some View {
        Group {
            Label("Kontrolujem kartu…", systemImage: "creditcard.and.123")
                .font(.headline)
            Text("Zisťujem, aká karta je v čítačke. \(purpose)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Môže to trvať niekoľko sekúnd.")
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { store.cancelCardFlow() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var insertCard: some View {
        Group {
            Label("Vložte kartu s mandátnym certifikátom", systemImage: "creditcard.and.123")
                .font(.headline)
            Text("Vložte advokátsky preukaz SAK s mandátnym certifikátom (MQC) do čítačky. \(purpose)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Čakám na kartu…")
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { store.cancelCardFlow() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .task { await store.waitForCard() }
    }

    private var enterPIN: some View {
        Group {
            Label("PIN karty", systemImage: "key.horizontal")
                .font(.headline)
            Text("Zadajte PIN podpisového certifikátu. \(purpose) PIN si aplikácia pamätá len do ukončenia a zabudne ho, keď kartu vyberiete.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.certificateLoadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .focused($pinFocused)
                .onSubmit(submit)
            HStack {
                if store.isResolvingCertificate {
                    ProgressView().controlSize(.small)
                    Text("Načítavam certifikáty z karty…").font(.caption)
                }
                Spacer()
                Button("Zrušiť", role: .cancel) { store.cancelCardFlow() }
                    .keyboardShortcut(.cancelAction)
                Button("Pokračovať", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty || store.isResolvingCertificate)
            }
        }
        .onAppear { pinFocused = true }
    }

    private func submit() {
        guard !pin.isEmpty else { return }
        let entered = pin
        pin = ""
        Task { await store.submitCardPIN(entered) }
    }
}
