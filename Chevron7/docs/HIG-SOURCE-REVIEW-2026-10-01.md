# Chevron7 HIG Source Review - 2026-10-01

Scope: read-only check of the macOS SwiftUI app. No code changed.
Method: source review only (`read` + `grep` on `Chevron7/Sources/Chevron7App`). No running app, no contrast measurement, no Accessibility Inspector run, no accessibility-tree observation. Results below are source observations, not verified visual passes.

HIG corpus: apple-hig skill release 2026-09-27, Apple source snapshot 2026-09-12.
Guidance mode: ordinary guidance (no enforce mode, no Duo mode).

Loaded references (routing helper `hig_route.py`, request "just check the app"):

- 16 foundations: `accessibility`, `branding`, `color`, `dark-mode`, `design-principles`, `icons`, `images`, `inclusion`, `layout`, `materials`, `motion`, `privacy`, `right-to-left`, `sf-symbols`, `typography`, `writing`
- Plus project-relevant platform file (no related expansion): `designing-for-macos`

App files sampled:

- `Chevron7/Sources/Chevron7App/Chevron7App.swift` (WindowGroup, menus, window sizing)
- `Chevron7/Sources/Chevron7App/Theme/DesignSystem.swift` (`glassCard`, `inspectorCard`, `StickyActionBar`, badges)
- `Chevron7/Sources/Chevron7App/Theme/AsyncActionButton.swift`, `HoldToConfirmButton.swift`
- `Chevron7/Sources/Chevron7App/Views/RootView.swift` (NavigationSplitView, sidebar, bottom bar)
- `Chevron7/Sources/Chevron7App/Views/SigningFlowViews.swift`, `ZakoFlowViews.swift`
- `Chevron7/Sources/Chevron7App/Views/AnalysisCanvasView.swift`, `AttestationFormView.swift`, `AuthorizeDoneViews.swift`
- `Chevron7/Sources/Chevron7App/Views/EvidenceDashboardView.swift`, `SettingsView.swift`
- `Chevron7/Sources/Chevron7App/Views/MobileSigningSheet.swift`, `EidentitaSigningSheet.swift`, `WebSigningSheet.swift`, `ZakoCardPromptSheet.swift`

## 1. Passes (source-observed)

### 1.1 Materials

Source rule: "Use regular when background content might create legibility issues or components contain significant text, such as alerts, sidebars, or popovers."

Application: `glassCard()` uses `.regularMaterial` with 12pt continuous rounding plus a subtle primary stroke (`DesignSystem.swift:9-16`). `StickyActionBar` uses `.regularMaterial` over a divider (`DesignSystem.swift:30-44`). Sidebar bottom bar uses `.regularMaterial` (`RootView.swift:417`). This matches the rule for text-bearing containers.

Source rule: "Don't use Liquid Glass in the content layer."

Application: no custom Liquid Glass in content views found. `inspectorCard()` deliberately uses flat `Color.primary.opacity(0.035)` to avoid stacked frosted layers (`DesignSystem.swift:18-26`). Consistent with the rule.

### 1.2 Color and Dark Mode architecture

Source rule: "Use semantic colors that adapt automatically (`labelColor`/`controlColor` in macOS; `separator` in iOS/iPadOS)."

Application: backgrounds use `Color(nsColor: .windowBackgroundColor)` (`SigningFlowViews.swift:18`, `ZakoFlowViews.swift:19`) and `Color(nsColor: .controlBackgroundColor)` (`AttestationFormView.swift:354`). Text hierarchy uses `.primary`, `.secondary`, `.tertiary`, `.accentColor`. No hard-coded light/dark hex values found in app views.

Source rule: "For custom colors, add an Xcode Color Set with bright and dim variants. Avoid hard-coded or non-adaptive values."

Application: status fills use semantic colors with opacity (`.red.opacity(0.08)`, `.orange.opacity(0.08-0.09)`, `.green.opacity(0.14)`, `.accentColor.opacity(0.07-0.08)`). They adapt because the base color is semantic. No separate asset needed at this usage.

Source rule: "Avoid relying solely on color to differentiate objects, indicate interactivity or communicate essential information; be sure to also convey it another way, like text labels or glyph shapes."

Application: status rows pair color with `Label` + SF Symbol + text (for example `checkmark.seal.fill` / `exclamationmark.triangle.fill` / `creditcard.fill` in `AttestationFormView.swift:280-296`, `AuthorizeDoneViews.swift:88-106`, `SigningFlowViews.swift:502-508`). Evidence rows pair tone color with `UXLabels.evidenceStatusLabel` text and `record.status.sfSymbol` (`EvidenceDashboardView.swift:589-590`). Sidebar conversion rows expose `row.accessibilityLabel` with name, number and state (`SidebarConversionRows.swift:22-24`, `RootView.swift:184`).

### 1.3 Typography architecture

Source rule: "Consider using the built-in text styles."

Application: bulk of UI uses built-in styles (`.callout`, `.caption`, `.caption2`, `.footnote`, `.headline`, `.title2`, `.title3`, `.subheadline`). Examples: `DesignSystem.swift:59,63`, `RootView.swift:69,78,170,174`, `SigningFlowViews.swift:132-136`, `EvidenceDashboardView.swift:52,75,88`. This preserves the macOS text-style scale:

| Style | Weight | Size | Line height |
|---|---|---|---|
| Body | Regular | 13 | 16 |
| Headline | Bold | 13 | 16 |
| Callout | Regular | 12 | 15 |
| Footnote | Regular | 10 | 13 |

Custom `.system(size:)` uses are isolated to badges, clause print preview and excerpt views (see open item 2.1).

macOS reference sizes from HIG typography: `Default 13 pt`, `Minimum 10 pt`. Most app text sits at or above minimum via styles.

### 1.4 Accessibility labels

Source rule (accessibility): "Describe the interface and content for VoiceOver." Related practice: "Label elements appropriately for Voice Control."

Application: broad coverage found via grep (40+ sites). Examples:

- Document rows: `"Podpisany dokument ..."`, `"Nedavny dokument ..."`, `"Dokument ..."` with values for origin, method, availability (`RootView.swift:97-98,308-309,351-353`)
- Register rows: hint `"Otvori detail v Registri konverzii"` (`RootView.swift:185`)
- Canvas: `"SuhRN dokumentu"`, `"Prebieha analyza dokumentu"`, element rows with kind, state, provenance, confidence and selected state plus `accessibilityAddTraits([.isSelected, .isButton])` and `"Vybrat prvok"` action (`AnalysisCanvasView.swift:505-506,524-525,1239-1243`)
- Batch: `"Davka podpisov"`, `"Priebeh podpisovania"`, `"Zaverecne zhrnutie davky"` with counts, per-item values (`SigningFlowViews.swift:1206-1208,1529-1531,1566-1570,1605-1610`)
- Controls: `"Predchadzajuca strana"`, `"Nasledujuca strana"`, `"Poskytovatel detekcie"`, `"PIN podpisovej karty"` with empty/filled value, `"Sluzba casovej peciatky"`, `"Skopirovat SHA-256 odtlacok"` (`AnalysisCanvasView.swift:317-318,342,358`, `SigningFlowViews.swift:1319,1393-1395,1516`)
- Donate, settings, provider rows similarly labeled.

No `accessibilityHidden(true)` abuse found except one decorative stack in Done view (`AuthorizeDoneViews.swift:481`).

### 1.5 Keyboard and macOS integration

Source rule (designing-for-macos): "Use the menu bar for easy access to all app commands." / "Handle keyboard shortcuts to accelerate actions and support keyboard-only workflows."

Application: `Chevron7Commands` provides File Open (`Cmd-O`), Open with shift variant, Recent menu, Sidebar toggle (`Ctrl-Cmd-S`), Settings replacement (`Cmd-,`), Help Donate (`Chevron7App.swift:133-197`). Sheets use `.defaultAction` for primary and `.cancelAction` for cancel (`PhysicalSecurityElementView.swift:47,55`, `WebSigningSheet.swift:288,294`, `ZakoCardPromptSheet.swift:48,79,82`, `EidentitaSigningSheet.swift:27`, `MobileSigningSheet.swift:27`). Intake uses `Cmd-O` buttons (`SigningFlowViews.swift:151`, `ZakoFlowViews.swift:172`).

Source rule (designing-for-macos): "Let people resize, hide, show, and move windows to fit their work style and device configuration; support full-screen mode for distraction-free work."

Application: main `WindowGroup` sets `frame(minWidth: ..., minHeight: 640)`, `idealWidth: 1320, idealHeight: 860`, `defaultSize(width: 1320, height: 860)`, `.windowStyle(.automatic)` (`Chevron7App.swift:97-103`). Settings uses a regular `Window` with `minWidth: 900, minHeight: 560` and `.windowResizability(.contentMinSize)` (`Chevron7App.swift:115-121`). No full-screen opt-out found. Sidebar has `navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)` (`RootView.swift:412`).

### 1.6 Privacy

Source rule: "Store sensitive information in a keychain (Keychain services)." / "Never store passwords or secure content in plain-text files"

Application: AI API key reads via `KeychainStore.load(account: "ai.apikey")` (`SettingsView.swift:298`), copy states key stays in system Keychain (`SettingsView.swift:310`). EZZK password Keychain-only, token memory-only per project docs. PIN copy states PIN is operation-scoped (`SigningFlowViews.swift:632`, batch PIN `SigningFlowViews.swift:1396`). No plain-text secret storage found in sampled views.

### 1.7 Motion

Source rule: keep motion purposeful; supplement with non-motion feedback. Accessibility pairs with Reduce Motion handling.

Application: error shake in `AsyncActionButton.swift:97-111` gates increment with `!reduceMotion`. No autoplay or looping decorative animation found in sampled views.

### 1.8 QR sheets (correction)

Prior draft flagged `Color.white` QR backgrounds as a Dark Mode defect. Correction after reading full `qrArea`:

- `EidentitaSigningSheet.swift:35-42` and `MobileSigningSheet.swift:35-42` apply `.padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 12))` directly to the `Image(decorative:...)` QR, with `.quaternary` placeholder while loading. White is confined to the QR patch plus 8pt quiet zone, not the card. White QR backing is required for scanner contrast. No finding. Closed.

## 2. Open items (source-observed, not runtime-verified)

### 2.1 Custom 9pt type below macOS minimum [source-only]

Source rule: "Use sizes most people can read easily. Follow each platform's default and minimum sizes, for custom and system fonts alike." macOS row: `Default 13 pt`, `Minimum 10 pt`.

Evidence (custom sizes under 10pt):

- `AttestationFormView.swift:320` `.system(size: 11, weight: .bold, design: .serif)` title (above minimum, noted for context)
- `AttestationFormView.swift:324,326,346` `.system(size: 9, design: .serif)` clause body lines
- `AnalysisCanvasView.swift:222` `.system(size: 9, weight: .bold)` page count badge
- `WebSigningSheet.swift:117` `.system(size: 9)` page label
- `EvidenceDashboardView.swift:741` `.system(size: 10, design: .monospaced)` attestation XML (at minimum)
- Small symbols `.system(size: 8-10)` for chevrons and step marks (`AnalysisCanvasView.swift:582`, `DesignSystem.swift:152,156,177`, `EvidenceDashboardView.swift:769`)

Why it matters: 9pt on-screen body is smaller than the HIG macOS minimum even if the printed clause uses small serif. Badges at 9pt are short strings, lower risk, but still worth an Inspector + legibility pass at 1x/2x.

Suggested next check (not applied): run the clause preview and badge at 10pt minimum on-screen, keep 9pt only if the clause is a 1:1 print preview with a documented exception; verify `caption2` equivalents where possible.

### 2.2 Bottom-anchored primary actions [source-only]

Source rule: "**macOS:** Avoid controls/critical information at the window bottom (the window may be moved below the screen edge)"

Evidence: `StickyActionBar` pinned to bottom in signing prepare and ZaKo authorize flows; main window `minHeight: 640` mitigates but does not remove the clipped-window case.

Why not a fail now: bottom action bars are a common Mac pattern and content scrolls above the bar in these flows. Needs a runtime check: move window bottom off-screen, confirm primary action remains reachable via scrolling, keyboard (`.defaultAction`) and Full Keyboard Access.

### 2.3 Contrast and Dynamic Type need runtime proof [not checked]

Source rules for reference:

- "Strive for acceptable contrast using a standard contrast calculator." WCAG Level AA values guiding Accessibility Inspector: `Up to 17 pt All 4.5:1`, `18 pt All 3:1`, `All Bold 3:1`.
- "If the default does not meet these minimums, provide a higher-contrast scheme when Increase Contrast is on."
- macOS control sizes: `Default 28x28 pt`, `Minimum 20x20 pt`. Spacing note: "about 12 pt around elements with a bezel and about 24 pt around the visible edges of elements without one can reduce accidental taps."

Not verified: subtle `Color.primary.opacity(0.03-0.04)` card fills, `.secondary`/`.tertiary` captions on `.regularMaterial`, orange/green status text on tinted capsules. These use system colors (good for adaptation) but still need Increase Contrast + light/dark runs in Accessibility Inspector. No custom hit-size violations found in source, but no pointer/click measurement was taken.

## 3. Explicitly not covered

- Visual layout, clipping, truncation, RTL mirroring, VoiceOver traversal order, keyboard-only run, unhealthy color-vision simulation, tvOS/visionOS/watchOS rules (app is macOS-only).
- Legal copy accuracy (Slovak strings), EZZK flows, signing correctness, engine behavior.
- Performance, battery, haptics/audio (not applicable to this Mac app surface).

## 4. Recommended next verification (read-only, no fix yet)

1. Build and run in light + dark + Increase Contrast + Reduce Transparency; screenshot signing prepare, ZaKo authorize, canvas review, register detail.
2. Accessibility Inspector audit: labels, traits, hit sizes, contrast.
3. Window tests: min size 1320x640 (or current `MacOS27Layout.rootMinimumWidth` x 640), resized narrow, bottom off-screen, full-screen.
4. Type sweep: replace ad-hoc 9pt screen text with style equivalents at 10pt or larger unless print-fidelity exception is documented.
5. Keyboard-only pass: Tab order, `.defaultAction`/`.cancelAction`, Full Keyboard Access focus rings, no trapped focus in sheets.

## 5. Change log for this note

- 2026-10-01: initial source review saved. QR white-background item investigated and closed as by-design after reading `qrArea` in both sheets. No app code touched.
- 2026-10-03: item 2.1 applied for screen text: the clause preview lines (`AttestationFormView`), the page count badge (`AnalysisCanvasView`) and the web signing page label (`WebSigningSheet`) moved from 9pt to the 10pt macOS minimum. Kept at 9pt: SF Symbol glyphs (step checkmark, chevrons) and the element label drawn on the analysis canvas, whose frame is fixed at 170x14 pt over the scan. Items 2.2 and 2.3 still need a runtime pass.
