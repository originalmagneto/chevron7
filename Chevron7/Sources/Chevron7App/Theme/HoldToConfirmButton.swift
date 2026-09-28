// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2
//
// Interaction choreography adapted from SwiftPieces HoldToConfirm
// (https://github.com/Saivion/SwiftPieces, registry/swift/controls/HoldToConfirm.swift):
// only the press-and-hold-to-commit idea was adapted; no upstream source lines
// were copied. Upstream work retained under its own terms (MIT + Commons Clause,
// Copyright (c) 2026 Saivion Hayes, see AsyncActionButton.swift for the full notice).
//
// A press-and-hold capsule for the one action that costs real money: ZaKo
// authorization consumes a paid evidence number, and the card stays in the
// reader with the PIN remembered, so a stray click must not commit. Pointer
// users hold for the full duration (early release rewinds, nothing fires);
// keyboard and VoiceOver users commit on activation, which is already a
// deliberate act after typing the PIN. No haptics: this is macOS.

import SwiftUI

struct HoldToConfirmButton: View {
    var title: String
    var systemImage: String
    var workingText: String?
    var duration: TimeInterval = 1.0
    var disabled: Bool = false
    var isWorking: Bool = false
    /// Test seam: mirrors the gesture's pressing transitions. Production
    /// leaves it nil; tests assert cancel resets to false.
    var pressingObserver: ((Bool) -> Void)?
    var action: () -> Void

    // Reset by the framework itself when the press ends or cancels: unlike a
    // manual flag, this cannot get stuck on early release or drag-away.
    @GestureState private var pressing = false
    @State private var fill: Double = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(isWorking ? (workingText ?? title) : title)
                .font(.body.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // The hittable shape ships with the control: the whole padded capsule,
        // so a press on padding still holds. Tests must not add their own.
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(disabled ? Color.gray.opacity(0.4) : Color.indigo)
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.35))
                    .frame(width: proxy.size.width * fill, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Color.white.opacity(0.9) : .clear, lineWidth: 2)
        }
        .opacity(disabled && !isWorking ? 0.6 : 1)
        // Focusable without the default activate interaction: Return/Space go
        // through onKeyPress below, VoiceOver through accessibilityAction, so a
        // keyboard commit can never double-fire with a system activation.
        .focusable(!disabled)
        .focused($focused)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: duration, maximumDistance: 30)
                .updating($pressing) { value, state, _ in
                    state = value && !disabled && !isWorking
                }
                // onEnded runs only on successful completion, so a full hold is
                // the only pointer path that commits.
                .onEnded { _ in commit() }
        )
        .onChange(of: pressing) { _, nowPressing in
            pressingObserver?(nowPressing)
            if nowPressing {
                withAnimation(.linear(duration: duration)) { fill = 1 }
            } else if !isWorking {
                withAnimation(.easeOut(duration: 0.2)) { fill = 0 }
            }
        }
        .onChange(of: disabled) { _, isDisabled in
            if isDisabled { fill = 0 }
        }
        .onDisappear { fill = 0 }
        .onKeyPress(.return) { commit(); return .handled }
        .onKeyPress(.space) { commit(); return .handled }
        .accessibilityLabel(title)
        .accessibilityHint("Podržte na autorizáciu konverzie. Spotrebuje evidenčné číslo.")
        .accessibilityAction(.default) { commit() }
        .help("Podržte na autorizáciu konverzie")
    }

    private func commit() {
        guard !disabled, !isWorking else { return }
        fill = 1
        action()
    }
}
