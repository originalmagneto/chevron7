# Settings Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the five-tab Settings window with a System Settings style sidebar of seven panes, each a native grouped `Form` under a status header, with Basic content always visible and Advanced content behind one global toggle.

**Architecture:** Pure logic first (`SettingsAdvancedState`, `SettingsStatus`, `EZZKConnection`, Quick Action visibility, pane enum), each unit tested. Then shared view components, then one new pane view per file built next to the old `SettingsView` (which keeps compiling unchanged until the switch). One task swaps `SettingsView` to a `NavigationSplitView` shell and deletes the old tab code and cards. Last task: docs, rename boundary, full suite, build, screenshots.

**Tech Stack:** Swift 6, SwiftUI on macOS 27 (`NavigationSplitView`, `Form` with `.formStyle(.grouped)`, `.glassProminent`), XCTest, Swift Package Manager.

**Spec:** `Chevron7/docs/superpowers/specs/2026-10-06-settings-redesign-design.md`

## Global Constraints

- Work on branch `feat/settings-redesign` in `/Users/magneto/Projects/Chevron7`; the Swift package is `Chevron7/` (run every `swift` command from `/Users/magneto/Projects/Chevron7/Chevron7`).
- Toolchain: prefix every build and test with `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"`.
- Never use em dashes in code, strings, comments or docs. Use hyphens, colons or parentheses.
- English for code, identifiers and comments; Slovak for every user-facing string.
- Every new Swift file starts with the two SPDX lines used in the repo:
  `// SPDX-FileCopyrightText: 2026 Marián Čuprík` and `// SPDX-License-Identifier: EUPL-1.2`.
- Tests never touch the real Keychain, `~/Library/Application Support/Chevron7` or `~/Library/Caches/Chevron7`: App tests use `makeSettingsStore()` / `MemoryCredentialStore` / `ScriptedTransport` from `Tests/Chevron7AppTests/TestSettingsStore.swift`.
- Persisted raw values (`AppSettings.EZZKMode` raw values, `AppSettings.AIMode` raw values) never change.
- UI preferences: `@AppStorage("settings.showAdvanced")` (default `false`) and `@AppStorage("settings.selectedPane")` (pane raw value, default `""`).
- Liquid Glass only on the navigation layer: at most one `.buttonStyle(.glassProminent)` per pane; pills are tinted capsules, never `.glassEffect`.
- `LearningCardText` keeps its name and `summary(counts:)` signature (`SettingsLearningCardTests`). `AIPromptPreset` keeps its name and cases (`SigningBatchTests.testAIPromptPresetChoicesAreExactlyApproved`).
- "Autogram v mobile" is the AVM relay name and may appear in strings; `scripts/check-rename-boundary.sh` must pass.
- `CLAUDE.md` and `AGENTS.md` at the repo root stay byte-identical.

## File map

Create in `Chevron7/Sources/Chevron7App/Views/Settings/`:

| File | Responsibility |
|---|---|
| `SettingsPane.swift` | pane enum: title, subtitle, SF Symbol, tint, initial pane |
| `SettingsStatus.swift` | `StatusPillModel` and pure pill derivation per pane |
| `SettingsAdvancedState.swift` | pure "advanced value is active" predicates |
| `EZZKConnection.swift` | connect / disconnect flow over `AppSettingsStore` |
| `SettingsComponents.swift` | `SettingsIcon`, `StatusPill`, `SettingsPaneHeader`, `SettingsPaneForm`, `AdvancedBadge`, `AdvancedSectionHeader`, `InlineError` |
| `ProfileSettingsPane.swift` | profiles list and selected profile form |
| `EZZKSettingsPane.swift` | EZZK account, connect, submission, Advanced mode, lookup, numbers, migration |
| `SigningSettingsPane.swift` | TSA and PDF/A |
| `MobileSettingsPane.swift` | AVM toggle, eIdentita status, Advanced AVM server, portal, key removal |
| `EidentitaSetupSheet.swift` | eIdentita setup guide, key, verify |
| `BrowserFinderSettingsPane.swift` | Safari bridge, local copies, Quick Action, Finder guide sheet |
| `AISettingsPane.swift` | detection provider, learning, detector, prompts (also hosts `AIPromptPreset`, `LearningCardText`) |
| `GeneralSettingsPane.swift` | recent documents |
| `SettingsView.swift` | window shell (moved from `Views/SettingsView.swift`) |

Modify:
- `Chevron7/Sources/Chevron7Kit/Support/AppSettings.swift` (EZZK mode labels)
- `Chevron7/Sources/Chevron7App/ServicesProvider.swift` (Quick Action visibility)
- `Chevron7/Sources/Chevron7App/Chevron7App.swift` (window size)
- `Chevron7/Sources/Chevron7App/Views/SettingsView.swift` (deleted in Task 12)
- `CLAUDE.md`, `AGENTS.md`

Tests in `Chevron7/Tests/`:
- `Chevron7KitTests/EZZKModeLabelTests.swift`
- `Chevron7AppTests/SettingsPaneTests.swift`
- `Chevron7AppTests/SettingsAdvancedStateTests.swift`
- `Chevron7AppTests/SettingsStatusTests.swift`
- `Chevron7AppTests/EZZKConnectionTests.swift`
- `Chevron7AppTests/FinderQuickActionServiceTests.swift` (extend)

---

### Task 1: User-facing EZZK mode labels

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Support/AppSettings.swift:83-89`
- Test: `Chevron7/Tests/Chevron7KitTests/EZZKModeLabelTests.swift`

**Interfaces:**
- Produces: `AppSettings.EZZKMode.label` returns "Skúšobný režim (lokálne)", "Testovacia evidencia", "Ostrá evidencia".

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class EZZKModeLabelTests: XCTestCase {
    func testLabelsAreUserFacing() {
        XCTAssertEqual(AppSettings.EZZKMode.demo.label, "Skúšobný režim (lokálne)")
        XCTAssertEqual(AppSettings.EZZKMode.test.label, "Testovacia evidencia")
        XCTAssertEqual(AppSettings.EZZKMode.production.label, "Ostrá evidencia")
    }

    func testRawValuesStayPersisted() {
        XCTAssertEqual(AppSettings.EZZKMode.allCases.map(\.rawValue), ["demo", "test", "production"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter EZZKModeLabelTests`
Expected: FAIL, `testLabelsAreUserFacing` reports "Demo (lokálne)" is not equal to "Skúšobný režim (lokálne)".

- [ ] **Step 3: Change the labels**

In `AppSettings.swift`, replace the body of `EZZKMode.label`:

```swift
        public var label: String {
            switch self {
            case .demo: "Skúšobný režim (lokálne)"
            case .test: "Testovacia evidencia"
            case .production: "Ostrá evidencia"
            }
        }
```

- [ ] **Step 4: Run the test and the EZZK presentation tests**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter 'EZZKModeLabelTests|EZZKRecordPresentationTests'`
Expected: PASS. If an `EZZKRecordPresentationTests` assertion expects an old label, update that expected string to the new label (the Register shows `record.ezzkMode?.label`).

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7Kit/Support/AppSettings.swift Chevron7/Tests/Chevron7KitTests/EZZKModeLabelTests.swift Chevron7/Tests/Chevron7AppTests/EZZKRecordPresentationTests.swift
git commit -m "feat(ezzk): user-facing mode names instead of Demo, Test and Produkcia

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Pane enum and initial pane

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/SettingsPane.swift`
- Test: `Chevron7/Tests/Chevron7AppTests/SettingsPaneTests.swift`

**Interfaces:**
- Produces: `enum SettingsPane: String, CaseIterable, Identifiable` with cases `profile, ezzk, signing, mobile, browserFinder, ai, general`; `title: String`, `subtitle: String`, `symbol: String`, `tint: Color`; `static func initial(stored: String, ezzkConnected: Bool) -> SettingsPane`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class SettingsPaneTests: XCTestCase {
    func testSidebarOrder() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), [
            "Profil advokáta", "EZZK", "Podpisovanie", "Mobil a eIdentita",
            "Prehliadač a Finder", "AI a učenie", "Všeobecné"])
    }

    func testStoredPaneWins() {
        XCTAssertEqual(SettingsPane.initial(stored: "ai", ezzkConnected: false), .ai)
    }

    func testFirstOpenShowsEZZKUntilConnected() {
        XCTAssertEqual(SettingsPane.initial(stored: "", ezzkConnected: false), .ezzk)
        XCTAssertEqual(SettingsPane.initial(stored: "", ezzkConnected: true), .profile)
    }

    func testUnknownStoredPaneFallsBack() {
        XCTAssertEqual(SettingsPane.initial(stored: "conversion", ezzkConnected: true), .profile)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SettingsPaneTests`
Expected: FAIL to compile, "cannot find 'SettingsPane' in scope".

- [ ] **Step 3: Implement**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// One entry of the Settings sidebar, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case profile, ezzk, signing, mobile, browserFinder, ai, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Profil advokáta"
        case .ezzk: "EZZK"
        case .signing: "Podpisovanie"
        case .mobile: "Mobil a eIdentita"
        case .browserFinder: "Prehliadač a Finder"
        case .ai: "AI a učenie"
        case .general: "Všeobecné"
        }
    }

    var subtitle: String {
        switch self {
        case .profile: "Údaje advokáta do doložky a záznamu o konverzii"
        case .ezzk: "Evidencia zaručených konverzií"
        case .signing: "Časová pečiatka a formát PDF/A"
        case .mobile: "Podpis občianskym preukazom cez iPhone a eIdentitu"
        case .browserFinder: "Podpisovanie zo Safari a z kontextovej ponuky Findera"
        case .ai: "Detekcia bezpečnostných prvkov a učenie na tomto Macu"
        case .general: "Správanie aplikácie"
        }
    }

    var symbol: String {
        switch self {
        case .profile: "person.text.rectangle.fill"
        case .ezzk: "building.columns.fill"
        case .signing: "signature"
        case .mobile: "iphone.radiowaves.left.and.right"
        case .browserFinder: "safari.fill"
        case .ai: "eye.fill"
        case .general: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .profile: .blue
        case .ezzk: .green
        case .signing: .indigo
        case .mobile: .orange
        case .browserFinder: .teal
        case .ai: .purple
        case .general: .gray
        }
    }

    /// The remembered pane, else EZZK while it is not connected (the one step every
    /// advocate needs), else the profile.
    static func initial(stored: String, ezzkConnected: Bool) -> SettingsPane {
        if let pane = SettingsPane(rawValue: stored) { return pane }
        return ezzkConnected ? .profile : .ezzk
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SettingsPaneTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/Settings/SettingsPane.swift Chevron7/Tests/Chevron7AppTests/SettingsPaneTests.swift
git commit -m "feat(settings): sidebar panes with symbols, tints and the first pane

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Active Advanced values

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/SettingsAdvancedState.swift`
- Test: `Chevron7/Tests/Chevron7AppTests/SettingsAdvancedStateTests.swift`

**Interfaces:**
- Consumes: `AppSettings` (`Chevron7Kit`), `AVMClient.publicBaseURL`, `AGPClient.defaultBaseURL`.
- Produces: `enum SettingsAdvancedState` with static `(AppSettings) -> Bool` functions `ezzkModeIsActive`, `customTSAIsActive`, `avmServerIsActive`, `agpPortalIsActive`, `webSigningFolderIsActive`, `webSigningRetentionIsActive`, `aiProviderIsActive`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

final class SettingsAdvancedStateTests: XCTestCase {
    func testDefaultsAreNotActive() {
        let settings = AppSettings()
        XCTAssertFalse(SettingsAdvancedState.ezzkModeIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.customTSAIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.avmServerIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.agpPortalIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.webSigningFolderIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.webSigningRetentionIsActive(settings))
        XCTAssertFalse(SettingsAdvancedState.aiProviderIsActive(settings))
    }

    func testOnlyTheTestModeIsAdvanced() {
        XCTAssertTrue(SettingsAdvancedState.ezzkModeIsActive(AppSettings(ezzkMode: .test)))
        XCTAssertFalse(SettingsAdvancedState.ezzkModeIsActive(AppSettings(ezzkMode: .production)))
    }

    func testSelectedCustomTSAIsActive() {
        let url = "https://tsa.example.sk/tsp"
        XCTAssertTrue(SettingsAdvancedState.customTSAIsActive(
            AppSettings(customTSAServers: [url], selectedTSAURL: url)))
        XCTAssertFalse(SettingsAdvancedState.customTSAIsActive(
            AppSettings(customTSAServers: [url])))
    }

    func testChangedServersAreActive() {
        XCTAssertTrue(SettingsAdvancedState.avmServerIsActive(AppSettings(avmBaseURL: "https://avm.example.sk/api/v1")))
        XCTAssertTrue(SettingsAdvancedState.agpPortalIsActive(AppSettings(agpBaseURL: "https://agp.example.sk")))
    }

    func testWebSigningCustomisationsAreActive() {
        XCTAssertTrue(SettingsAdvancedState.webSigningFolderIsActive(AppSettings(webSigningOutputPath: "~/Podpisy")))
        XCTAssertFalse(SettingsAdvancedState.webSigningFolderIsActive(AppSettings(webSigningOutputPath: "  ")))
        XCTAssertTrue(SettingsAdvancedState.webSigningRetentionIsActive(AppSettings(webSigningRetentionDays: 30)))
    }

    func testExternalAIProvidersAreActive() {
        for mode in [AppSettings.AIMode.omlxLocal, .ollamaLocal, .customAPIKey] {
            XCTAssertTrue(SettingsAdvancedState.aiProviderIsActive(AppSettings(aiMode: mode)), "\(mode)")
        }
        XCTAssertFalse(SettingsAdvancedState.aiProviderIsActive(AppSettings(aiMode: .disabled)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SettingsAdvancedStateTests`
Expected: FAIL to compile, "cannot find 'SettingsAdvancedState' in scope". (If `AppSettings(...)` with only some labels does not compile, the memberwise init in `AppSettings.swift` lists every parameter with a default, so labels can be omitted; check the parameter order there and reorder the arguments in the test to match.)

- [ ] **Step 3: Implement**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// Whether an Advanced setting holds a value other than its default. Such a setting
/// stays visible even with Advanced off, so no hidden value changes signing or EZZK.
enum SettingsAdvancedState {
    static func ezzkModeIsActive(_ settings: AppSettings) -> Bool {
        settings.ezzkMode == .test
    }

    static func customTSAIsActive(_ settings: AppSettings) -> Bool {
        settings.customTSAServers.contains(settings.selectedTSAURL)
    }

    static func avmServerIsActive(_ settings: AppSettings) -> Bool {
        trimmed(settings.avmBaseURL) != AVMClient.publicBaseURL.absoluteString
    }

    static func agpPortalIsActive(_ settings: AppSettings) -> Bool {
        trimmed(settings.agpBaseURL) != AGPClient.defaultBaseURL.absoluteString
    }

    static func webSigningFolderIsActive(_ settings: AppSettings) -> Bool {
        !trimmed(settings.webSigningOutputPath).isEmpty
    }

    static func webSigningRetentionIsActive(_ settings: AppSettings) -> Bool {
        settings.webSigningRetentionDays != 0
    }

    static func aiProviderIsActive(_ settings: AppSettings) -> Bool {
        switch settings.aiMode {
        case .omlxLocal, .ollamaLocal, .customAPIKey: true
        case .builtInOnDevice, .disabled: false
        }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SettingsAdvancedStateTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/Settings/SettingsAdvancedState.swift Chevron7/Tests/Chevron7AppTests/SettingsAdvancedStateTests.swift
git commit -m "feat(settings): tell which Advanced settings hold a non-default value

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Quick Action visibility in Finder

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/ServicesProvider.swift` (add to `enum FinderQuickActionService`)
- Test: `Chevron7/Tests/Chevron7AppTests/FinderQuickActionServiceTests.swift` (append tests)

**Interfaces:**
- Produces: `enum QuickActionVisibility: Equatable { case visible, hiddenInFinder, notInstalled }` (top level, same file); `FinderQuickActionService.visibility(workflowInstalled: Bool, statuses: [String: Any]) -> QuickActionVisibility`; `FinderQuickActionService.currentVisibility() -> QuickActionVisibility`.

- [ ] **Step 1: Write the failing tests** (append inside `FinderQuickActionServiceTests`)

```swift
    func testVisibilityNeedsTheWorkflow() {
        XCTAssertEqual(FinderQuickActionService.visibility(workflowInstalled: false, statuses: [:]), .notInstalled)
    }

    func testVisibleWhenFinderShowsItInTheContextMenu() {
        let statuses = FinderQuickActionService.servicesStatus(updating: [:])
        XCTAssertEqual(FinderQuickActionService.visibility(workflowInstalled: true, statuses: statuses), .visible)
    }

    func testHiddenWhenThePersonUnchecksIt() {
        let key = "(null) - \(FinderQuickActionService.menuTitle) - runWorkflowAsService"
        let statuses: [String: Any] = [key: ["presentation_modes": ["ContextMenu": 0, "ServicesMenu": 0]]]
        XCTAssertEqual(FinderQuickActionService.visibility(workflowInstalled: true, statuses: statuses), .hiddenInFinder)
    }

    func testHiddenWithoutAModernEntry() {
        XCTAssertEqual(FinderQuickActionService.visibility(workflowInstalled: true, statuses: [:]), .hiddenInFinder)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter FinderQuickActionServiceTests`
Expected: FAIL to compile, "type 'FinderQuickActionService' has no member 'visibility'".

- [ ] **Step 3: Implement** (inside `enum FinderQuickActionService`, after `servicesStatus`; add the enum at file scope below the service)

```swift
    /// Whether Finder offers the Quick Action. Its file nearly always exists (every launch
    /// reinstalls it), so what tells the person something is the `pbs` entry: Finder's
    /// context menu reads `presentation_modes`, and a person who unchecked the action in
    /// Customize… has a zero there.
    static func visibility(workflowInstalled: Bool, statuses: [String: Any]) -> QuickActionVisibility {
        guard workflowInstalled else { return .notInstalled }
        let entry = statuses[statusKey(menuTitle)] as? [String: Any]
        let modes = entry?["presentation_modes"] as? [String: Any]
        let contextMenu = (modes?["ContextMenu"] as? NSNumber)?.intValue ?? 0
        return contextMenu == 1 ? .visible : .hiddenInFinder
    }

    static func currentVisibility() -> QuickActionVisibility {
        let installed = FileManager.default.fileExists(
            atPath: servicesDirectory.appendingPathComponent(workflowInstallName).path)
        let statuses = UserDefaults(suiteName: "pbs")?.dictionary(forKey: "NSServicesStatus") ?? [:]
        return visibility(workflowInstalled: installed, statuses: statuses)
    }
```

```swift
enum QuickActionVisibility: Equatable {
    case visible
    case hiddenInFinder
    case notInstalled
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter FinderQuickActionServiceTests`
Expected: PASS (existing tests plus 4 new).

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/ServicesProvider.swift Chevron7/Tests/Chevron7AppTests/FinderQuickActionServiceTests.swift
git commit -m "feat(finder): tell whether Finder actually shows the Quick Action

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Status pills

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/SettingsStatus.swift`
- Test: `Chevron7/Tests/Chevron7AppTests/SettingsStatusTests.swift`

**Interfaces:**
- Consumes: `AppSettings`, `EZZKAccountController.State`, `WebBridgeAgentService.Status`, `QuickActionVisibility` (Task 4), `TimestampAuthority.qualifiedURLs`, `DetectorTrainingReadiness.firstRunPages`.
- Produces:
  - `struct StatusPillModel: Equatable { enum Tone: Equatable { case ok, attention, off, info }; let tone: Tone; let text: String }`
  - `enum SettingsStatus` with static functions:
    - `profile(_ settings: AppSettings) -> [StatusPillModel]`
    - `ezzk(mode: AppSettings.EZZKMode, state: EZZKAccountController.State, hasStoredCredentials: Bool, productionAllowed: Bool) -> [StatusPillModel]`
    - `signing(_ settings: AppSettings) -> [StatusPillModel]`
    - `mobile(mobileSigningEnabled: Bool, eidentitaKeyStored: Bool, eidentitaUserID: String) -> [StatusPillModel]`
    - `browserFinder(agent: WebBridgeAgentService.Status, quickAction: QuickActionVisibility) -> [StatusPillModel]`
    - `ai(mode: AppSettings.AIMode, reviewedPages: Int?) -> [StatusPillModel]`

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

final class SettingsStatusTests: XCTestCase {
    private func pill(_ tone: StatusPillModel.Tone, _ text: String) -> StatusPillModel {
        StatusPillModel(tone: tone, text: text)
    }

    func testProfile() {
        XCTAssertEqual(SettingsStatus.profile(AppSettings()), [pill(.attention, "Žiadny profil")])
        var profile = AdvocateProfile()
        profile.fullName = "JUDr. Ján Novák"
        let settings = AppSettings(profiles: [profile], activeProfileID: profile.id)
        XCTAssertEqual(SettingsStatus.profile(settings), [pill(.info, "JUDr. Ján Novák")])
    }

    func testEZZKDemo() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .demo, state: .signedOut, hasStoredCredentials: false, productionAllowed: true),
                       [pill(.info, "Skúšobný režim, bez zápisu do evidencie")])
    }

    func testEZZKProductionWithoutLogin() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .production, state: .signedOut, hasStoredCredentials: false, productionAllowed: true),
                       [pill(.attention, "Nepripojené")])
    }

    func testEZZKConnected() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .production, state: .signedOut, hasStoredCredentials: true, productionAllowed: true),
                       [pill(.ok, "Pripojené"), pill(.ok, "Odosielanie zapnuté")])
        XCTAssertEqual(SettingsStatus.ezzk(mode: .production, state: .signedOut, hasStoredCredentials: true, productionAllowed: false),
                       [pill(.ok, "Pripojené"), pill(.off, "Odosielanie zamknuté")])
    }

    func testEZZKTestMode() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .test, state: .signedOut, hasStoredCredentials: true, productionAllowed: true),
                       [pill(.info, "Testovacia evidencia"), pill(.ok, "Prihlásené")])
        XCTAssertEqual(SettingsStatus.ezzk(mode: .test, state: .signedOut, hasStoredCredentials: false, productionAllowed: true),
                       [pill(.info, "Testovacia evidencia"), pill(.attention, "Neprihlásené")])
    }

    func testEZZKFailedLoginAddsAttention() {
        XCTAssertEqual(SettingsStatus.ezzk(mode: .production, state: .failed("x"), hasStoredCredentials: false, productionAllowed: true),
                       [pill(.attention, "Nepripojené"), pill(.attention, "Prihlásenie zlyhalo")])
    }

    func testSigningCustomTSAIsUnverified() {
        let url = "https://tsa.example.sk/tsp"
        let pills = SettingsStatus.signing(AppSettings(customTSAServers: [url], selectedTSAURL: url))
        XCTAssertEqual(pills.last, pill(.attention, "Kvalifikácia neoverená"))
    }

    func testSigningBuiltInQualifiedTSA() {
        let qualified = TimestampAuthority.qualifiedURLs[0].absoluteString
        let pills = SettingsStatus.signing(AppSettings(selectedTSAURL: qualified))
        XCTAssertEqual(pills.last, pill(.ok, "Kvalifikovaná"))
        XCTAssertEqual(pills.first?.tone, .info)
    }

    func testMobile() {
        XCTAssertEqual(SettingsStatus.mobile(mobileSigningEnabled: true, eidentitaKeyStored: true, eidentitaUserID: "37"),
                       [pill(.ok, "Podpis mobilom zapnutý"), pill(.ok, "eIdentita pripravená")])
        XCTAssertEqual(SettingsStatus.mobile(mobileSigningEnabled: false, eidentitaKeyStored: true, eidentitaUserID: " "),
                       [pill(.off, "Podpis mobilom vypnutý"), pill(.attention, "eIdentita nedokončená")])
        XCTAssertEqual(SettingsStatus.mobile(mobileSigningEnabled: true, eidentitaKeyStored: false, eidentitaUserID: ""),
                       [pill(.ok, "Podpis mobilom zapnutý"), pill(.off, "eIdentita nenastavená")])
    }

    func testBrowserFinder() {
        XCTAssertEqual(SettingsStatus.browserFinder(agent: .enabled, quickAction: .visible),
                       [pill(.ok, "Safari prepojené"), pill(.ok, "Quick Action vo Findere")])
        XCTAssertEqual(SettingsStatus.browserFinder(agent: .requiresApproval, quickAction: .hiddenInFinder),
                       [pill(.attention, "Safari nie je prepojené"), pill(.attention, "Quick Action skrytá vo Findere")])
        XCTAssertEqual(SettingsStatus.browserFinder(agent: .unsignedBuild, quickAction: .notInstalled),
                       [pill(.off, "Safari: vývojárska zostava"), pill(.attention, "Quick Action nenainštalovaná")])
    }

    func testAI() {
        XCTAssertEqual(SettingsStatus.ai(mode: .builtInOnDevice, reviewedPages: 10),
                       [pill(.ok, "Interný režim"), pill(.info, "Skontrolované strany: 10 z 40")])
        XCTAssertEqual(SettingsStatus.ai(mode: .disabled, reviewedPages: nil), [pill(.off, "AI vypnutá")])
        XCTAssertEqual(SettingsStatus.ai(mode: .ollamaLocal, reviewedPages: nil), [pill(.info, "Ollama")])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SettingsStatusTests`
Expected: FAIL to compile, "cannot find 'StatusPillModel' in scope".

- [ ] **Step 3: Implement**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// One status capsule in a Settings pane header.
struct StatusPillModel: Equatable {
    enum Tone: Equatable {
        /// Works.
        case ok
        /// Needs the person to act.
        case attention
        /// Switched off.
        case off
        /// Neutral information.
        case info
    }

    let tone: Tone
    let text: String
}

/// Header pills of each pane, read from state that already exists. Nothing here
/// talks to a service.
enum SettingsStatus {
    static func profile(_ settings: AppSettings) -> [StatusPillModel] {
        guard let active = settings.profiles.first(where: { $0.id == settings.activeProfileID }) else {
            return [StatusPillModel(tone: .attention, text: "Žiadny profil")]
        }
        let name = active.displayName.isEmpty ? "Nový profil" : active.displayName
        return [StatusPillModel(tone: .info, text: name)]
    }

    static func ezzk(mode: AppSettings.EZZKMode, state: EZZKAccountController.State,
                     hasStoredCredentials: Bool, productionAllowed: Bool) -> [StatusPillModel] {
        var pills: [StatusPillModel]
        switch mode {
        case .demo:
            pills = [StatusPillModel(tone: .info, text: "Skúšobný režim, bez zápisu do evidencie")]
        case .test:
            pills = [StatusPillModel(tone: .info, text: "Testovacia evidencia"),
                     hasStoredCredentials
                        ? StatusPillModel(tone: .ok, text: "Prihlásené")
                        : StatusPillModel(tone: .attention, text: "Neprihlásené")]
        case .production:
            if hasStoredCredentials {
                pills = [StatusPillModel(tone: .ok, text: "Pripojené"),
                         productionAllowed
                            ? StatusPillModel(tone: .ok, text: "Odosielanie zapnuté")
                            : StatusPillModel(tone: .off, text: "Odosielanie zamknuté")]
            } else {
                pills = [StatusPillModel(tone: .attention, text: "Nepripojené")]
            }
        }
        if case .failed = state {
            pills.append(StatusPillModel(tone: .attention, text: "Prihlásenie zlyhalo"))
        }
        return pills
    }

    static func signing(_ settings: AppSettings) -> [StatusPillModel] {
        let active = settings.activeTSA
        var pills = [StatusPillModel(tone: .info, text: active.name)]
        if TimestampAuthority.qualifiedURLs.map(\.absoluteString).contains(active.url) {
            pills.append(StatusPillModel(tone: .ok, text: "Kvalifikovaná"))
        } else if settings.activeTSAQualificationIsUnverified {
            pills.append(StatusPillModel(tone: .attention, text: "Kvalifikácia neoverená"))
        }
        return pills
    }

    static func mobile(mobileSigningEnabled: Bool, eidentitaKeyStored: Bool,
                       eidentitaUserID: String) -> [StatusPillModel] {
        let phone = mobileSigningEnabled
            ? StatusPillModel(tone: .ok, text: "Podpis mobilom zapnutý")
            : StatusPillModel(tone: .off, text: "Podpis mobilom vypnutý")
        let hasUserID = !eidentitaUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let eidentita: StatusPillModel = switch (eidentitaKeyStored, hasUserID) {
        case (true, true): StatusPillModel(tone: .ok, text: "eIdentita pripravená")
        case (false, false): StatusPillModel(tone: .off, text: "eIdentita nenastavená")
        default: StatusPillModel(tone: .attention, text: "eIdentita nedokončená")
        }
        return [phone, eidentita]
    }

    static func browserFinder(agent: WebBridgeAgentService.Status,
                              quickAction: QuickActionVisibility) -> [StatusPillModel] {
        let safari: StatusPillModel = switch agent {
        case .enabled: StatusPillModel(tone: .ok, text: "Safari prepojené")
        case .unsignedBuild: StatusPillModel(tone: .off, text: "Safari: vývojárska zostava")
        default: StatusPillModel(tone: .attention, text: "Safari nie je prepojené")
        }
        let finder: StatusPillModel = switch quickAction {
        case .visible: StatusPillModel(tone: .ok, text: "Quick Action vo Findere")
        case .hiddenInFinder: StatusPillModel(tone: .attention, text: "Quick Action skrytá vo Findere")
        case .notInstalled: StatusPillModel(tone: .attention, text: "Quick Action nenainštalovaná")
        }
        return [safari, finder]
    }

    static func ai(mode: AppSettings.AIMode, reviewedPages: Int?) -> [StatusPillModel] {
        let provider: StatusPillModel = switch mode {
        case .builtInOnDevice: StatusPillModel(tone: .ok, text: "Interný režim")
        case .disabled: StatusPillModel(tone: .off, text: "AI vypnutá")
        case .omlxLocal: StatusPillModel(tone: .info, text: "oMLX")
        case .ollamaLocal: StatusPillModel(tone: .info, text: "Ollama")
        case .customAPIKey: StatusPillModel(tone: .info, text: "Vlastné API")
        }
        guard let reviewedPages else { return [provider] }
        return [provider, StatusPillModel(
            tone: .info,
            text: "Skontrolované strany: \(reviewedPages) z \(DetectorTrainingReadiness.firstRunPages)")]
    }
}
```

`AdvocateProfile.displayName` is defined today at the end of `Views/SettingsView.swift`; it is in the same module, so it resolves. Task 6 moves it.

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SettingsStatusTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/Settings/SettingsStatus.swift Chevron7/Tests/Chevron7AppTests/SettingsStatusTests.swift
git commit -m "feat(settings): status pills derived from existing state

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: EZZK connect and disconnect

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/EZZKConnection.swift`
- Test: `Chevron7/Tests/Chevron7AppTests/EZZKConnectionTests.swift`

**Interfaces:**
- Consumes: `AppSettingsStore` (`settings.ezzkMode`, `ezzkAccountController`), `EZZKAccountController.setMode(_:)`, `signIn(login:password:)`, `signOut()`, `state`, `hasStoredCredentials`.
- Produces: `@MainActor enum EZZKConnection` with `static func isConnected(mode: AppSettings.EZZKMode, hasStoredCredentials: Bool) -> Bool`, `enum Result: Equatable { case connected, failed(String) }`, `static func connect(store: AppSettingsStore, login: String, password: String) async -> Result`, `static func disconnect(store: AppSettingsStore)`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class EZZKConnectionTests: XCTestCase {
    private func makeStore(replies: [String], credentials: MemoryCredentialStore = MemoryCredentialStore(),
                           mode: AppSettings.EZZKMode = .demo) -> AppSettingsStore {
        let transport = ScriptedTransport(replies)
        let controller = EZZKAccountController(mode: mode, credentialStore: credentials,
                                               transportFactory: { _ in transport }, productionPolicy: .refused)
        let store = makeSettingsStore(ezzkAccountController: controller)
        store.settings.ezzkMode = mode
        return store
    }

    func testIsConnectedOnlyOnProductionWithCredentials() {
        XCTAssertTrue(EZZKConnection.isConnected(mode: .production, hasStoredCredentials: true))
        XCTAssertFalse(EZZKConnection.isConnected(mode: .production, hasStoredCredentials: false))
        XCTAssertFalse(EZZKConnection.isConnected(mode: .test, hasStoredCredentials: true))
        XCTAssertFalse(EZZKConnection.isConnected(mode: .demo, hasStoredCredentials: true))
    }

    func testSuccessfulConnectLeavesProduction() async throws {
        let credentials = MemoryCredentialStore()
        let store = makeStore(replies: [loginSucceeded], credentials: credentials)

        let result = await EZZKConnection.connect(store: store, login: "ucet", password: "heslo")

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(store.settings.ezzkMode, .production)
        XCTAssertEqual(store.ezzkAccountController.mode, .production)
        XCTAssertEqual(try credentials.load(environment: .production),
                       EZZKSOAPCredentials(login: "ucet", password: "heslo"))
    }

    func testFailedConnectRestoresThePreviousMode() async throws {
        let credentials = MemoryCredentialStore()
        let store = makeStore(replies: [loginRejected], credentials: credentials)

        let result = await EZZKConnection.connect(store: store, login: "ucet", password: "zle")

        XCTAssertEqual(result, .failed("Nesprávne prihlasovacie meno alebo heslo."))
        XCTAssertEqual(store.settings.ezzkMode, .demo)
        XCTAssertEqual(store.ezzkAccountController.mode, .demo)
        XCTAssertNil(try credentials.load(environment: .production))
    }

    func testDisconnectKeepsProductionAndDropsCredentials() throws {
        let credentials = MemoryCredentialStore()
        try credentials.save(EZZKSOAPCredentials(login: "ucet", password: "heslo"), environment: .production)
        let store = makeStore(replies: [], credentials: credentials, mode: .production)
        XCTAssertTrue(store.ezzkAccountController.hasStoredCredentials)

        EZZKConnection.disconnect(store: store)

        XCTAssertEqual(store.settings.ezzkMode, .production)
        XCTAssertEqual(store.ezzkAccountController.mode, .production)
        XCTAssertFalse(store.ezzkAccountController.hasStoredCredentials)
        XCTAssertNil(try credentials.load(environment: .production))
    }

    private let loginSucceeded = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><OutputMessageOf_LogInOutput xmlns="http://ditec/2017/06/iam/core"><Content xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><ErrorCode i:nil="true"/><Account><Id>1</Id><Name>ucet-test</Name></Account><TokenDescriptor>token-1</TokenDescriptor></Content></OutputMessageOf_LogInOutput></s:Body></s:Envelope>"#

    private let loginRejected = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><OutputMessageOf_LogInOutput xmlns="http://ditec/2017/06/iam/core"><Content xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><ErrorCode>CORE-003</ErrorCode><Account i:nil="true"/><TokenDescriptor i:nil="true"/></Content></OutputMessageOf_LogInOutput></s:Body></s:Envelope>"#
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter EZZKConnectionTests`
Expected: FAIL to compile, "cannot find 'EZZKConnection' in scope".

- [ ] **Step 3: Implement**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// The Basic EZZK flow: one account on the live register, no environment picker.
@MainActor
enum EZZKConnection {
    enum Result: Equatable {
        case connected
        case failed(String)
    }

    static func isConnected(mode: AppSettings.EZZKMode, hasStoredCredentials: Bool) -> Bool {
        mode == .production && hasStoredCredentials
    }

    /// Switches to the live register and signs in. A refused login restores the mode the
    /// person had, so a typo never leaves them on production without an account.
    static func connect(store: AppSettingsStore, login: String, password: String) async -> Result {
        let controller = store.ezzkAccountController
        let previous = controller.mode
        store.settings.ezzkMode = .production
        controller.setMode(.production)
        await controller.signIn(login: login, password: password)
        if case .signedIn = controller.state { return .connected }
        let message: String = if case .failed(let text) = controller.state {
            text
        } else {
            "Pripojenie k EZZK sa nepodarilo."
        }
        store.settings.ezzkMode = previous
        controller.setMode(previous)
        return .failed(message)
    }

    /// Drops the saved login and keeps the live register selected: a conversion then
    /// stops with a login error instead of quietly running without legal effect.
    static func disconnect(store: AppSettingsStore) {
        store.ezzkAccountController.signOut()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter EZZKConnectionTests`
Expected: PASS (4 tests). If `testSuccessfulConnectLeavesProduction` fails because the production client refuses `LogIn` under `.refused`, read `EZZKSOAPClient.performLogIn` and `EZZKProductionPolicy`: login is not a consequential call and must be allowed; report the finding instead of changing the policy.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/Settings/EZZKConnection.swift Chevron7/Tests/Chevron7AppTests/EZZKConnectionTests.swift
git commit -m "feat(ezzk): connect to the live register in one step, restore the mode on failure

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Shared view components

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/SettingsComponents.swift`

**Interfaces:**
- Consumes: `SettingsPane` (Task 2), `StatusPillModel` (Task 5).
- Produces:
  - `SettingsIcon(symbol: String, tint: Color, size: CGFloat = 20)`
  - `StatusPill(model: StatusPillModel)`
  - `SettingsPaneHeader(pane: SettingsPane, pills: [StatusPillModel])`
  - `SettingsPaneForm<Content: View>(pane: SettingsPane, pills: [StatusPillModel], @ViewBuilder content: () -> Content)`
  - `AdvancedBadge()`
  - `AdvancedSectionHeader(title: String = "Rozšírené")`
  - `InlineError(message: String)`
  - `extension StatusPillModel.Tone { var symbol: String; var color: Color }`

This task is view code only; it is verified by building (the panes in Tasks 8 to 11 exercise it and Task 13 checks it visually).

- [ ] **Step 1: Implement**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// A white SF Symbol on a tinted rounded square, as System Settings draws its panes.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension StatusPillModel.Tone {
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .off: "minus.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .attention: .orange
        case .off: .secondary
        case .info: .blue
        }
    }
}

/// A tinted capsule, not glass: glass belongs to the navigation layer.
struct StatusPill: View {
    let model: StatusPillModel

    var body: some View {
        Label(model.text, systemImage: model.tone.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(model.tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(model.tone.color.opacity(0.15), in: Capsule())
            .lineLimit(1)
            .accessibilityElement(children: .combine)
    }
}

struct SettingsPaneHeader: View {
    let pane: SettingsPane
    let pills: [StatusPillModel]

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsIcon(symbol: pane.symbol, tint: pane.tint, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                Text(pane.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !pills.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { pillViews }
                        VStack(alignment: .leading, spacing: 4) { pillViews }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var pillViews: some View {
        ForEach(pills.indices, id: \.self) { StatusPill(model: pills[$0]) }
    }
}

/// Every pane: a grouped form whose first group is the header, as in System Settings.
struct SettingsPaneForm<Content: View>: View {
    let pane: SettingsPane
    let pills: [StatusPillModel]
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(pane: pane, pills: pills)
            }
            content()
        }
        .formStyle(.grouped)
    }
}

/// Marks an Advanced setting shown only because it holds a non-default value.
struct AdvancedBadge: View {
    var body: some View {
        Text("Rozšírené")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel("Rozšírené nastavenie")
    }
}

struct AdvancedSectionHeader: View {
    var title = "Rozšírené"

    var body: some View {
        Label(title, systemImage: "slider.horizontal.3")
    }
}

/// An error next to the control that caused it.
struct InlineError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.octagon.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
```

- [ ] **Step 2: Build**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/Settings/SettingsComponents.swift
git commit -m "feat(settings): icon, status pill, pane header and form scaffold

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Profile, Signing and General panes

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/ProfileSettingsPane.swift`
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/SigningSettingsPane.swift`
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/GeneralSettingsPane.swift`
- Modify: `Chevron7/Sources/Chevron7App/Views/SettingsView.swift` (move `extension AdvocateProfile { var displayName }` out of it, lines 1271-1275)

**Interfaces:**
- Consumes: `SettingsPaneForm`, `AdvancedBadge`, `AdvancedSectionHeader`, `InlineError` (Task 7); `SettingsStatus.profile`, `SettingsStatus.signing` (Task 5); `SettingsAdvancedState.customTSAIsActive` (Task 3).
- Produces: `ProfileSettingsPane(settingsStore: AppSettingsStore)`, `SigningSettingsPane(settingsStore: AppSettingsStore, showAdvanced: Bool)`, `GeneralSettingsPane(settingsStore: AppSettingsStore)`; `AdvocateProfile.displayName` now lives in `ProfileSettingsPane.swift`.

The old `SettingsView` keeps its own tab code until Task 12; these panes are new types beside it.

- [ ] **Step 1: Profile pane**

Delete the `extension AdvocateProfile` block (lines 1271-1275) from `Views/SettingsView.swift` and create `ProfileSettingsPane.swift`:

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

extension AdvocateProfile {
    var displayName: String {
        fullName.isEmpty ? officeName : fullName
    }
}

struct ProfileSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    @State private var editingID: UUID?
    @State private var profileToDelete: UUID?

    private var profiles: [AdvocateProfile] { settingsStore.settings.profiles }
    private var activeID: UUID? { settingsStore.settings.activeProfileID }

    var body: some View {
        SettingsPaneForm(pane: .profile, pills: SettingsStatus.profile(settingsStore.settings)) {
            Section("Profily") {
                if profiles.isEmpty {
                    Text("Pridajte profil s údajmi advokáta. Použije sa v doložke aj v zázname o konverzii.")
                        .foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
                HStack(spacing: 8) {
                    Button { addProfile() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Pridať profil")
                    Button {
                        profileToDelete = editingID
                    } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Odstrániť profil")
                        .disabled(editingID == nil || profiles.count < 2)
                    Spacer()
                    if let editingID, editingID != activeID {
                        Button("Nastaviť ako aktívny") {
                            settingsStore.settings.activeProfileID = editingID
                        }
                    }
                }
                .buttonStyle(.borderless)
            }

            if let index = profiles.firstIndex(where: { $0.id == editingID }) {
                Section("Údaje profilu") {
                    TextField("Meno a priezvisko", text: $settingsStore.settings.profiles[index].fullName,
                              prompt: Text("JUDr. Meno Priezvisko"))
                    TextField("Funkcia", text: $settingsStore.settings.profiles[index].position,
                              prompt: Text("advokát"))
                    TextField("Evidenčné číslo SAK", text: $settingsStore.settings.profiles[index].registrationNumber,
                              prompt: Text("1234"))
                    TextField("IČO kancelárie", text: $settingsStore.settings.profiles[index].ico,
                              prompt: Text("IČO"))
                    TextField("Názov kancelárie", text: $settingsStore.settings.profiles[index].officeName,
                              prompt: Text("Advokátska kancelária…"))
                    TextField("Adresa kancelárie", text: $settingsStore.settings.profiles[index].officeAddress,
                              prompt: Text("Ulica, PSČ a mesto"))
                    Toggle("Právnická osoba (kancelária)", isOn: $settingsStore.settings.profiles[index].isLegalEntity)
                }
            }
        }
        .onAppear { editingID = editingID ?? activeID ?? profiles.first?.id }
        .confirmationDialog("Naozaj chcete odstrániť tento profil?",
                            isPresented: Binding(get: { profileToDelete != nil },
                                                 set: { if !$0 { profileToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Odstrániť profil", role: .destructive) { deleteProfile() }
            Button("Zrušiť", role: .cancel) { profileToDelete = nil }
        } message: {
            Text("Profil a jeho údaje budú odstránené z tejto aplikácie.")
        }
    }

    private func profileRow(_ profile: AdvocateProfile) -> some View {
        let isActive = profile.id == activeID
        let isEditing = profile.id == editingID
        return Button {
            editingID = profile.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isEditing ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName.isEmpty ? "Nový profil" : profile.displayName)
                    if !profile.officeName.isEmpty, profile.officeName != profile.displayName {
                        Text(profile.officeName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isActive {
                    StatusPill(model: StatusPillModel(tone: .ok, text: "Aktívny"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isEditing ? .isSelected : [])
    }

    private func addProfile() {
        let profile = AdvocateProfile()
        settingsStore.settings.profiles.append(profile)
        if settingsStore.settings.activeProfileID == nil {
            settingsStore.settings.activeProfileID = profile.id
        }
        editingID = profile.id
    }

    private func deleteProfile() {
        guard let id = profileToDelete else { return }
        settingsStore.settings.profiles.removeAll { $0.id == id }
        if settingsStore.settings.activeProfileID == id {
            settingsStore.settings.activeProfileID = settingsStore.settings.profiles.first?.id
        }
        editingID = settingsStore.settings.activeProfileID
        profileToDelete = nil
    }
}
```

- [ ] **Step 2: Signing pane**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

struct SigningSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    @State private var newTSAURL = ""
    @State private var tsaTestStatus: String?
    @State private var tsaTestFailed = false
    @State private var isTestingTSA = false
    @State private var tsaToDelete: String?

    var body: some View {
        let settings = settingsStore.settings
        let customActive = SettingsAdvancedState.customTSAIsActive(settings)
        SettingsPaneForm(pane: .signing, pills: SettingsStatus.signing(settings)) {
            Section {
                Picker("Aktívna TSA", selection: $settingsStore.settings.selectedTSAURL) {
                    ForEach(settings.availableTSAServers) { server in
                        Text(server.name).tag(server.url)
                    }
                }
                LabeledContent("Adresa") {
                    Text(settings.activeTSA.url)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button {
                        testTSAConnection()
                    } label: {
                        if isTestingTSA {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Otestovať spojenie", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(isTestingTSA || settings.selectedTSAURL.isEmpty)
                    Spacer()
                    if let tsaTestStatus {
                        if tsaTestFailed {
                            InlineError(message: tsaTestStatus)
                        } else {
                            Label(tsaTestStatus, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            } header: {
                Label("Časová pečiatka", systemImage: "clock.badge.checkmark")
            } footer: {
                if settings.activeTSAQualificationIsUnverified {
                    Label(TimestampAuthority.unverifiedQualificationWarning,
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Režim PDF/A", selection: $settingsStore.settings.pdfaMode) {
                    ForEach(PDFAConversionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Label("PDF/A", systemImage: "doc.badge.gearshape")
            } footer: {
                Text("Vektorová konverzia zachováva textovú vrstvu; rasterizovaná garancia (200 dpi) vyrovná problematické skeny. Obe spĺňajú PDF/A-2b.")
            }

            if showAdvanced || customActive {
                Section {
                    ForEach(settings.customTSAServers, id: \.self) { server in
                        HStack {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                            Text(server).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            if !showAdvanced, server == settings.selectedTSAURL { AdvancedBadge() }
                            Button(role: .destructive) {
                                tsaToDelete = server
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Odstrániť TSA server")
                        }
                    }
                    HStack {
                        TextField("Nový server", text: $newTSAURL, prompt: Text("https://vlastna-tsa.sk/tsp"))
                        Button("Pridať") { addTSA() }
                            .disabled(newTSAURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    AdvancedSectionHeader(title: "Vlastné TSA servery")
                }
            }
        }
        .confirmationDialog("Naozaj chcete odstrániť tento TSA server?",
                            isPresented: Binding(get: { tsaToDelete != nil },
                                                 set: { if !$0 { tsaToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Odstrániť TSA server", role: .destructive) { deleteTSA() }
            Button("Zrušiť", role: .cancel) { tsaToDelete = nil }
        } message: {
            Text("Server bude odstránený zo zoznamu vlastných TSA služieb.")
        }
    }

    private func addTSA() {
        let trimmed = newTSAURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settingsStore.settings.customTSAServers.contains(trimmed) else { return }
        settingsStore.settings.customTSAServers.append(trimmed)
        newTSAURL = ""
    }

    private func deleteTSA() {
        guard let server = tsaToDelete else { return }
        settingsStore.settings.customTSAServers.removeAll { $0 == server }
        if settingsStore.settings.selectedTSAURL == server {
            settingsStore.settings.selectedTSAURL = TimestampAuthority.legacyDefaultURL
        }
        tsaToDelete = nil
    }

    private func testTSAConnection() {
        isTestingTSA = true
        tsaTestStatus = nil
        let urlString = settingsStore.settings.selectedTSAURL
        Task {
            defer { isTestingTSA = false }
            guard let url = URL(string: urlString), url.scheme != nil else {
                tsaTestFailed = true
                tsaTestStatus = "Neplatná adresa TSA."
                return
            }
            do {
                let reply = try await RFC3161TimestampClient()
                    .requestToken(for: Data("chevron7-tsa-connectivity-test".utf8), tsaURL: url)
                tsaTestFailed = false
                if let time = reply.genTime {
                    tsaTestStatus = "Pečiatka prijatá (\(AttestationClauseGenerator.isoFormatter.string(from: time)))"
                } else {
                    tsaTestStatus = "Token prijatý (\(reply.token.count) B)."
                }
            } catch {
                tsaTestFailed = true
                tsaTestStatus = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 3: General pane**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore

    var body: some View {
        SettingsPaneForm(pane: .general, pills: []) {
            Section {
                Toggle("Pamätať naposledy otvorené dokumenty", isOn: $settingsStore.settings.retainRecentDocuments)
            } header: {
                Label("Naposledy otvorené dokumenty", systemImage: "clock.arrow.circlepath")
            } footer: {
                Text("Uloží najviac osem bezpečných bookmarkov pre rýchly návrat po reštarte. Obsah dokumentov sa do zoznamu neukladá.")
            }
        }
    }
}
```

- [ ] **Step 4: Build and run the related tests**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter 'SettingsStatusTests|SettingsAdvancedStateTests'`
Expected: `Build complete!` and PASS. If `AdvocateProfile` fields differ from `fullName, position, registrationNumber, ico, officeName, officeAddress, isLegalEntity`, use the names from `Chevron7Kit` (they are the ones the old profiles tab bound to).

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/Settings/ProfileSettingsPane.swift Chevron7/Sources/Chevron7App/Views/Settings/SigningSettingsPane.swift Chevron7/Sources/Chevron7App/Views/Settings/GeneralSettingsPane.swift Chevron7/Sources/Chevron7App/Views/SettingsView.swift
git commit -m "feat(settings): profile, signing and general panes as grouped forms

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: EZZK pane

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/EZZKSettingsPane.swift`

**Interfaces:**
- Consumes: `EZZKConnection` (Task 6), `SettingsStatus.ezzk` (Task 5), `SettingsAdvancedState.ezzkModeIsActive` (Task 3), components (Task 7), `EZZKAccountController` (`mode`, `state`, `isDemoMode`, `environment`, `hasStoredCredentials`, `storedLogin`, `productionPolicy`, `setMode`, `signIn`, `signOut`, `lookUp(evidenceNumber:)`, `message(for:)`), `AppSettingsStore.requestTestNumbersIntoPool()`.
- Produces: `EZZKSettingsPane(settingsStore: AppSettingsStore, showAdvanced: Bool)`.

Account section rules:
- Mode `.test`: the old sign in ("Prihlásiť a overiť" / "Odhlásiť") in the current mode.
- Mode `.demo` or `.production` without credentials: "Pripojiť k EZZK" (`.glassProminent`), confirmation first, then `EZZKConnection.connect`.
- Mode `.production` with credentials: connected rows and "Odpojiť".
- "Overiť" from the spec is not built: the controller has no way to re-verify a saved login without the password; the state row already shows "Overené: účet, čas" after a sign in. "Otvoriť register" is not built: no deep link into the main window exists (spec non-goal).

- [ ] **Step 1: Implement**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

struct EZZKSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    @State private var loginField = ""
    @State private var passwordField = ""
    @State private var connectError: String?
    @State private var isConnecting = false
    @State private var showConnectConfirmation = false
    @State private var lookupNumber = ""
    @State private var lookupResult: EZZKRecordLookup?
    @State private var lookupError: String?
    @State private var lookupInProgress = false
    @State private var testNumbers: [String] = []
    @State private var numbersError: String?
    @State private var numbersInProgress = false
    @State private var showNumbersConfirmation = false

    private var controller: EZZKAccountController { settingsStore.ezzkAccountController }
    private var isConnected: Bool {
        EZZKConnection.isConnected(mode: controller.mode, hasStoredCredentials: controller.hasStoredCredentials)
    }
    private var productionAllowed: Bool { controller.productionPolicy.allowsConsequentialCalls }

    var body: some View {
        let modeActive = SettingsAdvancedState.ezzkModeIsActive(settingsStore.settings)
        SettingsPaneForm(pane: .ezzk, pills: SettingsStatus.ezzk(
            mode: controller.mode, state: controller.state,
            hasStoredCredentials: controller.hasStoredCredentials, productionAllowed: productionAllowed)) {
            if showAdvanced || modeActive {
                modeSection(showsBadge: !showAdvanced)
            }
            accountSection
            if controller.mode == .test || isConnected {
                submissionSection
            }
            if showAdvanced {
                if !controller.isDemoMode {
                    lookupSection
                    numbersSection
                }
                migrationSection
            }
        }
        .onAppear { loginField = controller.storedLogin }
        .onChange(of: controller.mode) { _, _ in
            loginField = controller.storedLogin
            passwordField = ""
            lookupResult = nil
            lookupError = nil
            testNumbers = []
            numbersError = nil
        }
        .confirmationDialog("Pripojiť k ostrej evidencii EZZK?", isPresented: $showConnectConfirmation,
                            titleVisibility: .visible) {
            Button("Pripojiť") { connect() }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Od tejto chvíle sa evidenčné čísla aj záznamy o konverzii zapisujú do centrálnej evidencie s právnymi účinkami.")
        }
        .confirmationDialog("Vyžiadať evidenčné čísla z testovacieho EZZK?", isPresented: $showNumbersConfirmation,
                            titleVisibility: .visible) {
            Button("Vyžiadať čísla") { Task { await requestTestNumbers() } }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Testovacie EZZK vráti nespotrebované čísla osoby a podľa potreby pridelí nové.")
        }
    }

    // MARK: - Basic

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if isConnected {
                LabeledContent("Prihlasovacie meno", value: controller.storedLogin)
                LabeledContent("Heslo") {
                    Label("v Keychaine", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
            } else {
                TextField("Prihlasovacie meno", text: $loginField, prompt: Text("z registračného e-mailu EZZK"))
                    .textContentType(.username)
                SecureField("Heslo", text: $passwordField,
                            prompt: Text(controller.hasStoredCredentials ? "uložené v Keychaine" : "heslo do EZZK"))
                    .textContentType(.password)
            }
            TextField("Názov osoby", text: $settingsStore.settings.ezzkPersonName, prompt: Text("presne ako v doložke"))
            TextField("IČO", text: $settingsStore.settings.ezzkICO, prompt: Text("IČO osoby"))
            stateRow
            accountButtons
            if let connectError {
                InlineError(message: connectError)
            } else if case .failed(let message) = controller.state {
                InlineError(message: message)
            }
        } header: {
            Label("Účet EZZK", systemImage: "person.badge.key")
        } footer: {
            Text("Heslo sa uloží iba do Keychainu tohto Macu, a to až po úspešnom overení v EZZK.")
        }
    }

    @ViewBuilder
    private var stateRow: some View {
        switch controller.state {
        case .verifying:
            Label("Overuje sa v EZZK", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .signedIn(let accountName, let checkedAt):
            Label("Overené: \(accountName), \(checkedAt.formatted(date: .omitted, time: .shortened))",
                  systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .signedOut, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var accountButtons: some View {
        HStack {
            Spacer()
            if controller.mode == .test {
                if controller.hasStoredCredentials {
                    Button("Odhlásiť", role: .destructive) { signOut() }
                }
                Button("Prihlásiť a overiť") { signInInCurrentMode() }
                    .disabled(controller.state == .verifying || loginField.isEmpty || passwordField.isEmpty)
            } else if isConnected {
                Button("Odpojiť", role: .destructive) {
                    EZZKConnection.disconnect(store: settingsStore)
                    loginField = controller.storedLogin
                    passwordField = ""
                }
            } else {
                Button {
                    connectError = nil
                    showConnectConfirmation = true
                } label: {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Pripojiť k EZZK", systemImage: "link")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isConnecting || loginField.isEmpty || passwordField.isEmpty)
            }
        }
    }

    private var submissionSection: some View {
        let status = submissionStatus
        return Section {
            Label(status.title, systemImage: status.symbol)
        } header: {
            Label("Odosielanie záznamov", systemImage: "arrow.up.doc")
        } footer: {
            Text(status.detail)
        }
    }

    private var submissionStatus: (title: String, symbol: String, detail: String) {
        switch controller.mode {
        case .demo:
            ("Lokálna simulácia", "desktopcomputer",
             "Podpísaný záznam o konverzii sa vytvorí, ale do EZZK sa neodošle.")
        case .test:
            ("Zapnuté automaticky", "checkmark.circle",
             "Po autorizácii sa záznam podpíše rovnakým PIN a odošle do testovacieho EZZK. Výsledok je v Registri konverzií.")
        case .production where productionAllowed:
            ("Zapnuté automaticky", "checkmark.circle",
             "Po autorizácii sa záznam podpíše rovnakým PIN a odošle do EZZK. Čakajúce záznamy sa overujú každých päť minút; výsledok je v Registri konverzií.")
        case .production:
            ("Zamknuté", "lock",
             "Pridelenie čísla aj odoslanie záznamu sú v tejto verzii zamknuté.")
        }
    }

    // MARK: - Advanced

    private func modeSection(showsBadge: Bool) -> some View {
        Section {
            Picker("Prostredie", selection: Binding(
                get: { controller.mode },
                set: { newMode in
                    settingsStore.settings.ezzkMode = newMode
                    controller.setMode(newMode)
                })) {
                ForEach(AppSettings.EZZKMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .disabled(controller.state == .verifying || lookupInProgress || numbersInProgress || isConnecting)
            if let environment = controller.environment {
                LabeledContent("Prihlásenie") { endpoint(environment.soapLoginURL.absoluteString) }
                LabeledContent("Služba") { endpoint(environment.soapServiceURL.absoluteString) }
            }
        } header: {
            HStack {
                AdvancedSectionHeader(title: "Prostredie EZZK")
                if showsBadge { AdvancedBadge() }
            }
        } footer: {
            Text(modeExplanation)
        }
    }

    private var modeExplanation: String {
        switch controller.mode {
        case .demo: "Skúšobný režim používa iba lokálnu simuláciu, nič sa neposiela do EZZK."
        case .test: "Testovacia evidencia EZZK na overenie integrácie. Čísla ani záznamy nemajú právne účinky."
        case .production where productionAllowed:
            "Ostrá evidencia: čísla aj záznamy majú právne účinky. Každá konverzia sa zapíše do centrálnej evidencie."
        case .production: "Ostrá evidencia. Zatiaľ iba overenie prihlásenia, čas servera a vyhľadanie záznamu."
        }
    }

    private func endpoint(_ value: String) -> some View {
        Text(value)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    private var lookupSection: some View {
        Section {
            HStack {
                TextField("Evidenčné číslo", text: $lookupNumber)
                    .onSubmit { lookUpRecord() }
                Button("Vyhľadať") { lookUpRecord() }
                    .disabled(lookupInProgress || lookupNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if lookupInProgress {
                ProgressView().controlSize(.small)
            } else if let lookupError {
                InlineError(message: lookupError)
            } else if let lookup = lookupResult {
                if !lookup.isProcessed {
                    Label("Záznam je evidovaný, ale ešte nespracovaný.", systemImage: "hourglass")
                        .foregroundStyle(.orange)
                }
                if let info = lookup.info {
                    infoRow("Číslo", info.evidenceNumber)
                    infoRow("Konverzia", info.executionTime?.formatted(date: .abbreviated, time: .standard))
                    infoRow("Prijaté", info.receiptTime?.formatted(date: .abbreviated, time: .standard))
                    infoRow("Osoba", info.personName)
                    infoRow("Pôvodný", documentSummary(info.originalDocumentName, info.originalDocumentFormat,
                                                       info.originalDocumentSheets))
                    infoRow("Nový", documentSummary(info.newDocumentName, info.newDocumentFormat,
                                                    info.newDocumentSheets))
                }
            }
        } header: {
            AdvancedSectionHeader(title: "Overenie záznamu")
        } footer: {
            Text("Overenie nepotrebuje prihlásenie a v EZZK nič nemení.")
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) { Text(value).textSelection(.enabled) }
        }
    }

    private func documentSummary(_ name: String?, _ format: String?, _ sheets: Int?) -> String {
        [name, format, sheets.map { "listov: \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    private var numbersSection: some View {
        Section {
            if controller.mode == .production {
                // "Vyžiadať čísla" stays test only whatever the production policy: a production
                // number no record uses lapses at midnight and breaks the 24-hour reporting duty.
                Label(productionAllowed
                      ? "V ostrej evidencii sa evidenčné číslo získava iba v zaručenej konverzii."
                      : "V ostrej evidencii je pridelenie evidenčného čísla zatiaľ zamknuté, aj v zaručenej konverzii.",
                      systemImage: "lock")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Vyžiadať čísla") { showNumbersConfirmation = true }
                        .disabled(numbersInProgress || !controller.hasStoredCredentials)
                    if numbersInProgress { ProgressView().controlSize(.small) }
                }
                if let numbersError {
                    InlineError(message: numbersError)
                } else if !testNumbers.isEmpty {
                    Text(testNumbers.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            AdvancedSectionHeader(title: "Evidenčné čísla")
        } footer: {
            if controller.mode != .production {
                Text("Vyžaduje uložené prihlásenie, názov osoby a IČO.")
            }
        }
    }

    private var migrationSection: some View {
        Section {
            TextField("Notifikačný e-mail", text: $settingsStore.settings.ezzkNotificationEmail,
                      prompt: Text("advokat@kancelaria.sk"))
            TextField("Adresa eDesk", text: $settingsStore.settings.ezzkEdeskAddress,
                      prompt: Text("elektronická schránka"))
        } header: {
            AdvancedSectionHeader(title: "Kontaktné údaje pre migráciu")
        } footer: {
            Text("Slúžia iba na migráciu historických záznamov. Na prihlásenie sa nepoužívajú.")
        }
    }

    // MARK: - Actions

    private func connect() {
        let login = loginField
        let password = passwordField
        isConnecting = true
        connectError = nil
        Task {
            let result = await EZZKConnection.connect(store: settingsStore, login: login, password: password)
            isConnecting = false
            switch result {
            case .connected:
                passwordField = ""
            case .failed(let message):
                connectError = message
            }
        }
    }

    private func signInInCurrentMode() {
        let login = loginField
        let password = passwordField
        Task {
            await controller.signIn(login: login, password: password)
            if case .signedIn = controller.state { passwordField = "" }
        }
    }

    private func signOut() {
        controller.signOut()
        // A failed sign-out keeps the stored login, so keep showing it.
        loginField = controller.storedLogin
        passwordField = ""
    }

    private func lookUpRecord() {
        let number = lookupNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty, !lookupInProgress else { return }
        let requestedMode = controller.mode
        lookupInProgress = true
        lookupError = nil
        lookupResult = nil
        Task {
            defer { lookupInProgress = false }
            do {
                let result = try await controller.lookUp(evidenceNumber: number)
                if controller.mode == requestedMode { lookupResult = result }
            } catch {
                if controller.mode == requestedMode { lookupError = EZZKAccountController.message(for: error) }
            }
        }
    }

    private func requestTestNumbers() async {
        let requestedMode = controller.mode
        numbersInProgress = true
        numbersError = nil
        defer { numbersInProgress = false }
        do {
            let numbers = try await settingsStore.requestTestNumbersIntoPool()
            if controller.mode == requestedMode { testNumbers = numbers }
        } catch {
            if controller.mode == requestedMode { numbersError = EZZKAccountController.message(for: error) }
        }
    }
}
```

- [ ] **Step 2: Build and run the EZZK tests**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter 'EZZKConnectionTests|EZZKAccountControllerTests'`
Expected: `Build complete!` and PASS. If `.buttonStyle(.glassProminent)` is unavailable in the SDK, the toolchain is not Xcode 27: stop and report instead of substituting a style.

- [ ] **Step 3: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/Settings/EZZKSettingsPane.swift
git commit -m "feat(settings): EZZK pane with one-step connect and Advanced environment

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Mobile and eIdentita pane

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/EidentitaSetupSheet.swift`
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/MobileSettingsPane.swift`

**Interfaces:**
- Consumes: `AGPKeyStore`, `AGPTokenMinter`, `AGPClient`, `AGPError` (`Chevron7Kit`), `SettingsStatus.mobile`, `SettingsAdvancedState.avmServerIsActive`, `agpPortalIsActive`, components.
- Produces: `EidentitaSetupSheet(settingsStore: AppSettingsStore, onClose: () -> Void)` with `static let steps: [String]`; `MobileSettingsPane(settingsStore: AppSettingsStore, showAdvanced: Bool)`; `enum EidentitaKey { static func isStored() -> Bool }`.

- [ ] **Step 1: Setup sheet**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Kit
import CryptoKit
import SwiftUI

enum EidentitaKey {
    /// A key in the Keychain that decodes; the display is derived from it, never regenerated.
    static func isStored() -> Bool {
        guard let raw = try? AGPKeyStore().loadPrivateKey() else { return false }
        return (try? P256.Signing.PrivateKey(rawRepresentation: raw)) != nil
    }
}

/// The portal-side eIdentita setup, kept out of the pane so the pane shows only status.
struct EidentitaSetupSheet: View {
    @Bindable var settingsStore: AppSettingsStore
    let onClose: () -> Void
    @State private var keyStored = false
    @State private var publicPEM = ""
    @State private var error: String?
    @State private var busy = false
    @State private var verified = false

    /// The portal-side setup, as the Autogram Portal's organization settings show it
    /// since its tenants (2026-09-30).
    static let steps = [
        "Prihláste sa na portál Autogram z poľa Portál a otvorte Nastavenia. Predvolený je testovací portál, kde Slovensko.Digital dnes sprístupňuje API; ostrý portál je agp.slovensko.digital.",
        "Ak pod poľom „Verejný kľúč API tokenu“ stojí, že API prístup nie je zapnutý, požiadajte Slovensko.Digital o jeho zapnutie pre vašu organizáciu. Kľúč vkladá vlastník organizácie.",
        "Tu kliknite na „Vygenerovať kľúč“, skopírujte verejný kľúč, vložte ho na portáli do poľa „Verejný kľúč API tokenu“ a kliknite na Uložiť.",
        "Do poľa ID organizácie prepíšte číslo z vety pod tým poľom na portáli: „V tokene použite sub = …“.",
        "Kliknite na „Overiť“. Pri podpise potom vyberte Podpísať mobilom a eIdentitu.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "person.badge.key.fill", tint: .orange, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nastaviť eIdentitu").font(.title3.weight(.semibold))
                            Text("Podpis cez portál Autogram: QR kód z portálu naskenujete aplikáciou eIDENTITA.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Postup") {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        Label {
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "\(index + 1).circle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                Section("Portál") {
                    TextField("Portál", text: $settingsStore.settings.agpBaseURL,
                              prompt: Text(AGPClient.defaultBaseURL.absoluteString))
                    TextField("ID organizácie", text: $settingsStore.settings.agpUserID,
                              prompt: Text("číslo „sub“ z Nastavení na portáli"))
                }
                Section {
                    HStack {
                        Button(keyStored ? "Vygenerovať nový kľúč" : "Vygenerovať kľúč") { generateKey() }
                        Button("Overiť") { verify() }
                            .disabled(!keyStored)
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        if verified {
                            Label("Overené", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                    }
                    .disabled(busy)
                    if !publicPEM.isEmpty {
                        Text(publicPEM)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(publicPEM, forType: .string)
                        } label: {
                            Label("Skopírovať verejný kľúč", systemImage: "doc.on.doc")
                        }
                    }
                    if let error { InlineError(message: error) }
                } header: {
                    Text("Kľúč")
                } footer: {
                    Text("Súkromný kľúč žije iba v Keychaine tohto Macu. Token sa razí nanovo pre každý request a platí pár minút.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Hotovo") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .padding()
        }
        .frame(width: 560, height: 620)
        .onAppear { loadKey() }
    }

    private func loadKey() {
        if let raw = try? AGPKeyStore().loadPrivateKey(),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            keyStored = true
            publicPEM = AGPTokenMinter.spkiPEM(publicKey: key.publicKey)
        } else {
            keyStored = false
            publicPEM = ""
        }
    }

    private func generateKey() {
        busy = true
        error = nil
        verified = false
        Task {
            do {
                let key = AGPTokenMinter.generateKey()
                try AGPKeyStore().savePrivateKey(Data(key.rawRepresentation))
                publicPEM = AGPTokenMinter.spkiPEM(publicKey: key.publicKey)
                keyStored = true
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func verify() {
        busy = true
        error = nil
        verified = false
        Task {
            do {
                let client = try AGPClient.configured(
                    userID: settingsStore.settings.agpUserID,
                    baseURL: settingsStore.settings.agpBaseURLValue,
                    keyStore: AGPKeyStore())
                guard try await client.verifyToken() else { throw AGPError.invalidResponse }
                verified = true
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
```

- [ ] **Step 2: Mobile pane**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

struct MobileSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    @State private var keyStored = false
    @State private var showSetup = false

    var body: some View {
        let settings = settingsStore.settings
        let avmActive = SettingsAdvancedState.avmServerIsActive(settings)
        let portalActive = SettingsAdvancedState.agpPortalIsActive(settings)
        let pills = SettingsStatus.mobile(mobileSigningEnabled: settings.mobileSigningEnabled,
                                          eidentitaKeyStored: keyStored, eidentitaUserID: settings.agpUserID)
        SettingsPaneForm(pane: .mobile, pills: pills) {
            Section {
                Toggle("Ponúkať podpis občianskym preukazom s NFC cez iPhone",
                       isOn: $settingsStore.settings.mobileSigningEnabled)
            } header: {
                Label("Autogram v mobile", systemImage: "iphone.gen3.radiowaves.left.and.right")
            } footer: {
                Text("Dokument sa zašifruje kľúčom, ktorý pozná len tento Mac, nahrá sa na server Slovensko.Digital a po naskenovaní QR kódu ho podpíšete v aplikácii Autogram v mobile. Server dokument zmaže do 24 hodín.")
            }

            Section {
                LabeledContent("Stav") {
                    if let eidentita = pills.last { StatusPill(model: eidentita) }
                }
                HStack {
                    Spacer()
                    Button("Nastaviť eIdentitu…") { showSetup = true }
                        .disabled(!settings.mobileSigningEnabled)
                }
            } header: {
                Label("eIdentita (štátna aplikácia)", systemImage: "person.badge.key")
            } footer: {
                Text("Dokument sa nahrá do vášho balíka na portáli Autogram, QR kód naskenujete aplikáciou eIDENTITA a podpísaný dokument sa stiahne späť.")
            }

            if showAdvanced || avmActive || portalActive {
                Section {
                    if showAdvanced || avmActive {
                        HStack {
                            TextField("Server Autogram v mobile", text: $settingsStore.settings.avmBaseURL,
                                      prompt: Text(AVMClient.publicBaseURL.absoluteString))
                            if !showAdvanced { AdvancedBadge() }
                        }
                    }
                    if showAdvanced || portalActive {
                        HStack {
                            TextField("Portál eIdentity", text: $settingsStore.settings.agpBaseURL,
                                      prompt: Text(AGPClient.defaultBaseURL.absoluteString))
                            if !showAdvanced { AdvancedBadge() }
                        }
                    }
                    if showAdvanced, keyStored {
                        Button("Odstrániť kľúč eIdentity", role: .destructive) {
                            try? AGPKeyStore().delete()
                            keyStored = EidentitaKey.isStored()
                        }
                    }
                } header: {
                    AdvancedSectionHeader()
                } footer: {
                    Text("Aplikácia Autogram v mobile otvára len odkazy z autogram.slovensko.digital. Iný server je určený len na testovanie.")
                }
            }
        }
        .onAppear { keyStored = EidentitaKey.isStored() }
        .sheet(isPresented: $showSetup, onDismiss: { keyStored = EidentitaKey.isStored() }) {
            EidentitaSetupSheet(settingsStore: settingsStore) { showSetup = false }
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build`
Expected: `Build complete!` (the old `MobileSigningCard` still exists beside the new types; no name clash because the new types have different names).

- [ ] **Step 4: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/Settings/EidentitaSetupSheet.swift Chevron7/Sources/Chevron7App/Views/Settings/MobileSettingsPane.swift
git commit -m "feat(settings): mobile pane with eIdentita status and a setup sheet

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Browser and Finder pane, AI pane

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/BrowserFinderSettingsPane.swift`
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/AISettingsPane.swift`
- Modify: `Chevron7/Sources/Chevron7App/Views/SettingsView.swift` (move `enum AIPromptPreset` lines 11-37 and `enum LearningCardText` lines 1277-1286 into `AISettingsPane.swift`)

**Interfaces:**
- Consumes: `WebBridgeAgentService` (`currentStatus()`, `registerNow()`, `retireLegacyAgent()`, `openLoginItemsSettings()`, `Status`), `FinderQuickActionService` (`installQuickAction()`, `refreshServicesCache()`, `currentVisibility()`, `menuTitle`), `ExampleBank` (`entries()`, `reviewedPages()`, `removeAll()`, `directory`), `CreateMLExporter`, `DetectorTrainingReadiness`, `TrainingState`, `ModelRegistry`, `ModelMetadata`, `ModelTransfer`, `DetectorTrainingWindow.id`, `KeychainStore`, `SystemLanguageModel`, `SettingsStatus.browserFinder`, `SettingsStatus.ai`, `SettingsAdvancedState` web signing and AI predicates, components.
- Produces: `BrowserFinderSettingsPane(settingsStore: AppSettingsStore, showAdvanced: Bool)`, `FinderGuideSheet(onClose: () -> Void)`, `AISettingsPane(settingsStore: AppSettingsStore, showAdvanced: Bool, waitForLearningWrites: @MainActor () async -> Void)`, `AIPromptPreset` and `LearningCardText` moved unchanged.

- [ ] **Step 1: Browser and Finder pane**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Kit
import SwiftUI

struct BrowserFinderSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    @State private var agentStatus: WebBridgeAgentService.Status = .notRegistered
    @State private var quickAction: QuickActionVisibility = .notInstalled
    @State private var finderMessage: String?
    @State private var showFinderGuide = false

    private var resolvedFolder: String {
        let configured = settingsStore.settings.webSigningOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? settingsStore.outputDirectory.path : (configured as NSString).expandingTildeInPath
    }

    var body: some View {
        let settings = settingsStore.settings
        let folderActive = SettingsAdvancedState.webSigningFolderIsActive(settings)
        let retentionActive = SettingsAdvancedState.webSigningRetentionIsActive(settings)
        SettingsPaneForm(pane: .browserFinder,
                         pills: SettingsStatus.browserFinder(agent: agentStatus, quickAction: quickAction)) {
            Section {
                agentStatusRow
                Toggle("Ukladať podpísané dokumenty aj lokálne", isOn: $settingsStore.settings.webSigningSavesLocally)
            } header: {
                Label("Safari", systemImage: "safari")
            } footer: {
                Text("Podpis z prehliadača sa vracia stránke. Bez lokálnej kópie po ňom na Macu nezostane súbor, ktorý by sa dal neskôr overiť.")
            }

            Section {
                LabeledContent("Quick Action") {
                    Text(quickActionText).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Ako aktivovať vo Findere…") { showFinderGuide = true }
                    Spacer()
                    if quickAction != .visible {
                        Button("Nainštalovať Quick Action") { install() }
                            .buttonStyle(.glassProminent)
                    }
                }
                if let finderMessage {
                    Text(finderMessage).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Label("Finder", systemImage: "folder")
            } footer: {
                Text("Podpíše označené PDF priamo z Findera (PAdES s kvalifikovanou časovou pečiatkou) bez otvorenia hlavného okna.")
            }

            if showAdvanced || folderActive || retentionActive {
                Section {
                    if showAdvanced || folderActive {
                        HStack {
                            TextField("Priečinok kópií", text: $settingsStore.settings.webSigningOutputPath,
                                      prompt: Text("Predvolený priečinok aplikácie"))
                            Button("Vybrať…") { chooseFolder() }
                            if !showAdvanced { AdvancedBadge() }
                        }
                        .disabled(!settings.webSigningSavesLocally)
                        LabeledContent("Aktuálne") {
                            Text(resolvedFolder).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if showAdvanced || retentionActive {
                        HStack {
                            Picker("Presunúť kópie do Koša", selection: $settingsStore.settings.webSigningRetentionDays) {
                                Text("Nikdy").tag(0)
                                Text("Po 7 dňoch").tag(7)
                                Text("Po 30 dňoch").tag(30)
                                Text("Po 90 dňoch").tag(90)
                            }
                            if !showAdvanced { AdvancedBadge() }
                        }
                        .disabled(!settings.webSigningSavesLocally)
                    }
                    if showAdvanced {
                        Button("Obnoviť služby macOS") {
                            finderMessage = FinderQuickActionService.refreshServicesCache()
                                ? "Registrácia služieb bola odoslaná systému macOS."
                                : "Registráciu služieb sa nepodarilo obnoviť."
                            quickAction = FinderQuickActionService.currentVisibility()
                        }
                    }
                } header: {
                    AdvancedSectionHeader()
                } footer: {
                    Text("Kôš sa týka iba kópií podpisov z prehliadača. Dokumenty podpísané v aplikácii zostávajú, kde ste ich uložili.")
                }
            }
        }
        .onAppear {
            agentStatus = WebBridgeAgentService.currentStatus()
            quickAction = FinderQuickActionService.currentVisibility()
        }
        .sheet(isPresented: $showFinderGuide) {
            FinderGuideSheet { showFinderGuide = false }
        }
    }

    private var quickActionText: String {
        switch quickAction {
        case .visible: "Zobrazená v kontextovej ponuke"
        case .hiddenInFinder: "Nainštalovaná, ale vo Findere vypnutá"
        case .notInstalled: "Nenainštalovaná"
        }
    }

    private func install() {
        finderMessage = FinderQuickActionService.installQuickAction()
            ? "Quick Action bola nainštalovaná do služieb Findera."
            : "Quick Action sa nepodarilo nainštalovať."
        quickAction = FinderQuickActionService.currentVisibility()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Vybrať"
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.webSigningOutputPath = url.path
        }
    }

    /// The launchd agent the Safari extension reaches the app through; without it
    /// a portal never gets an answer.
    @ViewBuilder
    private var agentStatusRow: some View {
        switch agentStatus {
        case .enabled:
            Label("Prepojenie so Safari je zapnuté.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .requiresApproval:
            Label("Prepojenie so Safari čaká na povolenie v Položkách pri prihlásení.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Otvoriť Položky pri prihlásení…") { WebBridgeAgentService.openLoginItemsSettings() }
        case .notRegistered:
            Label("Prepojenie so Safari nie je zaregistrované.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
        case .legacyAgentOnly:
            Label("Podpisovanie zo Safari teraz ide cez staršie prepojenie z predchádzajúcej inštalácie, ktoré macOS po reštarte sám nespustí. Kliknite na Zaregistrovať.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
        case .refusedByMacOS(legacyAgentInstalled: true):
            InlineError(message: "macOS nové prepojenie so Safari nepustí, kým eviduje staré z predchádzajúcej inštalácie. Kliknite na Odstrániť staré prepojenie, reštartujte Mac a o pár minút kliknite na Zaregistrovať. Dovtedy podpisovanie zo Safari nepôjde.")
            HStack {
                Button("Odstrániť staré prepojenie") { agentStatus = WebBridgeAgentService.retireLegacyAgent() }
                Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
            }
        case .refusedByMacOS(legacyAgentInstalled: false):
            InlineError(message: "macOS registráciu prepojenia so Safari zatiaľ odmieta. Ak ste práve odstránili staré prepojenie, reštartujte Mac a o pár minút kliknite na Zaregistrovať. Skontrolujte tiež, či je Chevron7 (the Software s.r.o.) zapnutý v Systémové nastavenia → Všeobecné → Položky pri prihlásení a rozšírenia → Povoliť na pozadí.")
            HStack {
                Button("Otvoriť Položky pri prihlásení…") { WebBridgeAgentService.openLoginItemsSettings() }
                Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
            }
        case .legacyAgentRemoved:
            Label("Staré prepojenie je v Koši. Reštartujte Mac, otvorte Chevron7 a o pár minút kliknite na Zaregistrovať.",
                  systemImage: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
        case .failed(let message):
            InlineError(message: "Prepojenie so Safari sa nepodarilo zaregistrovať: \(message)")
            Button("Otvoriť Položky pri prihlásení…") { WebBridgeAgentService.openLoginItemsSettings() }
        case .translocated:
            Label("Chevron7 beží priamo z disku DMG alebo z neprenesenej kópie, odkiaľ macOS prepojenie so Safari nedovolí. Presuňte Chevron7 do priečinka Applications a spustite ho znova.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unsignedBuild:
            Label("Vývojárska zostava bez Developer ID: prepojenie so Safari registruje scripts/install-webbridge-agent.sh.",
                  systemImage: "hammer")
                .foregroundStyle(.secondary)
        }
    }
}

struct FinderGuideSheet: View {
    let onClose: () -> Void

    private let steps = [
        "Nainštalujte Chevron7 do priečinka Applications.",
        "Kliknite na Nainštalovať Quick Action. Chevron7 ju uloží do ~/Library/Services.",
        "Vo Findere otvorte Quick Actions → Customize… a zaškrtnite \(FinderQuickActionService.menuTitle).",
        "Označte jeden alebo viac PDF súborov.",
        "Kliknite pravým tlačidlom a zvoľte Quick Actions → \(FinderQuickActionService.menuTitle).",
        "Chevron7 vyberie dostupný podpisový certifikát, mandátny uprednostní. PIN alebo BOK zadáte iba počas podpisu.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Aktivácia vo Findere") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Label {
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "\(index + 1).circle.fill").foregroundStyle(.teal)
                        }
                    }
                }
                Section {
                    Text("Ak položka nie je ani v Customize…, ukončite a znova spustite Chevron7, v Rozšírených kliknite na Obnoviť služby macOS a reštartujte Finder. Workflow prijíma iba PDF súbory, nie ASiC-E kontajnery. PIN sa nikdy neukladá.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Hotovo") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .padding()
        }
        .frame(width: 520, height: 460)
    }
}
```

- [ ] **Step 2: AI pane**

Cut `enum AIPromptPreset` (old file lines 11-37) and `enum LearningCardText` (lines 1277-1286) from `Views/SettingsView.swift` and paste them unchanged at the top of `AISettingsPane.swift`, under the imports. Then add:

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Kit
import FoundationModels
import SwiftUI
import UniformTypeIdentifiers

// enum AIPromptPreset { ... }   (moved unchanged)
// enum LearningCardText { ... } (moved unchanged)

struct AISettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    var waitForLearningWrites: @MainActor () async -> Void = {}
    @Environment(\.openWindow) private var openWindow
    @State private var selectedPromptPreset: AIPromptPreset = .legalDocuments
    @State private var counts: [BankLabel: Int] = [:]
    @State private var reviewedPages: Int?
    @State private var message: String?
    @State private var showDeleteConfirmation = false
    @State private var modelAvailable = false
    @State private var readinessText: String?
    @State private var activeModelText: String?
    @State private var hasPreviousModel = false
    @State private var hasActiveModel = false

    private var bank: ExampleBank { settingsStore.exampleBank }

    private static let basicModes: [AppSettings.AIMode] = [.builtInOnDevice, .disabled]
    private static let allModes: [AppSettings.AIMode] = [.builtInOnDevice, .omlxLocal, .ollamaLocal, .customAPIKey, .disabled]

    var body: some View {
        let settings = settingsStore.settings
        let providerActive = SettingsAdvancedState.aiProviderIsActive(settings)
        let modes = (showAdvanced || providerActive) ? Self.allModes : Self.basicModes
        SettingsPaneForm(pane: .ai, pills: SettingsStatus.ai(mode: settings.aiMode, reviewedPages: reviewedPages)) {
            Section {
                Picker("Poskytovateľ", selection: $settingsStore.settings.aiMode) {
                    ForEach(modes) { mode in
                        Text(title(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Label("Detekcia", systemImage: "viewfinder")
            } footer: {
                Text("Vstavané pravidlá na tomto Macu bežia vždy. Zvolený režim dopĺňa detekciu bezpečnostných prvkov podľa § 37.")
            }

            if settings.aiMode.supportsPromptOverride {
                providerSection(showsBadge: !showAdvanced)
                if showAdvanced { promptSection }
            }

            Section {
                Toggle("Klasifikovať neisté nálezy modelom na tomto Macu (Apple Intelligence)",
                       isOn: $settingsStore.settings.useFoundationModelClassifier)
                    .disabled(!modelAvailable)
                Toggle("Učiť sa z potvrdených a odmietnutých prvkov", isOn: $settingsStore.settings.learnFromReviews)
                Text(LearningCardText.summary(counts: counts))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack {
                    if showAdvanced {
                        Button("Exportovať dataset pre Create ML…") { exportDataset() }
                    }
                    Spacer()
                    Button("Vymazať lokálny dataset…", role: .destructive) { showDeleteConfirmation = true }
                }
            } header: {
                Label("Učenie", systemImage: "graduationcap")
            } footer: {
                Text(modelAvailable
                     ? "Dataset aj model zostávajú na tomto Macu a nikdy sa neodosielajú."
                     : "On-device model nie je dostupný. Zapnite Apple Intelligence v Systémových nastaveniach.")
            }

            Section {
                if let readinessText {
                    Text(readinessText).monospacedDigit()
                }
                if let activeModelText {
                    Text(activeModelText).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Otvoriť trénovanie…") { openWindow(id: DetectorTrainingWindow.id) }
                    if showAdvanced, hasActiveModel {
                        Button("Exportovať detektor…") { exportModel() }
                    }
                    if hasPreviousModel {
                        Button("Vrátiť predchádzajúci detektor") { rollbackModel() }
                    }
                }
                if showAdvanced {
                    Toggle("Pripomínať trénovanie detektora", isOn: $settingsStore.settings.detectorTrainingOffersEnabled)
                }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            } header: {
                Label("Vlastný detektor", systemImage: "scope")
            } footer: {
                Text("Dosť skontrolovaných strán natrénuje detektor aj pre nové dokumenty, iba na tomto Macu. Prenos detektora nesie iba model, nikdy vaše skeny.")
            }
        }
        .task { await refresh() }
        .onAppear {
            let current = settingsStore.settings.aiPrompt
            selectedPromptPreset = AIPromptPreset.allCases.first { $0.promptText == current }
                ?? (current == nil ? .legalDocuments : .customPrompt)
        }
        .confirmationDialog("Vymazať všetky uložené príklady?", isPresented: $showDeleteConfirmation) {
            Button("Vymazať", role: .destructive) { deleteDataset() }
            Button("Zrušiť", role: .cancel) {}
        }
    }

    private func title(for mode: AppSettings.AIMode) -> String {
        switch mode {
        case .builtInOnDevice: "Interný režim (na tomto Macu)"
        case .omlxLocal: "oMLX (Apple Silicon MLX)"
        case .ollamaLocal: "Ollama (lokálny server)"
        case .customAPIKey: "Vlastný API kľúč (OpenAI-compatible)"
        case .disabled: "Vypnuté"
        }
    }

    // MARK: - Advanced provider

    private func providerSection(showsBadge: Bool) -> some View {
        Section {
            switch settingsStore.settings.aiMode {
            case .omlxLocal:
                TextField("API endpoint", text: $settingsStore.settings.omlxURL, prompt: Text("http://localhost:8000/v1"))
                TextField("Model", text: $settingsStore.settings.omlxModel,
                          prompt: Text("mlx-community/Qwen2.5-VL-7B-Instruct-4bit"))
                readinessRow("Endpoint", ready: validEndpoint(settingsStore.settings.omlxURL))
                readinessRow("Model", ready: !trimmed(settingsStore.settings.omlxModel).isEmpty)
            case .ollamaLocal:
                TextField("Server", text: $settingsStore.settings.ollamaURL, prompt: Text("http://localhost:11434"))
                TextField("Model", text: $settingsStore.settings.ollamaModel, prompt: Text("llava / llama3.2-vision"))
                readinessRow("Server", ready: validEndpoint(settingsStore.settings.ollamaURL))
                readinessRow("Model", ready: !trimmed(settingsStore.settings.ollamaModel).isEmpty)
            case .customAPIKey:
                TextField("Base URL", text: $settingsStore.settings.openAICompatibleBaseURL,
                          prompt: Text("https://api.openai.com/v1"))
                TextField("Model", text: $settingsStore.settings.openAICompatibleModel, prompt: Text("gpt-4o-mini"))
                SecureField("API kľúč", text: Binding(
                    get: { KeychainStore.load(account: "ai.apikey") ?? "" },
                    set: { newValue in
                        if newValue.isEmpty {
                            KeychainStore.delete(account: "ai.apikey")
                        } else {
                            _ = KeychainStore.save(secret: newValue, account: "ai.apikey")
                        }
                    }), prompt: Text("sk-…"))
                readinessRow("Base URL", ready: validEndpoint(settingsStore.settings.openAICompatibleBaseURL))
                readinessRow("API kľúč v Keychaine", ready: !trimmed(KeychainStore.load(account: "ai.apikey") ?? "").isEmpty)
            case .builtInOnDevice, .disabled:
                EmptyView()
            }
        } header: {
            HStack {
                AdvancedSectionHeader(title: "Konfigurácia poskytovateľa")
                if showsBadge { AdvancedBadge() }
            }
        } footer: {
            Text("Kľúč sa ukladá výhradne do Keychainu tohto Macu.")
        }
    }

    private var promptSection: some View {
        Section {
            Picker("Predvoľba promptu", selection: $selectedPromptPreset) {
                ForEach(AIPromptPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .onChange(of: selectedPromptPreset) { _, preset in
                if let promptText = preset.promptText {
                    settingsStore.settings.aiPrompt = promptText
                }
            }
            TextEditor(text: Binding(
                get: { settingsStore.settings.aiPrompt ?? "" },
                set: { newValue in
                    selectedPromptPreset = .customPrompt
                    settingsStore.settings.aiPrompt =
                        newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newValue
                }))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 80)
            HStack {
                Spacer()
                Button("Obnoviť predvolený") {
                    settingsStore.settings.aiPrompt = nil
                    selectedPromptPreset = .legalDocuments
                }
            }
        } header: {
            AdvancedSectionHeader(title: "Klasifikačný prompt")
        } footer: {
            Text("Prázdne pole znamená schválený predvolený prompt. Prompt sa použije iba pre oMLX, Ollama a vlastné API.")
        }
    }

    private func readinessRow(_ label: String, ready: Bool) -> some View {
        LabeledContent(label) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? .green : .orange)
                .accessibilityLabel(ready ? "Pripravené" : "Chýba")
        }
    }

    private func validEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: trimmed(value)), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return false }
        return true
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Learning (moved from LearningDatasetCard)

    private func refresh() async {
        modelAvailable = SystemLanguageModel.default.isAvailable
        let entries = await bank.entries()
        counts = Dictionary(grouping: entries, by: \.label).mapValues(\.count)
        let bankDir = await bank.directory
        let root = ModelRegistry.modelsDirectory(in: bankDir)
        let pages = (try? await bank.reviewedPages()) ?? []
        let state = (try? TrainingState.load(from: root)) ?? TrainingState()
        let settings = settingsStore.settings
        let report = DetectorTrainingReadiness.report(
            pages: pages, lastRunAt: state.lastRunAt,
            learnOn: settings.learnFromReviews,
            offersEnabled: settings.detectorTrainingOffersEnabled,
            snoozedUntil: state.snoozedUntil)
        reviewedPages = state.lastRunAt == nil ? report.reviewedPages : nil
        if state.lastRunAt == nil {
            readinessText = "Skontrolované strany: \(report.reviewedPages) z \(DetectorTrainingReadiness.firstRunPages) pre prvé trénovanie"
        } else {
            readinessText = "Nové strany od posledného trénovania: \(report.newSinceLastTraining) z \(DetectorTrainingReadiness.retrainNewPages)"
        }
        let registry = ModelRegistry(root: root)
        if let meta = try? JSONDecoder().decode(
            ModelMetadata.self,
            from: Data(contentsOf: root.appendingPathComponent("active/metadata.json"))) {
            let date = meta.trainedAt.formatted(date: .numeric, time: .omitted)
            activeModelText = "Aktívny vlastný detektor z \(date): recall +\(Int((meta.recallGain * 100).rounded())) %."
            hasActiveModel = true
        } else {
            activeModelText = nil
            hasActiveModel = false
        }
        hasPreviousModel = FileManager.default.fileExists(atPath: registry.previousModelURL().path)
    }

    private func deleteDataset() {
        Task {
            do {
                await waitForLearningWrites()
                try await bank.removeAll()
                message = "Lokálny dataset bol vymazaný."
            } catch {
                message = "Vymazanie zlyhalo: \(error.localizedDescription)"
            }
            await refresh()
        }
    }

    private func rollbackModel() {
        Task {
            do {
                let bankDir = await bank.directory
                try ModelRegistry(root: ModelRegistry.modelsDirectory(in: bankDir)).rollback()
                message = "Vrátený predchádzajúci detektor."
            } catch {
                message = "Vrátenie zlyhalo: \(error.localizedDescription)"
            }
            await refresh()
        }
    }

    private func exportModel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Detector.zip"
        panel.prompt = "Exportovať"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let bankDir = await bank.directory
                try ModelTransfer().exportActiveModel(modelsRoot: ModelRegistry.modelsDirectory(in: bankDir), to: url)
                message = "Detektor exportovaný: \(url.lastPathComponent). Obsahuje iba model, nikdy vaše skeny."
            } catch {
                message = "Export zlyhal: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    private func exportDataset() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Exportovať"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            do {
                await waitForLearningWrites()
                let url = try await CreateMLExporter.export(bank: bank, to: folder)
                message = "Export hotový: \(url.path)"
            } catch {
                message = "Export zlyhal: \(error.localizedDescription)"
            }
        }
    }
}
```

Note: the old `LearningDatasetCard` reads `bank.entries()`; `bank` is `settingsStore.exampleBank` (the old call site passed `settingsStore.exampleBank`).

- [ ] **Step 3: Build and run the moved-type tests**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter 'SettingsLearningCardTests|SigningBatchTests/testAIPromptPresetChoicesAreExactlyApproved|SettingsStatusTests'`
Expected: `Build complete!` and PASS.

- [ ] **Step 4: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/Settings/BrowserFinderSettingsPane.swift Chevron7/Sources/Chevron7App/Views/Settings/AISettingsPane.swift Chevron7/Sources/Chevron7App/Views/SettingsView.swift
git commit -m "feat(settings): browser and Finder pane, AI and learning pane

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Sidebar shell replaces the tabs

**Files:**
- Delete: `Chevron7/Sources/Chevron7App/Views/SettingsView.swift`
- Create: `Chevron7/Sources/Chevron7App/Views/Settings/SettingsView.swift`
- Modify: `Chevron7/Sources/Chevron7App/Chevron7App.swift:125-130`

**Interfaces:**
- Consumes: every pane (Tasks 8 to 11), `SettingsPane.initial` (Task 2), `EZZKConnection.isConnected` (Task 6), `SettingsIcon` (Task 7).
- Produces: `SettingsView(settingsStore: AppSettingsStore, waitForLearningWrites: @MainActor () async -> Void = {})`, same initializer as before.

- [ ] **Step 1: Delete the old file and write the shell**

Run: `git rm Chevron7/Sources/Chevron7App/Views/SettingsView.swift`
(This removes the old tabs, `LearningDatasetCard`, `WebSigningStorageCard` and `MobileSigningCard`. `AIPromptPreset`, `LearningCardText` and `AdvocateProfile.displayName` were already moved in Tasks 8 and 11.)

Create `Views/Settings/SettingsView.swift`:

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// Settings as System Settings lays them out: panes in a sidebar, Basic content always,
/// Advanced content behind one toggle at the bottom of the sidebar.
struct SettingsView: View {
    @Bindable var settingsStore: AppSettingsStore
    var waitForLearningWrites: @MainActor () async -> Void = {}
    @AppStorage("settings.showAdvanced") private var showAdvanced = false
    @AppStorage("settings.selectedPane") private var storedPane = ""
    @State private var selection: SettingsPane?

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(symbol: pane.symbol, tint: pane.tint)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                Toggle("Rozšírené nastavenia", isOn: $showAdvanced)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Zobrazí technické nastavenia v každej sekcii.")
            }
        } detail: {
            detail(for: selection ?? .profile)
        }
        .toolbar(removing: .sidebarToggle)
        .onAppear {
            let controller = settingsStore.ezzkAccountController
            selection = SettingsPane.initial(
                stored: storedPane,
                ezzkConnected: EZZKConnection.isConnected(mode: controller.mode,
                                                          hasStoredCredentials: controller.hasStoredCredentials))
        }
        .onChange(of: selection) { _, pane in
            if let pane { storedPane = pane.rawValue }
        }
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .profile:
            ProfileSettingsPane(settingsStore: settingsStore)
        case .ezzk:
            EZZKSettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced)
        case .signing:
            SigningSettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced)
        case .mobile:
            MobileSettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced)
        case .browserFinder:
            BrowserFinderSettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced)
        case .ai:
            AISettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced,
                           waitForLearningWrites: waitForLearningWrites)
        case .general:
            GeneralSettingsPane(settingsStore: settingsStore)
        }
    }
}
```

- [ ] **Step 2: Window size**

In `Chevron7App.swift`, the `Window("Nastavenia", id: SettingsWindow.id)` block becomes:

```swift
        Window("Nastavenia", id: SettingsWindow.id) {
            SettingsView(settingsStore: model.settingsStore, waitForLearningWrites: { await model.zakoStore.waitForBankWrites() })
                .environment(model.ezzkAccountController)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)
```

- [ ] **Step 3: Build and run the whole suite**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test`
Expected: `Build complete!`; every test passes. Any reference to a deleted type (`LearningDatasetCard`, `WebSigningStorageCard`, `MobileSigningCard`, `MobileSigningCard.agpSetupSteps`) is a compile error to fix by pointing it at the new type (`EidentitaSetupSheet.steps`).

- [ ] **Step 4: Check for glass on content and em dashes**

Run: `grep -rn -e 'glassCard' -e 'glassEffect' -e '—' Chevron7/Sources/Chevron7App/Views/Settings/`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add -A Chevron7/Sources/Chevron7App/Views Chevron7/Sources/Chevron7App/Chevron7App.swift
git commit -m "feat(settings): System Settings style sidebar with Basic and Advanced

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Docs, rename boundary, app build and screenshots

**Files:**
- Modify: `CLAUDE.md`, `AGENTS.md` (repo root; identical edits)

- [ ] **Step 1: Update the Settings descriptions**

In both `CLAUDE.md` and `AGENTS.md`, replace the bullet that starts with `- **Settings (SettingsView.swift)**:` with:

```markdown
- **Settings (`Views/Settings/`)**: a System Settings style `NavigationSplitView` (`SettingsView`): seven panes in the sidebar (`SettingsPane`: Profil advokáta, EZZK, Podpisovanie, Mobil a eIdentita, Prehliadač a Finder, AI a učenie, Všeobecné), each SF Symbol on a tinted square (`SettingsIcon`), and a "Rozšírené nastavenia" toggle at the sidebar bottom (`@AppStorage("settings.showAdvanced")`; the last pane is `settings.selectedPane`, first open shows EZZK until it is connected). Every pane is a `.formStyle(.grouped)` form whose first group is `SettingsPaneHeader` with status pills derived from existing state (`SettingsStatus`, tested). Advanced groups appear only with the toggle, except a setting holding a non-default value (`SettingsAdvancedState`), which shows with an "Rozšírené" badge. Basic EZZK has no environment picker: "Pripojiť k EZZK" confirms, switches to production and signs in, restoring the previous mode on failure; "Odpojiť" keeps production (`EZZKConnection`). EZZK modes read "Skúšobný režim (lokálne)", "Testovacia evidencia" and "Ostrá evidencia" (`EZZKMode.label`). Guides live in sheets (`EidentitaSetupSheet`, `FinderGuideSheet`); the Quick Action pill reads whether Finder shows it (`FinderQuickActionService.currentVisibility`). Glass only on the navigation layer: one `.glassProminent` action per pane, pills are tinted capsules. Spec: `Chevron7/docs/superpowers/specs/2026-10-06-settings-redesign-design.md`
```

Also in the `AI provider selection in Settings uses provider rows (SettingsView.aiProviderRow)...` bullet, replace that sentence with: `AI provider selection in Settings is a radio group in AISettingsPane (Interný režim and Vypnuté in Basic; oMLX, Ollama and a custom API key with their configuration in Advanced); learning, dataset and detector sections live in the same pane`.

- [ ] **Step 2: Verify the two files are identical and free of em dashes**

Run: `cmp CLAUDE.md AGENTS.md && ! grep -n '—' CLAUDE.md`
Expected: no output, exit status 0.

- [ ] **Step 3: Rename boundary**

Run: `Chevron7/scripts/check-rename-boundary.sh`
Expected: passes (exit 0).

- [ ] **Step 4: Build the app and capture each pane**

Run: `cd /Users/magneto/Projects/Chevron7/Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" ./build_app.sh`
Then open the built app (`.build/out/Products/Debug/Chevron7.app`), open Nastavenia (⌘,) and capture every pane in light and dark mode, with "Rozšírené nastavenia" off and on (28 screenshots). Check: header pills match the state; no pane shows a horizontal scroll bar at 760 pt width; Full Keyboard Access moves through sidebar and form; the EZZK connect confirmation appears before any network call. Save the captures in the session scratchpad and send them to the user.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md AGENTS.md
git commit -m "docs: Settings as a sidebar with Basic and Advanced

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Spec coverage check

| Spec section | Task |
|---|---|
| Window structure, sidebar, toggle, remembered pane, first open | 2, 12 |
| Sidebar panes, symbols, tints | 2, 7 |
| Visual language: header, pills, grouped form, glass rules, badge | 7, 12 (grep check) |
| Guides in sheets | 10, 11 |
| Profil advokáta | 8 |
| EZZK labels | 1 |
| EZZK Basic, connect flow, connected state, Odpojiť, Advanced | 6, 9 |
| Podpisovanie | 8 |
| Mobil a eIdentita | 10 |
| Prehliadač a Finder, Quick Action visibility | 4, 11 |
| AI a učenie | 11 |
| Všeobecné | 8 |
| Active Advanced values | 3 |
| Status pill derivation | 5 |
| Errors inline, confirmations on owning panes | 8, 9, 11 |
| Code layout | all |
| Testing | 1 to 6, 12, 13 |
| Docs and rules | 13 |

Deviations from the spec, stated in Task 9: no "Overiť" button for a saved login (the controller cannot re-verify without the password) and no "Otvoriť register" button (no deep link into the main window exists).
