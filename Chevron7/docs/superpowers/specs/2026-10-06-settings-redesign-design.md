# Settings redesign: sidebar, Basic and Advanced, native macOS 27 look

Date: 2026-10-06
Status: approved in conversation, awaiting spec review
Branch: `feat/settings-redesign`

## Problem

The Settings window (`Sources/Chevron7App/Views/SettingsView.swift`, 1780 lines, one file) has five top tabs whose content does not match their names:

- "Konverzia PDF/A" holds mostly signing: TSA, phone signing (AVM), eIdentita and browser signing.
- "AI Vision" holds "Naposledy otvorené dokumenty".
- "Finder Quick Action" spends a whole tab on two buttons and a six step guide.
- Five long tab titles leave no room for another section; `.sidebarAdaptable` renders as top tabs on macOS 27.
- Status ("prihlásený do EZZK", "Safari zapnuté") is one grey line, while setup guides (eIdentita five steps, Finder six steps, the PEM key) are always expanded.
- Cards differ in width, some headings have icons and some do not, "Aktívna TSA" is labelled twice, the EZZK grid has uneven card heights, and one profile is a large form above empty space.

## Goals

1. Content grouped by what the advocate is doing, in a sidebar that can grow.
2. A Basic view that an advocate who downloaded the DMG understands, and an Advanced view for technical options, switched by one global toggle.
3. A native macOS 27 look following the HIG: Liquid Glass where the system puts it, SF Symbols, grouped forms, status at a glance.
4. No change to settings semantics, persisted values or the EZZK, signing and AI logic, apart from the EZZK "connect" flow and the EZZK mode labels described below.

## Non-goals

- Settings search.
- An overview or dashboard page.
- New status logic in services (pills read existing state only).
- Website screenshots of Settings (they go stale; separate task).
- Deep links from other screens into a given pane.

## Window structure

- `NavigationSplitView`: sidebar `List(selection:)` with `.listStyle(.sidebar)`, detail shows the selected pane. The sidebar and toolbar get Liquid Glass from the system. No sidebar toggle (`.toolbar(removing: .sidebarToggle)`), as in System Settings.
- Window: minimum 760 x 560, default 900 x 640 (the `Window("Nastavenia", id: SettingsWindow.id)` scene in `Chevron7App.swift`).
- Sidebar bottom: a `Toggle("Rozšírené nastavenia")`, small control size.
- Remembered UI preferences (not `AppSettings`, they are viewer conveniences):
  - `@AppStorage("settings.showAdvanced")`, default `false`
  - `@AppStorage("settings.selectedPane")`, the pane raw value
- First open (no stored pane): EZZK when EZZK is not connected (see below), else Profil advokáta.

### Sidebar panes

| Pane (`SettingsPane`) | Title | SF Symbol | Tint |
|---|---|---|---|
| `.profile` | Profil advokáta | `person.text.rectangle.fill` | blue |
| `.ezzk` | EZZK | `building.columns.fill` | green |
| `.signing` | Podpisovanie | `signature` | indigo |
| `.mobile` | Mobil a eIdentita | `iphone.radiowaves.left.and.right` | orange |
| `.browserFinder` | Prehliadač a Finder | `safari.fill` | teal |
| `.ai` | AI a učenie | `eye.fill` | purple |
| `.general` | Všeobecné | `gearshape.fill` | gray |

Each sidebar row is a `Label` whose icon is `SettingsIcon`: the symbol in white on a rounded square filled with the tint (System Settings style), 20 pt in the sidebar.

## Visual language

- **Pane header** (`SettingsPaneHeader`): `SettingsIcon` at 48 pt, title (`.title2`, semibold), one line subtitle (`.secondary`), then a row of `StatusPill`s.
- **StatusPill**: SF Symbol plus short text on a tinted capsule (`Capsule().fill(tint.opacity(0.15))`, text in the tint). Semantic tones:
  - `.ok` green, `checkmark.circle.fill`
  - `.attention` orange, `exclamationmark.triangle.fill`
  - `.off` gray, `minus.circle.fill`
  - `.info` blue, `info.circle.fill`
  Each pill has an `accessibilityLabel` with its full meaning.
- **Body**: `Form { ... }.formStyle(.grouped)`. Rows are `LabeledContent`, `Toggle`, `Picker`, `TextField` with the label on the left and the control on the right. An explanation lives in the section footer, at most two sentences.
- **Liquid Glass per HIG**: glass belongs to the navigation layer (sidebar, toolbar, sheets, the primary button), not to content. Pills are plain tinted capsules; the form keeps the native grouped background. At most one `.buttonStyle(.glassProminent)` primary action per pane; other buttons use the default style.
- **Guides move to sheets**: "Nastaviť eIdentitu…" (`EidentitaSetupSheet`: steps, portal, organization id, generate key, copy key, verify) and "Ako aktivovať vo Findere…" (the six steps). A pane keeps the status and one button.
- **Advanced group**: when shown, a final `Section` titled "Rozšírené" with `slider.horizontal.3` in its header.
- **Advanced badge**: an Advanced row shown because its value is active (see below) carries a small gray "Rozšírené" capsule.
- `glassCard()` leaves Settings only; the rest of the app keeps it.

## Pane content

### Profil advokáta

Basic:
- Header pills: active profile name (`.info`), or "Žiadny profil" (`.attention`).
- Section "Profily": a `List` of profiles, the active one marked with `checkmark`, selection picks the profile to edit; `+` / `-` buttons under the list (macOS list editing pattern). "Nastaviť ako aktívny" for a non-active selection. Delete keeps its confirmation dialog.
- Section "Údaje profilu": meno a priezvisko, funkcia, evidenčné číslo SAK, IČO kancelárie, názov kancelárie, adresa kancelárie, právnická osoba.

Advanced: none.

### EZZK

User facing mode names (`AppSettings.EZZKMode.label`, raw values unchanged because they are persisted):
- `.demo`: "Skúšobný režim (lokálne)"
- `.test`: "Testovacia evidencia"
- `.production`: "Ostrá evidencia"

These labels also appear in the Register detail ("Režim EZZK"), which is intended.

Basic, state "not connected" (mode `.demo`, or `.production` without stored credentials):
- Pill `.info` "Skúšobný režim, bez zápisu do evidencie" in demo; `.attention` "Nepripojené" in production without credentials.
- Section "Účet EZZK": prihlasovacie meno, heslo, názov osoby, IČO.
- Primary button "Pripojiť k EZZK".

Connect flow:
1. Confirmation dialog: "Od tejto chvíle sa evidenčné čísla aj záznamy o konverzii zapisujú do centrálnej evidencie s právnymi účinkami."
2. Remember the previous mode, set `settings.ezzkMode = .production` and `controller.setMode(.production)`, then `controller.signIn(login:password:)`.
3. On success: state "connected". On failure: restore the previous mode in both places and show the error under the fields.

Basic, state "connected" (mode `.production` with stored credentials):
- Pills: `.ok` "Pripojené", `.ok` "Odosielanie zapnuté" (or `.off` when the production policy refuses).
- Section "Účet EZZK": login, "Heslo: v Keychaine", osoba and IČO, last verification time; buttons "Overiť" and "Odpojiť".
- Section "Odosielanie záznamov": the existing explanation in one footer sentence, button "Otvoriť register".

"Odpojiť" calls `controller.signOut()` and leaves the mode on production. A conversion then fails with a login error instead of silently running in the trial mode without legal effect. Returning to the trial mode is Advanced only.

Advanced:
- Mode picker with all three labels (and the existing explanations).
- Endpoint URLs (Prihlásenie, Služba).
- Overenie záznamu (lookup).
- Evidenčné čísla (test only, unchanged rules).
- Kontaktné údaje pre migráciu.

State "test" (mode `.test`) is an active Advanced value: the mode picker shows even when Advanced is off.

### Podpisovanie

Basic:
- Pill: active TSA name, plus `.ok` "Kvalifikovaná" when it is one of `TimestampAuthority.qualifiedURLs`, or `.attention` "Kvalifikácia neoverená" when `settings.activeTSAQualificationIsUnverified` (the existing warning text stays in the section footer).
- Section "Časová pečiatka": picker "Aktívna TSA" (one label), "Otestovať spojenie" with the result inline.
- Section "PDF/A": segmented picker (vector / raster) with the existing footer.

Advanced: "Vlastné TSA servery" (list, add, delete with confirmation).

### Mobil a eIdentita

Basic:
- Pills: phone signing on or off; eIdentita `.ok` "Pripravená" when a key is stored in the Keychain and the organization id is set, `.attention` "Nedokončená" when only one of them is, `.off` "Nenastavená" otherwise. Verification is not persisted today, so its result shows only in the sheet for the current run.
- Section "Autogram v mobile": toggle "Ponúkať podpis občianskym preukazom s NFC cez iPhone" with the existing footer.
- Section "eIdentita": status row and button "Nastaviť eIdentitu…" opening `EidentitaSetupSheet`.

Advanced: AVM server URL; portal URL (staging or live); remove key.

### Prehliadač a Finder

Basic:
- Pills: Safari bridge from `WebBridgeAgentService.Status`; Quick Action from `FinderQuickActionService.servicesStatus` (Finder shows it only when the `pbs` entry has `presentation_modes`), because the workflow is reinstalled on every launch and its file nearly always exists.
- Section "Safari": bridge status row with its existing fix actions; toggle "Ukladať podpísané dokumenty aj lokálne".
- Section "Finder": Quick Action status; primary button "Nainštalovať Quick Action" only when Finder does not show it; "Ako aktivovať vo Findere…" sheet.

Advanced: output folder ("Vybrať…"), "Automaticky presunúť kópie do Koša", "Obnoviť služby".

### AI a učenie

Basic:
- Pills: active provider; "Skontrolované strany: N z 40" (`.info`).
- Section "Detekcia": choice between "Interný režim (na tomto Macu)" and "Vypnuté".
- Section "Učenie": Apple Intelligence classifier toggle, "Učiť sa z potvrdených a odmietnutých prvkov", counts (`LearningCardText.summary`), "Vymazať lokálny dataset…".
- Section "Vlastný detektor": progress, "Otvoriť trénovanie…".

Advanced: oMLX, Ollama and custom API key providers with their configuration and readiness rows; prompt preset and custom prompt; "Exportovať dataset pre Create ML…"; "Pripomínať trénovanie detektora".

### Všeobecné

Basic: "Pamätať naposledy otvorené dokumenty" with its footer. The "Rozšírené nastavenia" toggle stays in the sidebar.

## Active Advanced values

`SettingsAdvancedState` (pure, in `Chevron7App`, tested) answers per item whether its value differs from the default. Such an item is shown with the "Rozšírené" badge even when Advanced is off, so no hidden configuration changes signing or EZZK silently:

- `ezzkModeIsActive`: `ezzkMode == .test`
- `customTSAIsActive`: `selectedTSAURL` is one of `customTSAServers`
- `avmServerIsActive`: `avmBaseURL` differs from the default
- `agpPortalIsActive`: `agpBaseURL` differs from the default
- `webSigningFolderIsActive`: `webSigningOutputPath` is not empty
- `webSigningRetentionIsActive`: `webSigningRetentionDays` is not "never"
- `aiProviderIsActive`: `aiMode` is `.omlxLocal`, `.ollamaLocal` or `.customAPIKey`

## Status pill derivation

`SettingsStatus` (pure functions, tested) maps existing state to `[StatusPill]` per pane:

| Pane | Inputs |
|---|---|
| Profil | `settings.profiles`, `settings.activeProfileID` |
| EZZK | `settings.ezzkMode`, `controller.state`, `controller.hasStoredCredentials`, `controller.productionPolicy.allowsConsequentialCalls` |
| Podpisovanie | `settings.activeTSA`, `TimestampAuthority.qualifiedURLs`, `settings.activeTSAQualificationIsUnverified` |
| Mobil a eIdentita | `settings.mobileSigningEnabled`, eIdentita key in the Keychain, `settings.agpUserID` |
| Prehliadač a Finder | `WebBridgeAgentService.Status`, `FinderQuickActionService.servicesStatus` |
| AI | `settings.aiMode`, reviewed page count |

No pending-row count pill: `EZZKStatusChecker` has no accessor for it, and the submission pill covers the need.

## Errors and confirmations

- Errors show inline: red `exclamationmark.octagon.fill` and one sentence in the footer of the section that failed.
- Confirmation dialogs stay only for irreversible or legally relevant steps: delete profile, delete TSA server, connect to EZZK, delete the local dataset, request test numbers. They attach to the pane that owns them (profile and TSA dialogs to their panes, the EZZK dialogs to `EZZKSettingsPane`), not to the window root.

## Code layout

`Sources/Chevron7App/Views/Settings/`:

- `SettingsView.swift`: window, sidebar, Advanced toggle, pane routing
- `SettingsPane.swift`: pane enum with title, symbol and tint
- `SettingsComponents.swift`: `SettingsIcon`, `SettingsPaneHeader`, `StatusPill`, `AdvancedBadge`, the Advanced section
- `SettingsAdvancedState.swift`, `SettingsStatus.swift`: pure logic
- `ProfileSettingsPane.swift`
- `EZZKSettingsPane.swift` (including the connect flow)
- `SigningSettingsPane.swift`
- `MobileSettingsPane.swift`, `EidentitaSetupSheet.swift`
- `BrowserFinderSettingsPane.swift`
- `AISettingsPane.swift` (keeps `LearningCardText` with its name and signature, used by `SettingsLearningCardTests`)
- `GeneralSettingsPane.swift`

`SettingsView`'s public init (`settingsStore`, `waitForLearningWrites`) stays the same, so `Chevron7App.swift` only changes the window size. Existing logic (EZZK sign in, TSA test, Safari agent status, eIdentita key, dataset export) moves unchanged.

## Testing

Unit tests (App tests with `makeSettingsStore()` and `MemoryCredentialStore`, never the real Keychain or Application Support):

- `SettingsAdvancedStateTests`: each predicate for default and non-default values.
- `SettingsStatusTests`: pills per pane for each state, including EZZK demo, production without credentials, connected, policy refused.
- `EZZKConnectFlowTests`: a failed sign in restores the previous mode; a successful one leaves production; "Odpojiť" keeps production and drops credentials.
- Existing tests, including `SettingsLearningCardTests`, pass.

Manual: build the app and capture every pane in light and dark mode, with Advanced on and off; check Full Keyboard Access focus through the sidebar and forms.

## Known gap

With production mode and no stored credentials (after "Odpojiť", or today), ZaKo learns about the missing login only in `authorizeAndSign`, before signing and before a number is allocated; the SOAP client throws `EZZKError.notConfigured`, which the submission coordinator treats as nothing sent and requeues. Nothing is lost, but the advocate fills the form first. An early ZaKo notice ("Pripojte EZZK v Nastaveniach") is a follow-up, not part of this change.

## Docs and rules

- Update the Settings description in `CLAUDE.md` and `AGENTS.md` together (they must stay identical).
- New files pass `scripts/check-rename-boundary.sh`; "Autogram v mobile" is the AVM relay name and stays.
- No em dashes in strings or docs.
