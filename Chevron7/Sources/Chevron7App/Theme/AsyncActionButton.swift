// New code: SPDX-FileCopyrightText: 2026 Marián Čuprík, SPDX-License-Identifier: EUPL-1.2.
// Interaction choreography adapted from SwiftPieces CommitButton
// (https://github.com/Saivion/SwiftPieces, registry/swift/controls/CommitButton.swift):
// only the async phase-machine idea was adapted; no upstream source lines or color
// code were copied. Upstream work retained under its own terms, reproduced below.
//
// MIT + Commons Clause License Condition v1.0
// Copyright (c) 2026 Saivion Hayes
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, and distribute the Software as part of
// an application, website, or product, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// Commons Clause Restriction: you may use this Software, including for any
// commercial purpose, so long as you do not sell, sublicense, or redistribute
// the components themselves, whether alone, in a bundle, or as a ported version.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import SwiftUI

/// Read-only visual phase for an async action button. Derived from store state on
/// every render; never written back into the store.
enum AsyncActionPhase: Equatable {
    case idle
    case loading
    case error(String)
    case disabled

    /// Loading wins over `canSign == false` (`canSign` includes `!isSigning`);
    /// a set error wins over ineligibility so failures stay visible.
    static func derive(isSigning: Bool, lastError: String?, canSign: Bool) -> Self {
        if isSigning { return .loading }
        if let lastError { return .error(lastError) }
        return canSign ? .idle : .disabled
    }
}

/// Primary async action button: idle label, loading ring with the current stage
/// text, error doubling as retry. The detailed error stays in the caller's error
/// block; this button shows only the retry affordance.
struct AsyncActionButton: View {
    let phase: AsyncActionPhase
    let title: String
    let retryTitle: String
    /// Stage text while loading (e.g. PDF/A progress); falls back to `title`.
    let loadingText: String?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakes = 0

    init(
        phase: AsyncActionPhase,
        title: String,
        retryTitle: String = "Skúsiť znova",
        loadingText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.phase = phase
        self.title = title
        self.retryTitle = retryTitle
        self.loadingText = loadingText
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                switch phase {
                case .loading:
                    ProgressView().controlSize(.small)
                case .error:
                    Image(systemName: "exclamationmark.triangle")
                case .idle, .disabled:
                    Image(systemName: "signature.badge.checkmark")
                }
                Text(labelText)
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { content, value in
            content.offset(x: value)
        } keyframes: { _ in
            // Finite shake: always lands back at zero, so retry/loading are never displaced.
            KeyframeTrack {
                CubicKeyframe(0, duration: 0.05)
                CubicKeyframe(-6, duration: 0.06)
                CubicKeyframe(6, duration: 0.06)
                CubicKeyframe(-3, duration: 0.06)
                CubicKeyframe(0, duration: 0.06)
            }
        }
        .accessibilityLabel(accessibilityText)
        .onChange(of: phase) { _, new in
            if case .error = new, !reduceMotion {
                shakes += 1
            }
        }
    }

    private var labelText: String {
        switch phase {
        case .loading:
            return (loadingText?.isEmpty == false ? loadingText! : title)
        case .error:
            return retryTitle
        case .idle, .disabled:
            return title
        }
    }

    private var accessibilityText: String {
        if case .error(let message) = phase {
            return "\(retryTitle). \(message)"
        }
        return labelText
    }
}

#Preview {
    VStack(spacing: 12) {
        AsyncActionButton(phase: .idle, title: "Podpísať KEP", action: {})
        AsyncActionButton(phase: .loading, title: "Podpísať KEP", loadingText: "Konvertujem do PDF/A…", action: {})
            .disabled(true)
        AsyncActionButton(phase: .error("Podpis sa nepodarilo vytvoriť."), title: "Podpísať KEP", action: {})
        AsyncActionButton(phase: .disabled, title: "Podpísať KEP", action: {})
            .disabled(true)
    }
    .padding()
}
