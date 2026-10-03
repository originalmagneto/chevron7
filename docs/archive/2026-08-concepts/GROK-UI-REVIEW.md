# Review of Grok's interface suggestions

Date: 2026-09-15
Input: `DESING-SUGGESTIONS-GROK.md`

## Verdict

The report identifies real opportunities to improve adaptivity, keyboard access, and visual hierarchy. Its blanket prescription to remove bottom bars, replace tabs, and add background-extension effects is too strong. Some observations are outdated, and its Settings code does not compile as written.

**Recommended direction:** give the document more space, make signing context trustworthy, finish keyboard access, and simplify the busiest controls. Preserve useful workflow progress and the document's actual appearance. Native components are a means to those outcomes, not a reason to replace every custom view.

This review checked source, the installed macOS SDK, Apple documentation, existing layout contracts, and an icon source image. It did not run a live visual or VoiceOver audit. The comments below distinguish code evidence from visual hypotheses. No app code or original Grok report was changed.

## Corrections that matter before implementation

### 1. The proposed Settings API is wrong

The exact `.tabViewStyle(.sidebar)` example fails type checking with:

```text
error: type 'TabViewStyle' has no member 'sidebar'
```

Replacing it with `.tabViewStyle(.sidebarAdaptable)` type-checks in the installed Xcode 27 SDK. Apple documents that this style always presents a sidebar on macOS. See [SidebarAdaptableTabViewStyle](https://developer.apple.com/documentation/swiftui/sidebaradaptabletabviewstyle).

A `NavigationSplitView` with a category selection is another viable approach if explicit sidebar behavior is needed. Neither is required merely because Settings has five categories. Current tabs are a valid native control; the stronger issue is the density and repeated framing within each tab.

### 2. Keyboard editing already exists, but keyboard creation is incomplete

[The selected-element inspector](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/Views/AnalysisCanvasView.swift:601) already exposes numeric X/Y/width/height fields, arrow-key movement, and Shift-arrow resizing under `Presná poloha`.

The remaining gaps are more specific:

- The [add-element controls](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/Views/AnalysisCanvasView.swift:202) choose a tool, then instruct the user to click or drag on the document. There is no visible keyboard-only action to create a new box.
- Existing finding rows use `onTapGesture` for selection. An accessibility label alone does not establish an equivalent keyboard/VoiceOver activation path.
- Arrow shortcuts are attached to inspector buttons without explicit canvas-focus scoping. Check for conflicts while editing numeric fields or other controls.

A viable completion is an accessible Select action for existing findings and `Pridať na aktuálnu stranu`, placing a new box at a predictable position and selecting it for numeric editing. Retain the controls already implemented.

### 3. White PDF paper is not inherently a dark-mode defect

The explicit white rectangle is a **54 x 72 page backing**, not the entire thumbnail sidebar. A scanned page normally remains white in dark mode. Changing the paper color to a dark semantic control background may change how transparent margins and faint marks appear.

Evidence: [thumbnail rendering](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/Views/AnalysisCanvasView.swift:147).

Adapt the surrounding sidebar, selection outline, and padding to appearance. Preserve document colors. Removing redundant white decoration outside the actual page is reasonable after a visual check. The existing fixed portrait-shaped thumbnail backing could also misrepresent landscape page proportions; use the rendered page aspect ratio when revisiting it.

### 4. `backgroundExtensionEffect` does not reveal more document

Apple describes this as mirroring and blurring adjacent content into the background, without actually placing additional content under the sidebar. It is an optional visual effect, not an inspector requirement. See [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

For this document-review tool, mirrored text or marks provide little value and can confuse page boundaries. Prefer a neutral canvas around the real page. If an extension effect is prototyped, keep it outside the page and annotation hit-testing coordinate system.

### 5. The step bar is an indicator, not a second interactive navigation system

[FlowStepBar](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/Theme/DesignSystem.swift:145) displays text and symbols; it has no selection binding or step-change action. Simplifying its visual weight is reasonable. Replacing it with a segmented or palette picker introduces a new affordance: users expect to select any enabled segment.

Keep workflow prerequisites intact. For ZaKo, a compact `Krok 2 z 5: Overenie originálu` indicator is clearer than a picker for gated steps. For signing, reducing the step bar is optional; preserve orientation with a step label or title and consistent Back behavior.

Also distinguish Back from the current `Iný dokument` action: the latter resets the session. Do not relabel a reset as ordinary backwards navigation without changing its behavior.

### 6. Several material claims are overstated

- `glassCard` uses `.regularMaterial`, not `.glassEffect`. Repeated material cards can be visually busy, but this is not automatically multiple layers of Liquid Glass.
- [StickyActionBar](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/Theme/DesignSystem.swift:32) itself is an HStack, padding, and divider. It does not paint a glass background.
- Evidence's filter strip currently uses `windowBackgroundColor`, not the `.bar` background claimed in the report.
- `liquidGlass` and `floatingGlass` really are unused definitions. Removing unused helpers is reasonable housekeeping, with no direct visual benefit.
- A grouped `Form` is useful for settings layout and semantics; it should not be described as a guaranteed Liquid Glass content surface.

Apple recommends reducing custom backgrounds in navigation and controls and using custom glass sparingly. That supports selective simplification, not mandatory removal of all content grouping. See [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

## Assessment of the five high-priority proposals

| Grok proposal | Verdict | What I would do |
| --- | --- | --- |
| Move every primary action into the window toolbar | **Partly viable; too broad.** | Use a toolbar for document-wide navigation and editing actions. Keep signing confirmation close to its certificate/PIN context unless a prototype proves the toolbar improves the flow. Preserve discoverability, disabled states, mobile/card alternatives, and keyboard shortcuts. A persistent bottom action group is not inherently wrong. |
| Replace the 380-point signing pane with an inspector | **Strong candidate.** | The fixed width is confirmed in `SigningPrepareView`. Introduce a resizable, collapsible inspector with a visible toggle and menu command. Keep required signing controls reachable when collapsed, and show why signing is unavailable. Account for the main sidebar and preview at minimum window width. |
| Sidebar Settings with grouped forms | **Viable, medium-sized refactor.** | Use the corrected API, then migrate settings category by category to `Form`, `Section`, and standard controls. Preserve provider-specific configuration, help, validation messages, Keychain interactions, and all existing confirmation dialogs. Sidebar navigation is an option, not the primary usability fix. |
| Native inspector for the analysis canvas | **Viable; optional visual extension should be omitted initially.** | The existing HSplitView already resizes its panes, but `minimumWidth == 0` alone does not prove usable collapse/reopen behavior. Native inspector presentation can improve this. Keep page review, findings, and manual creation together. Retain the accurate page/overlay coordinate mapping. |
| Simplify wizard strips | **Viable polish after access issues.** | Reduce decoration and expose concise step progress. Do not make gated steps freely selectable. Preserve existing validation and session state when navigating. |
| Rebuild icon with Icon Composer | **Viable branding work, lower functional priority.** | The inspected PNG is a glossy pen/eID illustration with baked highlights and shadow. A simpler layered version should hold up better at small sizes. Preserve a recognizable pen/document concept and preview all appearances. Update packaging as well as artwork. |

The table separates the signing-inspector recommendation from the toolbar pass because it is independently valuable and has different workflow risks.

### Toolbar and search details

Evidence has a real crowding risk: search, a status filter, Open, Submit, and Export share one horizontal strip, and export errors add more controls. [The filter bar](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/Views/EvidenceDashboardView.swift:207) is a good candidate for `.searchable` plus a small set of toolbar actions. Preserve the existing search scope, status filter, empty/no-results states, Return/double-click behavior, and submit feedback. Search tokens are optional, not a requirement for native search.

Do not move every analysis control into the title bar. At narrow widths that simply relocates the crowding. The earlier plan explicitly allowed **toolbar or inspector groups**, and the current manual-marking controls and page navigation already live in the inspector. The report overstates how much of that plan is unfinished.

Apple's guidance supports deliberate grouping, a clear primary action, and overflow behavior at narrow widths. It does not establish a universal maximum of three groups; that number comes from this project's earlier plan. See [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars).

Use `safeAreaBar` where content actually scrolls beneath a custom bar. The present VStack layouts allocate space to the bars; adding a safe-area API is not automatically an improvement.

## Medium graphics and accessibility suggestions

| Item | Verdict and recommended treatment |
| --- | --- |
| Empty-state blur and glow | **Optional visual simplification.** The halo is present. Reduce it if it distracts from the import action; keep document-format guidance, error text, and drag/drop feedback. A standard unavailable view is one option, not a necessary replacement for an import screen. |
| Smartcard status glow / location | **Simplifying the glow is reasonable.** Do not move the entire footer into a crowded toolbar by default. Ensure card readiness is visible at signing time even with the sidebar hidden. The current footer derives connected status from a nonempty identities list, so truthful readiness is more important than its shadow. |
| Forced toolbar background visibility | **Try automatic behavior and compare.** The modifier exists in ZakoFlowView. Removal is a reasonable experiment, not a proven fix without looking at the resulting toolbar against the document. |
| Custom markup tiles | **Native picker is viable with preserved semantics.** The current tool is optional, and clicking the selected tool again exits marking mode. A picker needs an explicit Select/no-tool option. Retain labels for unfamiliar stamp/seal distinctions and keyboard activation. |
| Mixed corner radii | **Low-priority consistency work.** Two fixed values are not inherently concentric. Prefer system shapes and spacing; use a small number of meaningful tokens only for custom containers that remain. |
| Queue focus feedback | **Worth addressing early.** `.focusEffectDisabled()` is present. Restore clear focused-state feedback and verify Full Keyboard Access. Focus and the persistent selected document are different states; both must remain identifiable. |
| Sidebar document selection | **Useful but not a tag-only change.** The existing List selection type is `SidebarSection`; document rows are buttons. A unified typed selection model must distinguish sections, queued documents, recent-file opening, and Finder reveal. Do not launch Finder or reopen a document every time an arrow key changes selection. |
| Origin and preview in web prompt | **Highest priority interface improvement.** Show trusted origin and a preview bound to the exact requested content. A first-page preview or XML excerpt must be identified as partial and offer access to the rest. Add bounded loading/error behavior and preserve explicit confirmation. Coordinate with the XPC/origin fixes from the security review. |
| Browser panel | **Keep it.** It is already an NSPanel with standard SwiftUI controls. Fix close/cancel behavior from the security review. Its fixed 480-point content width and non-resizable style need reconsideration before adding a document preview. The claim that sheets can never come forward is too absolute; the existing panel solves this app's demonstrated background-prompt need. |
| Explicit unified toolbar style | **Optional.** `.windowStyle(.automatic)` and toolbar style control different aspects. Adding `.windowToolbarStyle(.unified)` may be useful for a chosen composition; absence of that modifier is not a defect. Compare with the system default. |
| Repeated inspector/settings cards | **Reasonable selective simplification.** Keep the conceptual groups and hierarchy. Try plain section headings and dividers on one panel surface before removing all containers or rebuilding entire screens. |
| Visible Settings label | **Small, viable discoverability improvement.** A `Label("Nastavenia", systemImage: "gearshape")` is clearer. The existing gear already has help and an accessibility label; this is not an established accessibility failure or universal HIG prohibition. Keep the app-menu Settings shortcut. |
| Reduce Transparency | **Check custom effects.** System materials adapt, but custom blur/shadow treatment deserves explicit testing and possibly an opaque variant. Do not assume every gradient becomes illegible. |
| Reduce Motion | **Target motion that actually occurs.** Static blur and gradients do not animate by themselves. `withAnimation` when scrolling to a selected finding is a more concrete place to respect reduced-motion preferences. |
| Text size and control metrics | **Valid adaptivity concern, broad diagnosis overstated.** Several fixed sizes are symbols, while much of the text already uses semantic styles. Audit small text, fixed widths, truncation, and localization. Semantic fonts do not make every macOS control automatically support arbitrary larger text. |
| Evidence detail inspector instead of sheet | **Optional behavior change.** Explicit Open/Return/double-click plus a sheet was deliberately specified in the earlier plan and is implemented. A selection-driven inspector may improve rapid review, but preserve full detail access and avoid network or edit side effects on selection. |

### Icon packaging detail

The build does not compile `AppIcon.iconset` or an Icon Composer document: it copies `Assets/Autogram.icns` and sets `CFBundleIconFile`. Changing only the iconset would not change this packaged app.

Evidence: [packaged icon](/Users/magneto/Projects/Autogram-macOS/Autogram/build_app.sh:44). A layered icon migration needs a compatible compilation/packaging step and a packaged-app check. The preview inspected during this review was `AppIcon.iconset/icon_256x256@2x.png`, not a runtime screenshot of the installed icon. Dark/clear/tinted appearance problems remain a prediction until previewed.

## Recommended implementation order

1. **Trust and access:** browser origin/preview and close behavior; finding selection/creation by keyboard; visible focus. Surface accurate card/signing readiness.
2. **Adaptivity:** resizable signing inspector with a reliable show/hide action; Evidence search and toolbar layout; long-error and minimum-window behavior.
3. **Settings:** simplify grouping and add the Settings label; adopt sidebar navigation if it helps category scanning.
4. **Canvas:** improve inspector presentation while preserving document colors, review state, and overlay alignment. Keep surrounding decoration quiet.
5. **Polish:** compact workflow progress, remove unnecessary glow, review toolbar visibility, clean up unused helpers.
6. **Branding:** layered icon plus updated app packaging and small-size/appearance previews.

## Verification and limits

- Type-checked Grok's Settings example: `.sidebar` fails; `.sidebarAdaptable` succeeds.
- Read the installed SwiftUI interface to confirm API availability for this target.
- Read relevant Apple documentation, including structured documentation endpoints where ordinary pages required JavaScript.
- Inspected the current SwiftUI layouts, state bindings, keyboard controls, existing plan, and icon source image.
- Ran the existing `MacOS27UXContractTests`: **3 passed, 0 failures**. Log: `/tmp/autogram-grok-ui-tests.log`. These tests check deployment/layout constants, not actual resizing, focus, or visual quality.

Before approving an implementation, exercise light/dark appearance, increased contrast, reduced transparency/motion, minimum-width windows, long Slovak labels/errors, keyboard-only creation and editing, and browser prompt cancellation. Those are acceptance checks for future changes; they were not claimed as completed here.

The strongest recommendations are based on observable layout and interaction constraints. Broad claims such as 'iOS-looking cards', 'double glass', or 'more Mac-like' are design judgments and need a rendered comparison before justifying a large rewrite.
