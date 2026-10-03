# Autogram macOS: graphical and interface suggestions (macOS 27)

Date: 2026-09-15
Author: Grok (static UI/UX review against macOS 27 Liquid Glass and HIG)

This is a source review of the SwiftUI app shell, signing, ZaKo canvas, evidence register, Settings, and browser signing panel. It was not a live click-through of a running build. No em dashes are used in this document.

The app already sits on the macOS 27 floor (`NavigationSplitView`, semantic materials, no neon, Settings as its own window). The remaining gaps are mostly where custom chrome still sits on top of the system Liquid Glass layer.

Official references used:

- https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- https://developer.apple.com/design/human-interface-guidelines/toolbars
- https://developer.apple.com/design/human-interface-guidelines/sidebars
- https://developer.apple.com/design/human-interface-guidelines/buttons
- Project baseline: `docs/SESSION_HANDOFF_2026-08-28.md`, `Autogram/docs/superpowers/plans/2026-08-28-macos27-ux-preflight-accessibility.md`

---

## Verdict

The shell reads as a native Mac app, not a web port. Apple's rule for Liquid Glass is: **standard bars, sidebars, and controls get the material for free; custom glass belongs only on small functional groups.** Autogram still paints a second layer of cards, bottom bars, and wizard strips on top of that. That is the main graphical debt.

`liquidGlass()` / `.glassEffect` is defined and unused. Almost every card uses `glassCard` (`.regularMaterial` + stroke). That is safer than stacking `.glassEffect`, but it still fights the system: content cards look like iOS insets instead of macOS 27 grouped content.

---

## What already matches macOS 27

Do not "fix" these.

- `NavigationSplitView` + `.listStyle(.sidebar)` + `Table` + `ContentUnavailableView`
- Menu commands are **text** (`Otvoriť súbor…`, `Nastavenia…`), which matters because macOS 27 hides many menu images
- Signing and ZaKo use `.borderedProminent` / `.controlSize(.large)` instead of custom CTA capsules
- Confidence and overdue status have text labels, not color alone (`UXLabels`)
- Inspector can collapse (`MacOS27Layout.inspectorMinimumWidth == 0`)
- Settings live in a resizable `Window`, not a sidebar fake-route
- Browser signing uses a floating `NSPanel` (correct after Sonoma: a sheet on a background app never comes forward)
- Project contract tests: `MacOS27UXContractTests` (deployment 27.0, inspector can collapse)

---

## High-priority interface gaps

### 1. Primary actions sit in a custom bottom bar instead of the window toolbar

Apple: toolbars **are** the Liquid Glass control layer; group related items; let scroll-edge effects keep them legible.

Today:

- Analysis canvas: `StickyActionBar` at the bottom (`AnalysisCanvasView.swift` around 80-113)
- Signing prepare: same pattern, inspector column `.background(.bar)` at a **fixed 380 pt** (`SigningFlowViews.swift` 254-273)
- Evidence: custom `filterBar` with a hand-drawn search field and `.background(.bar)` (`EvidenceDashboardView.swift` 207-270)

The August 2026 macOS 27 plan already said to move markup, page nav, and sheet-count into **at most three toolbar groups**, primary action on the trailing edge. That was not finished for analysis or signing.

**Do this**

- Window toolbar: Back | Re-analyze | Detection provider || Continue
- Evidence: `.searchable` on the navigation title + toolbar items for CEZZK / CSV / Open
- Signing prepare: `.inspector` (or `NavigationSplitView` inspector column) instead of a 380 pt `HStack`, so the pane can collapse and pick up system glass
- Register those bars with `safeAreaBar` if anything still scrolls underneath

Fixed 380 pt and `StickyActionBar` also ignore extra-large control metrics and larger text.

### 2. Settings look like a tabbed iOS scroll of glass cards

`SettingsView` is a `TabView` + `.tabItem` wrapping `ScrollView` + about 20 `.glassCard`s. Five categories (AI, PDF/A, EZZK, Finder, Profiles) belong in a **sidebar-style** settings window.

macOS 15+ / 27 pattern:

```swift
TabView {
    Tab("AI Vision", systemImage: "brain.head.profile") {
        Form { Section("Poskytovateľ") { ... } }
    }
    // ...
}
.tabViewStyle(.sidebar)
```

Use `Form` / `Section` / `LabeledContent` / `Picker` / `Toggle`. Drop `glassCard` here. The system grouped form is the Liquid Glass settings surface; nested material cards double-glass and clip more easily than `Form` (the file already needed a `ScrollView` workaround because content was clipped).

`OpenSettingsButton` in the sidebar is a **gear with no visible title**. HIG: sidebar footer actions should read as text (`Nastavenia`) plus symbol. The accessibility label is there; the visual is icon-only.

### 3. Split views do not use the inspector / background-extension APIs

Apple: use split views with an **inspector panel**, check safe areas, optionally `backgroundExtensionEffect()` so document content feels edge-to-edge under the chrome.

`AnalysisCanvasView` uses `HSplitView` plus a hand-built 80 pt thumbnail strip. Thumbnails sit on `Color.white` (`AnalysisCanvasView.swift` 147-149), which is a **dark-mode break** (white slabs in a dark window).

**Do this**

- Document canvas as the content column
- Thumbnails as a leading accessory, not a white card stack
- Findings as `.inspector` with `inspectorColumnWidth`
- `backgroundExtensionEffect()` on the page render so the PDF peeks under the sidebar/inspector glass

### 4. Custom wizard chrome competes with navigation titles

`FlowStepBar` is a second navigation system under an already-set `navigationTitle` / `navigationSubtitle`. Signing has three steps; ZaKo has five. The capsules, 22 pt circles, and green gradients are decorative relative to macOS 27 (concentric system controls, no extra glow).

**Do this**

- Signing: drop the bar. Title = current step (`Nastavenie podpisu`). Back lives in the toolbar.
- ZaKo: keep progress, but as a compact `Picker` with `.segmented` / `.palette` in the toolbar, or a single `ProgressView` + step name. Do not paint a web-style stepper across the content layer.

### 5. App icon is still a static `.iconset`, not Icon Composer layers

Apple's Liquid Glass icon rules: **layered** foreground / middle / background, let the system do specular light, blur, and dark/clear/tinted variants. `Autogram/Assets/AppIcon.iconset/` is flattened PNGs. In dark, clear, and tinted appearances the icon will look like a baked-in glass rendering sitting on system glass.

Rebuild in Icon Composer with solid overlapping shapes, no pre-baked blur or highlights.

---

## Medium: graphics and HIG

| Issue | Where | Why it matters | Fix |
|---|---|---|---|
| Decorative glow / blur on empty state | `DropzoneArtwork` (`DesignSystem.swift` 219-245): 160 pt blurred circle, white 0.22 stroke | Apple: do not decorate Liquid Glass; test Reduce Transparency / Reduce Motion | One SF Symbol + `ContentUnavailableView` or a single concentric `roundedRect` with `.regularMaterial`. No blur halo. |
| HUD glow on card status | `SmartcardHUDStatus` green `.shadow(radius: 4)` | Extra glow on a sidebar that is already glass | System green/secondary fill, no shadow. Put this in the window toolbar as a status item, not a custom sidebar footer capsule. |
| Forced toolbar chrome | `ZakoFlowViews.swift` `.toolbarBackgroundVisibility(.visible)` | Fights scroll-edge / automatic glass | Remove; let the system decide. |
| Custom search field | Evidence `filterBar` fake field with magnifying glass | Duplicate of toolbar search; no `.searchable` tokens | `.searchable(text:placement:)` |
| Markup tools are custom tiles | `toolButton` in `AnalysisCanvasView` | Should be `Picker` + `.palette` / segmented, extra-large size | Native picker in the inspector or a toolbar `ToolbarItemGroup` |
| Mixed corner radii | 6, 8, 9, 10, 12, 14, 16, 18, 24 | Liquid Glass wants concentric rounding to the window | One token, e.g. 10 for inner, 16 for panels |
| `Color.white` thumbnails | Analysis strip | Dark appearance | `Color(nsColor: .controlBackgroundColor)` or the page image only |
| Queue rows disable focus rings | `RootView.swift` `.focusEffectDisabled()` | Full Keyboard Access on macOS 27 | Delete it. Use `List` selection, not `Button` + `listRowBackground` |
| Sidebar documents as plain buttons | Signed / recent / queue | Not selectable list rows; no arrow-key move | `List` rows with `.tag` / selection |
| Control crowding in Evidence | Search + status picker + 3 buttons in one strip | Apple: do not crowd glass controls | Toolbar groups: search \| filter \| primary CEZZK |
| Web prompt has no document preview | `WebSigningSheet.swift` filename/size only | High-stakes confirm on a utility panel | Origin + first page / XML excerpt; keep the panel, make it a proper `NSPanel` with standard controls |
| `windowStyle(.automatic)` only | `AutogramApp.swift` | Fine, but no unified toolbar identity | `.windowToolbarStyle(.unified)` so title + toolbar share one glass bar |
| Unused glass helpers | `liquidGlass()`, `floatingGlass()` in `DesignSystem.swift` | Dead API; easy to misuse later | Keep `.glassEffect` only if a small functional group needs it (markup cluster). Delete or stop using `floatingGlass`. |
| `glassCard` on almost every settings and inspector block | ~40 call sites | Content is not the glass layer | Settings: `Form`. Inspectors: plain groups or one material, not a card per section. |

---

## Accessibility and adaptivity (still on the macOS 27 list)

Already better than the 18/40 review in the August 2026 handoff. Remaining:

- **Reduce Transparency / Reduce Motion:** `DropzoneArtwork` blur, HUD glow, `Color.green.gradient` on completed steps will look muddy or busy. Prefer semantic fills; skip blur when `accessibilityReduceTransparency` / `accessibilityReduceMotion` is on.
- **Dynamic Type:** several `.font(.system(size: 9...14))` in the canvas and `FlowStepBar`. Use `.caption2` / `.callout` so extra-large controls and larger text still fit.
- **Keyboard on the canvas:** markup still depends on click-to-place (`onTapGesture` around line 942). The 2026 plan wanted a VoiceOver / keyboard equivalent (inspector list + Place / Nudge).
- **Evidence double-click** plus Return is good; selection should also drive an inspector instead of only a sheet, which is more Mac-like for a register.
- **Sidebar Settings** has `.accessibilityLabel("Nastavenia")` and `.help`, but no visible text.

---

## Suggested implementation order (graphics only)

1. **Toolbar pass** (signing prepare, analysis, evidence): kill `StickyActionBar` and the custom filter strip; three toolbar groups; `.searchable`; `.inspector`.
2. **Settings rewrite:** `Tab` + sidebar style + `Form`. Label the sidebar Settings control. No `glassCard`.
3. **Canvas split view:** inspector API, no white thumbnails, `backgroundExtensionEffect` on the PDF.
4. **Simplify FlowStepBar** (or remove it on the 3-step signing flow).
5. **Quiet empty states and HUD:** no blur, no glow; `ContentUnavailableView` on intake.
6. **Icon Composer** layered icon (light / dark / clear / tinted).
7. Restore focus rings; make sidebar queues real `List` selection.

Items 1-3 are the ones a Tahoe/27 user will feel immediately: the window chrome starts looking like Finder / Mail / Preview, and the document becomes the content layer instead of sitting in a stack of material cards.

---

## File index

| Area | Paths |
|---|---|
| Layout contract | `Autogram/Sources/AutogramKit/MacOS27Layout.swift`, `Autogram/Tests/AutogramKitTests/MacOS27UXContractTests.swift` |
| Design tokens / custom chrome | `Autogram/Sources/AutogramApp/Theme/DesignSystem.swift` |
| App shell / sidebar | `Autogram/Sources/AutogramApp/AutogramApp.swift`, `Autogram/Sources/AutogramApp/Views/RootView.swift` |
| Signing | `Autogram/Sources/AutogramApp/Views/SigningFlowViews.swift` |
| ZaKo + canvas | `Autogram/Sources/AutogramApp/Views/ZakoFlowViews.swift`, `AnalysisCanvasView.swift`, `AttestationFormView.swift`, `AuthorizeDoneViews.swift` |
| Evidence | `Autogram/Sources/AutogramApp/Views/EvidenceDashboardView.swift` |
| Settings | `Autogram/Sources/AutogramApp/Views/SettingsView.swift` |
| Browser prompt | `Autogram/Sources/AutogramApp/WebSigningPrompt.swift`, `WebSigningSheet.swift` |
| Icon | `Autogram/Assets/AppIcon.iconset/` |
| Prior plan | `Autogram/docs/superpowers/plans/2026-08-28-macos27-ux-preflight-accessibility.md` |

Related: security and speed notes live in `FIXES-SUGGESTIONS-GROK.md`.
