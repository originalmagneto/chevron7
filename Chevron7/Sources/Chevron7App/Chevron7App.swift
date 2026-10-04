// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

@MainActor
@Observable
final class Chevron7AppModel {
    let settingsStore: AppSettingsStore
    let recentDocumentStore: RecentDocumentStore
    let signingStore: SigningSessionStore
    let zakoStore: ZakoSessionStore
    let ezzkAccountController: EZZKAccountController
    let signedDocumentStore: SignedDocumentStore
    let webSigning: WebSigningCoordinator
    let cardReader: CardReaderStatus
    let updater: AppUpdater

    init() {
        let settings = AppSettingsStore()
        let recentDocuments = RecentDocumentStore(settingsStore: settings)
        settingsStore = settings
        recentDocumentStore = recentDocuments
        ezzkAccountController = settings.ezzkAccountController
        signingStore = SigningSessionStore(
            signingProvider: settings.signingProvider,
            settingsStore: settings,
            recentDocumentStore: recentDocuments)
        zakoStore = ZakoSessionStore(settingsStore: settings, exampleBank: settings.exampleBank)
        let signedDocuments = SignedDocumentStore()
        signedDocumentStore = signedDocuments
        signingStore.signedDocumentStore = signedDocuments
        webSigning = WebSigningCoordinator(settingsStore: settings, signedDocumentStore: signedDocuments)
        cardReader = CardReaderStatus(
            discover: { [settings] in await settings.signingProvider.availableIdentities() },
            readCardATRs: { await SmartcardSlotReader.cardATRs() })
        updater = AppUpdater()
        let signing = signingStore
        let zako = zakoStore
        let browserSigning = webSigning
        cardReader.onRefresh = {
            signing.applyReaderIdentities($0)
            // ZaKo's clause step gates the evidence number on the card, so it hears the reader too.
            zako.applyReaderIdentities($0)
        }
        cardReader.isPaused = {
            signing.isSigning || signing.isResolvingCertificate
                || signing.batchPhase == .preflighting || signing.batchPhase == .signing
                || zako.isAuthorizing || zako.isResolvingCertificate
                || browserSigning.pending != nil
        }

        // Rows waiting for EZZK are sent and looked up every five minutes while a regular
        // Chevron7 runs (ruling R13); a web-signing launch starts the check only once the
        // app becomes regular. The process ending stops it.
        let checker = settings.statusChecker
        // Sparkle follows the same rule: a portal request must not raise an
        // update prompt, so a web-signing launch starts it only once the app
        // becomes regular.
        let appUpdater = updater
        checker.startIfAllowed(launchMode: AppLaunchMode.current, isRegularApp: false)
        if AppLaunchMode.current != .webSigning {
            appUpdater.startIfNeeded()
        }
        AppDelegate.onBecomeRegular = {
            checker.startIfAllowed(launchMode: AppLaunchMode.current, isRegularApp: true)
            appUpdater.startIfNeeded()
        }

        // Browser requests reach the app through the Safari extension and the
        // launchd rendezvous; nothing signs without the sheet this raises.
        let coordinator = webSigning
        WebBridgeListener.shared.setSignHandler { request in
            try await coordinator.handle(request)
        }
    }
}

struct Chevron7CommandActions {
    let openDocument: () -> Void
    let addFiles: () -> Void
    let toggleSidebar: () -> Void
    /// Recent documents for the File menu; empty when the feature is off.
    let recentDocuments: [RecentDocumentStore.RecentDocument]
    let openRecent: (RecentDocumentStore.RecentDocument) -> Void
    let clearRecent: () -> Void
}

private struct Chevron7CommandActionsKey: FocusedValueKey {
    typealias Value = Chevron7CommandActions
}

extension FocusedValues {
    var chevron7CommandActions: Chevron7CommandActions? {
        get { self[Chevron7CommandActionsKey.self] }
        set { self[Chevron7CommandActionsKey.self] = newValue }
    }
}

@main
struct Chevron7App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = Chevron7AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .environment(model.ezzkAccountController)
                .frame(minWidth: MacOS27Layout.rootMinimumWidth, minHeight: 640)
                .frame(idealWidth: 1320, idealHeight: 860)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1320, height: 860)
        // A portal request started the app: only the signing panel, no main window.
        .defaultLaunchBehavior(AppLaunchMode.current == .webSigning ? .suppressed : .automatic)
        // Window restoration would reopen the last main window despite the suppression.
        .restorationBehavior(AppLaunchMode.current == .webSigning ? .disabled : .automatic)
        .commands {
            Chevron7Commands(updater: model.updater)
        }

        // A regular window instead of the Settings scene: the Settings scene sizes
        // its window from the hosting view's preferred size and cannot be resized.
        Window("Nastavenia", id: SettingsWindow.id) {
            SettingsView(settingsStore: model.settingsStore, waitForLearningWrites: { await model.zakoStore.waitForBankWrites() })
                .environment(model.ezzkAccountController)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 940, height: 720)
        .windowResizability(.contentMinSize)
        Window("Trénovanie detektora", id: DetectorTrainingWindow.id) {
            DetectorTrainingView(settingsStore: model.settingsStore)
        }
        .defaultSize(width: 680, height: 600)
    }
}

private struct Chevron7Commands: Commands {
    @FocusedValue(\.chevron7CommandActions) private var actions
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button {
                actions?.openDocument()
            } label: {
                Label("Otvoriť súbor…", systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(actions == nil)

            Button {
                actions?.addFiles()
            } label: {
                Label("Pridať súbory…", systemImage: "plus.rectangle.on.folder")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Menu("Otvoriť nedávne") {
                let recents = actions?.recentDocuments ?? []
                if recents.isEmpty {
                    Text("Žiadne nedávne dokumenty")
                } else {
                    ForEach(recents) { entry in
                        Button {
                            actions?.openRecent(entry)
                        } label: {
                            Label(entry.displayName, systemImage: "doc")
                        }
                    }
                    Divider()
                    Button {
                        actions?.clearRecent()
                    } label: {
                        Label("Vymazať menu", systemImage: "trash")
                    }
                }
            }
            .disabled(actions == nil)
        }

        CommandGroup(after: .sidebar) {
            Button {
                actions?.toggleSidebar()
            } label: {
                Label("Zobraziť alebo skryť sidebar", systemImage: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(actions == nil)
        }

        CommandGroup(after: .appInfo) {
            Button("Skontrolovať aktualizácie…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.isConfigured)
        }

        CommandGroup(replacing: .appSettings) {
            OpenSettingsButton {
                Label("Nastavenia…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button {
                NSWorkspace.shared.open(AppLinks.donate)
            } label: {
                Label("Podporiť vývoj…", systemImage: "cup.and.saucer")
            }
        }
    }
}

/// Links the app opens in the browser.
enum AppLinks {
    /// Voluntary contributions. They pay for the Apple Developer Program
    /// membership, without which builds stay ad-hoc signed and Safari loads the
    /// extension only with Allow Unsigned Extensions re-enabled after every start.
    static let donate = URL(string: "https://buymeacoffee.com/chevron7")!
}

/// The quiet "Podporiť vývoj" row at the bottom of the main window's sidebar, next to
/// "Nastavenia": the Help menu's page, a plain label and a tooltip that says why. No
/// badge, animation or prompt.
enum SidebarDonateLink {
    static let url = AppLinks.donate
    static let title = "Podporiť vývoj"
    static let symbol = "cup.and.heat.waves.fill"
    /// The official yellow button image bundled by build_app.sh (Contents/Resources).
    static let buttonImageName = "BuyMeACoffee"
    /// Buy Me a Coffee's brand yellow (#FFDD00) with near-black text, as on the website's
    /// button; it reads the same in light and dark mode.
    static let brandYellow = (red: 1.0, green: 0xDD / 255.0, blue: 0.0)
    static let brandInk = (red: 0x0D / 255.0, green: 0x0C / 255.0, blue: 0x22 / 255.0)
    static let help =
        "Chevron7 je zadarmo. Príspevok cez Buy Me a Coffee pomáha platiť vývoj a podpisovanie aplikácie."
    static let accessibilityLabel = "Podporiť vývoj Chevron7 cez Buy Me a Coffee"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A portal request started the app: no Dock icon and no menu bar until the
        // person opens Chevron7 themselves.
        if AppLaunchMode.current == .webSigning {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FinderQuickActionService.installQuickAction()
        // The listener connects to the agent, so the agent is registered first.
        WebBridgeAgentService.ensureRegistered()
        WebBridgeListener.shared.start()
    }

    /// The launch open event asks for an untitled main window; a web-signing launch
    /// shows only the signing panel.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        AppLaunchMode.current != .webSigning || NSApp.activationPolicy() == .regular
    }

    /// Dock, Finder or Spotlight while the app already runs: become a regular app,
    /// and let SwiftUI open the main window when none is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.becomeRegularApp()
        Self.openMainWindowIfNeeded()
        return true
    }

    /// The main window scene is suppressed after a web-signing launch, so reopening
    /// does not bring one back by itself. The File > New Window command (⌘N) does.
    @MainActor
    static func openMainWindowIfNeeded() {
        let hasMainWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
        guard !hasMainWindow, let item = newWindowMenuItem(in: NSApp.mainMenu), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    @MainActor
    private static func newWindowMenuItem(in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.keyEquivalent == "n", item.keyEquivalentModifierMask == .command, item.action != nil {
                return item
            }
            if let found = newWindowMenuItem(in: item.submenu) {
                return found
            }
        }
        return nil
    }

    /// Set by the app model: work that waits for a regular app (the EZZK status check).
    @MainActor static var onBecomeRegular: (() -> Void)?

    @MainActor
    static func becomeRegularApp() {
        onBecomeRegular?()
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

enum SettingsWindow {
    static let id = "settings"
}

/// Opens (or fronts) the settings window; replaces `SettingsLink` now that the
/// settings live in a regular `Window` scene.
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            AppDelegate.becomeRegularApp()
            openWindow(id: SettingsWindow.id)
        } label: {
            label()
        }
    }
}
