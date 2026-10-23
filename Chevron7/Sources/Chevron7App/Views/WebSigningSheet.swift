// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

/// Confirmation for a signing request that arrived from a state portal.
///
/// The page never learns the PIN and never signs on its own: this sheet is the
/// only path from a browser request to the card.
struct WebSigningSheet: View {
    @Bindable var coordinator: WebSigningCoordinator
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            WebSigningBrandHeader(host: coordinator.pending?.request.pageHost)

            VStack(alignment: .leading, spacing: 16) {
                if let banner = coordinator.signatureCheck.bannerModel {
                    SignatureBanner(model: banner)
                }

                HStack(alignment: .top, spacing: 24) {
                    if let pending = coordinator.pending, let document = pending.pdfDocument {
                        WebSigningDocumentPreview(document: document, filename: pending.request.filename)
                            .frame(width: 360)
                            .frame(minHeight: 460)
                    }
                    controls
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)

            actions
        }
        .frame(minWidth: 860, idealWidth: 920, maxWidth: 1100)
        .onChange(of: coordinator.pinFocusRequest) {
            pinFocused = true
        }
        .sheet(isPresented: Bindable(coordinator.mobileSigning).isPresented) {
            if let session = coordinator.mobileSigning.session {
                MobileSigningSheet(session: session) {
                    coordinator.mobileSigning.cancel()
                }
            }
        }
        .sheet(isPresented: Bindable(coordinator.mobileSigning).isEidentitaPresented) {
            if let session = coordinator.mobileSigning.eidentitaSession {
                EidentitaSigningSheet(session: session) {
                    coordinator.mobileSigning.cancelEidentita()
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pending = coordinator.pending {
                documentCard(pending)
            }

            if coordinator.timestampSwitchAvailable {
                timestampToggle
            } else {
                Label("slovensko.sk prijíma iba podpis bez časovej pečiatky, podpíše sa presne tak, ako pýta stránka (\(coordinator.effectiveLevelDescription)).",
                      systemImage: "clock.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.mobileSigningAvailable {
                mobileOption
            }

            cardOption

            if let error = coordinator.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func documentCard(_ pending: WebSigningCoordinator.Pending) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if pending.pdfDocument == nil, let thumb = pending.pdfThumbnail {
                    VStack(spacing: 4) {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 60, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                        Text("1. strana")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: documentSymbol(pending))
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 40)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(pending.request.filename)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(pending.kindDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        metaChip(pending.sizeDescription)
                        metaChip(pending.request.signatureLevel.replacingOccurrences(of: "_", with: " "))
                    }
                    .padding(.top, 2)
                }
            }

            if !pending.attachments.isEmpty {
                attachmentList(pending.attachments)
            }

            if let excerpt = pending.xmlExcerpt {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pending.request.eform != nil || pending.request.payloadMimeType.contains("xml")
                        ? "Ukážka obsahu formulára (čiastočný náhľad):"
                        : "Ukážka obsahu dokumentu (čiastočný náhľad):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(excerpt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 90, alignment: .leading)
                    // Its own height, so the panel grows when the certificates appear
                    // instead of squeezing the excerpt.
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorCard(padding: 14)
    }

    private func documentSymbol(_ pending: WebSigningCoordinator.Pending) -> String {
        if pending.request.eform != nil || pending.request.payloadMimeType.lowercased().contains("xml") {
            return "doc.text"
        }
        return pending.xmlExcerpt == nil ? "doc" : "doc.plaintext"
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    /// The other documents the one signature covers, each openable in Quick Look
    /// before anything is signed.
    private func attachmentList(_ attachments: [WebSigningCoordinator.Attachment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(attachments.count == 1
                 ? "Podpis pokryje aj ďalší dokument:"
                 : "Podpis pokryje aj ďalšie dokumenty (\(attachments.count)):")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(attachments) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.filename)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(attachment.kindDescription) · \(attachment.sizeDescription)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        WebSigningQuickLook.shared.show(data: attachment.data, filename: attachment.filename)
                    } label: {
                        Label("Náhľad", systemImage: "eye")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Náhľad dokumentu \(attachment.filename)")
                }
            }
        }
    }

    /// State portals ask for Baseline B, so without this the phone offers only
    /// the handwritten-equivalent signature and the qualified one stays greyed out.
    private var timestampToggle: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pridať kvalifikovanú časovú pečiatku")
                    .font(.callout.weight(.medium))
                if coordinator.addsUnrequestedTimestamp {
                    Label("Podpíše sa ako osvedčený podpis (\(coordinator.effectiveLevelDescription)), o aký stránka nežiadala. nove.slovensko.sk takýto podpis odmietne.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Podpíše sa presne tak, ako pýta stránka (\(coordinator.effectiveLevelDescription)). Autogram v mobile to ponúkne ako vlastnoručný podpis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("Pridať kvalifikovanú časovú pečiatku", isOn: $coordinator.addsQualifiedTimestamp)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .inspectorCard(padding: 12)
    }

    /// Signing with the phone needs no reader and no PIN here, so it is offered
    /// first: on this path the eID is read over NFC and the PIN stays on the
    /// phone.
    private var mobileOption: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Podpísať mobilom")
                    .font(.callout.weight(.medium))
                Text(coordinator.eidentitaAvailable
                     ? "Občiansky preukaz cez NFC, bez čítačky: Autogram v mobile alebo eIDENTITA."
                     : "Občiansky preukaz cez NFC, bez čítačky.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if coordinator.eidentitaAvailable {
                Menu("Použiť mobil") {
                    Button("Autogram v mobile") { confirmViaMobile(.autogramMobile) }
                    Button("eIDENTITA (štátna aplikácia)") { confirmViaMobile(.eidentita) }
                }
                .fixedSize()
                .disabled(coordinator.isWorking)
            } else {
                Button("Použiť mobil") { confirmViaMobile(.autogramMobile) }
                    .disabled(coordinator.isWorking)
            }
        }
        .padding(12)
        .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func confirmViaMobile(_ method: MobileSigningMethod) {
        guard !coordinator.isWorking else { return }
        Task { await coordinator.confirmViaMobile(method: method) }
    }

    /// The card, its certificates and the PIN in one card, so the path to "Podpísať"
    /// reads as one step after the phone.
    private var cardOption: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityPicker
            if coordinator.selectedIdentityRequiresPIN {
                pinField
            } else if !coordinator.identities.isEmpty {
                bokNotice
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorCard(padding: 12)
    }

    private var identityPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "creditcard")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.mobileSigningAvailable ? "Alebo podpisovou kartou" : "Podpisovou kartou")
                        .font(.callout.weight(.medium))
                    cardStatus
                }
            }
            if coordinator.certificatesResolved, !coordinator.identities.isEmpty {
                // Every certificate on the card at once, marked qualified, mandate or
                // commercial, as in the main window, instead of a menu that hides the second.
                VStack(spacing: 6) {
                    ForEach(coordinator.identities) { identity in
                        IdentityRow(identity: identity,
                                    isSelected: coordinator.selectedIdentityID == identity.id,
                                    onSelect: { coordinator.selectedIdentityID = identity.id })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cardStatus: some View {
        if coordinator.identities.isEmpty {
            HStack(spacing: 8) {
                Text("Vložte kartu do čítačky.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Hľadať znova") {
                    Task { await coordinator.refreshIdentities() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } else if !coordinator.certificatesResolved {
            Label(coordinator.identities.first?.label ?? "Karta pripojená", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Vyberte certifikát, ktorým sa dokument podpíše.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pinField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PIN karty")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("PIN", text: $coordinator.pin)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($pinFocused)
                .onSubmit {
                    guard !coordinator.isWorking else { return }
                    Task { await coordinator.submitPIN() }
                }
            Label(coordinator.certificatesResolved
                  ? "Enter podpíše dokument."
                  : "Enter načíta certifikáty z karty.",
                  systemImage: "return")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The eID client asks for the BOK in its own window, both when the
    /// certificates are read and when the document is signed.
    private var bokNotice: some View {
        HStack(spacing: 8) {
            if coordinator.isReadingCertificates || coordinator.isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "person.text.rectangle")
                    .foregroundStyle(.secondary)
            }
            Text(coordinator.isReadingCertificates || coordinator.isWorking
                 ? "Zadajte BOK v okne eID klienta."
                 : "Po kliknutí na Podpísať si eID klient vypýta BOK dvakrát: prihlásenie ku karte a potvrdenie podpisu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        StickyActionBar {
            Button("Zrušiť", role: .cancel) { coordinator.cancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Spacer()
            if coordinator.isWorking {
                ProgressView().controlSize(.small)
            }
            Button { confirm() } label: {
                Label("Podpísať", systemImage: "signature")
                    .padding(.horizontal, 6)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(coordinator.isWorking || coordinator.selectedIdentityID == nil)
        }
    }

    private func confirm() {
        guard !coordinator.isWorking else { return }
        Task { await coordinator.confirm() }
    }
}

/// The panel's top band: the app icon on its midnight ground, so a prompt that
/// appears over Safari is recognisably Chevron7's, and the page that asked.
///
/// It runs under the transparent title bar, so the window title stays for
/// Mission Control and VoiceOver without being drawn twice.
struct WebSigningBrandHeader: View {
    let host: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .shadow(color: Chevron7Brand.amber.opacity(0.25), radius: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("CHEVRON7")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.6)
                    .foregroundStyle(Chevron7Brand.duskGrey)
                Text("Podpísať dokument zo stránky")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Chevron7Brand.signalWhite)
                originPill
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Chevron7Brand.midnight, Chevron7Brand.deepIndigo],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // The one light: a faint glow from where the icon's chevron sits.
                RadialGradient(colors: [Chevron7Brand.amber.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.06, y: 0.7), startRadius: 0, endRadius: 260)
                LinearGradient(colors: [.clear, Chevron7Brand.amber.opacity(0.55), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
            .ignoresSafeArea(edges: .top)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    private var originPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "safari")
            Text(host ?? "webový portál")
                .fontWeight(.medium)
                .foregroundStyle(Chevron7Brand.signalWhite)
            Text("· rozšírenie Safari")
        }
        .font(.caption)
        .foregroundStyle(Chevron7Brand.haze)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .accessibilityLabel("Pôvod: \(host ?? "webový portál") cez rozšírenie Safari")
    }
}
