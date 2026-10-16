# Window resize loop after hiding the sidebar (2026-10-16)

## Symptom

`SigningWindowResizeTests.testSigningScreenWithSidebarHiddenFromTheToolbarSurvivesShrinkingTheWindow` failed on the owner's Mac Studio for minutes or hours at a time and passed otherwise, on the same code (cbc9c0f3, 657f586b, d25f72c0 alike). AppKit threw `NSGenericException`: "The window has been marked as needing another Update Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views in the window", the loop that crashed 1.4.3. A failing run took about 21 s against 5 s for a passing one: the loop itself, until AppKit gave up twice.

## Trigger: the display was asleep

`pmset -g log` puts every recorded failure inside a "Display is turned off" period and every pass inside a "Display is turned on" period:

| Failures (local time) | Display off |
| --- | --- |
| 2026-10-15 18:17 to 18:22 | 18:16:10 to 18:56:40 |
| 2026-10-16 12:38 | 12:19:31 to 12:42:11 |
| 2026-10-16 16:52 to 17:06 | 16:46:04 to 20:36:11 |
| 2026-10-16 21:11 onwards (this investigation) | from 21:10:15 |

Passes (2026-10-16 11:27; 20:39 to 21:07, across screens, occlusion, scroller style, CPU load, cursor position, accessibility clients) all ran with the display on. With the display asleep the test failed on every run, at any window position; waking the display while the screen stayed locked (`caffeinate -u`) made it pass again. The screen lock, the second display, the other running Chevron7 build and the test's defaults domain play no part.

## Mechanism

The test hides the sidebar, then shrinks the window from 1200 x 788 to 1000 x 700. With the sidebar shown the window needs 1038 points; hidden, 760 (the `MinimumSizeFloor`).

- Hiding the sidebar is animated, whether through the toolbar button (SwiftUI's `com.apple.SwiftUI.navigationSplitView.toggleSidebar` item) or `NSSplitViewController.toggleSidebar(_:)` (the ⌃⌘S command). While it runs, the window's minimum width steps down with it (measured 1038, 1030, 788, 760 over about 0.25 s) and AppKit's split view still lays the sidebar out.
- The animation advances with the display. While the display sleeps it does not advance at all, so the window keeps needing 1038 points.
- A frame narrower than that (here `setFrame` to 1000 points) leaves the columns no room, and the hosting views ping-pong: the unified log shows `NSHostingView.SizeConstraints.update` changing a constraint constant that `AppKitPlatformViewHost.layoutMetricsInvalidatedForHostedView` turns into another SwiftUI invalidation, and the toolbar bridge re-vending its items (`Toolbar.LocationStorage.updatedVendedItems`) on every pass, until `-layoutSubtreeIfNeeded` hits 300 iterations and the window throws.

Measured while the display slept: the animated collapse (either path) followed by the resize failed on every run; the same collapse without animation (`isCollapsed` set directly, or the toolbar button writing a `columnVisibility` binding inside a transaction that disables animations) passed; hiding the inspector, whose animated collapse keeps the minimum at the expanded width until it ends, passed. Wrapping `toggleSidebar(_:)` in a zero-duration `NSAnimationContext` group does not help: it animates on its own terms.

With the display awake the same race exists, only narrower: a resize issued in the same run loop turn as the toolbar press failed on one run in four.

## Can a person hit it?

Yes, rarely: hiding the sidebar and having the window resized within that quarter second (a window tiling shortcut, a resize already under way), or at any time while a display does not refresh (a monitor asleep or switched off while macOS moves or resizes the window, for example on wake). 1.4.3 showed that this exception ends the app.

## Fix

The main window's `NavigationSplitView` takes its column visibility through `Binding.sidebarVisibility` (`Theme/UnanimatedColumnVisibility.swift`) over a per-window `@SceneStorage` flag, so a hidden sidebar is still remembered as the split view's own autosave did: every change, including the one the toolbar button makes, runs in a transaction that disables animations, and the ⌃⌘S command sets the same flag instead of sending `toggleSidebar(_:)`. A sidebar dragged shut sets the flag too, so ⌃⌘S brings it back with one press. The sidebar no longer slides; it hides and shows at once, and the minimum drops in one step. The Settings window removes its sidebar button, so it is not affected.

## Tests

- `testHidingTheSidebarDropsTheMinimumInOneStep` samples the window's minimum every 4 ms for 0.5 s after the toolbar press and accepts only the expanded and the collapsed width. With the animation back it fails with the display awake (intermediate widths), and asleep the minimum stays at the expanded width (measured), so it does not depend on the displays.
- `testSigningScreenWithSidebarHiddenFromTheToolbarSurvivesShrinkingTheWindow` presses the real toolbar button and resizes at once, then shrinks to the floor. Its previous version (AppKit's `toggleSidebar(_:)`, then 1200 and 1000 points) and the same sequence through the toolbar button failed on every run with the display asleep.
- `testSidebarCollapsedByTheDividerSetsTheFlag` and `testSidebarFlagMapsToTheColumnsAndBack` cover the flag.
- The final tests ran with the display awake. With the display asleep, the same composition (the unanimated binding, the toolbar press, the shrink sequence) passed in a probe, where the animated one failed on every run.
