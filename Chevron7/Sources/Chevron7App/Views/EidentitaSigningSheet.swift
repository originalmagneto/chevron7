// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

struct EidentitaSigningSheet: View {
    let session: EidentitaSigningSession
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Podpísať cez eIdentitu")
                .font(.title2.weight(.semibold))

            qrArea
                .frame(width: 260, height: 260)

            Text("Naskenujte QR kód mobilom a podpíšte dokument v štátnej aplikácii eIdentita občianskym preukazom.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            statusRow

            Button("Zrušiť", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .padding(28)
        .frame(width: 400)
    }

    @ViewBuilder
    private var qrArea: some View {
        if let image = session.qrImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .overlay { ProgressView() }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            switch session.state {
            case .idle, .uploading:
                ProgressView().controlSize(.small)
                Text("Nahrávam dokument na portál…")
            case .waitingForScan:
                ProgressView().controlSize(.small)
                if let deadline = session.deadline {
                    Text("Čakám na podpis z mobilu, QR kód platí do \(deadline.formatted(date: .omitted, time: .shortened)).")
                } else {
                    Text("Čakám na podpis z mobilu…")
                }
            case .signed:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Dokument je podpísaný.")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
            case .cancelled:
                Text("Zrušené.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
