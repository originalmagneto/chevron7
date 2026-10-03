# README and Diagram Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair visible SVG geometry collisions, keep the standalone diagrams and self-contained gallery synchronized, and enrich `README.md` with GitHub-compatible HTML without changing application code.

**Architecture:** Standalone SVG files under `docs/diagrams/` are the canonical diagram sources. The gallery keeps inline SVG copies inside its existing card wrappers, so each repaired standalone SVG is copied into its matching gallery section without adding a runtime dependency. README presentation uses native Markdown plus GitHub-safe HTML elements and preserves current Slovak content claims.

**Tech Stack:** SVG 1.1, self-contained HTML, GitHub-flavored Markdown/HTML, Python standard library for deterministic synchronization checks, `xmllint`, Chromium or Playwright for rendering.

## Global Constraints

- Do not modify Swift sources, tests, build scripts, package configuration, or unfinished EZZK work.
- Keep standalone SVG files independently viewable and accessible.
- Keep `docs/gallery.html` self-contained with inline SVG and no JavaScript or remote runtime dependency.
- Use GitHub-compatible HTML only in `README.md`: tables, `<details>`, `<summary>`, `<kbd>`, `<code>`, and semantic blockquotes.
- Preserve the existing editorial palette, typography hierarchy, accessible SVG metadata, and supported product claims.
- Never use em dashes in README, SVG text, plan text, or commit messages.
- Keep orthogonal connectors, opaque label masks, distinct edge attach points, and no connector transit through non-endpoint boxes.
- Preserve the existing four-pixel coordinate grid where practical; do not solve collisions by making labels illegibly small.
- Do not overwrite or stage unrelated user EZZK changes.

---

### Task 1: Repair process diagram geometry

**Files:**
- Modify: `docs/diagrams/process-zako.svg`
- Later sync: matching inline SVG in `docs/gallery.html`

**Interfaces:**
- Consumes: existing eight-step process content and current three-lane layout.
- Produces: a standalone process SVG where external interaction labels and connectors are independently traceable and do not collide with lane captions or boxes.

- [ ] **Step 1: Capture the current visual baseline**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
print(Path('docs/diagrams/process-zako.svg').read_text())
PY
```

Rasterize the SVG with the repository read tool using `docs/diagrams/process-zako.svg:img`. Record the two known failures: the `requestEvidenceNumber()` label touching the external lane caption and the external connector route crowding the lower lane boundary.

- [ ] **Step 2: Move external request routing into open canvas**

Keep the request connector attached to the bottom edge of step 05, but route it through a distinct horizontal segment below the automation lane. Use a route equivalent to:

```svg
<path d="M648,372 V392 Q648,400 640,400 H128 Q120,400 120,408 V432" ... />
```

Use the existing blue dashed style and marker. Keep the route away from the lane caption at `y=412` and away from the CEZZK output box at the bottom right.

- [ ] **Step 3: Add a masked request label in open space**

Place an opaque paper mask above the open horizontal request segment, not over the lane caption:

```svg
<rect x="260" y="376" width="224" height="12" rx="2" fill="#f5f5f5"/>
<text x="372" y="385" text-anchor="middle" ...>requestEvidenceNumber() · serverTime()</text>
```

Keep at least six pixels between the mask bottom and the connector stroke. Use the existing technical font and blue link color.

- [ ] **Step 4: Separate and label CEZZK submission routing**

Keep the submission connector on the right side from step 06 to the CEZZK output. Move its label beside the vertical segment with a paper mask, leaving a visible horizontal gap from the stroke. Ensure the line terminates on the output box and does not touch the lane separator text.

- [ ] **Step 5: Rasterize and inspect the repaired standalone SVG**

Use `docs/diagrams/process-zako.svg:img` again. Confirm visually that no label touches a lane caption, no connector passes through a node, and both external routes remain distinguishable.

- [ ] **Step 6: Commit the focused diagram repair**

```bash
git add docs/diagrams/process-zako.svg
git commit -m "docs: repair process diagram routing"
```

Only stage this SVG. Do not stage the gallery until its synchronized copy is verified in Task 3.

---

### Task 2: Repair PDF/A pipeline geometry

**Files:**
- Modify: `docs/diagrams/pdfa-pipeline.svg`
- Later sync: matching inline SVG in `docs/gallery.html`

**Interfaces:**
- Consumes: existing PDF/A data-flow nodes and semantics.
- Produces: a standalone PDF/A SVG whose delivery connector reaches the output box from an open route instead of passing through its text.

- [ ] **Step 1: Capture the current visual baseline**

Rasterize `docs/diagrams/pdfa-pipeline.svg:img` and confirm the delivery line from `DORUČENIE` crosses the `PDF/A-2b + XML príloha` output box. Preserve the current content and node positions unless routing requires a small vertical adjustment.

- [ ] **Step 2: Route delivery around the output node**

Replace the direct `M672,328 H1040 V292` route with an orthogonal route below the output box, then into its left edge. Use rounded bends and keep the route above the footer note. A valid route shape is:

```svg
<path d="M672,328 H704 V392 Q704,400 712,400 H924 Q932,400 932,392 V340 Q932,332 940,332 H948" ... />
```

Terminate the marker at the output node's left edge. Do not draw the connector over the output fill or text.

- [ ] **Step 3: Check neighboring connectors and labels**

Keep the `EmbeddedFile` to output connector vertical and independent. If its marker or label becomes visually crowded after rerouting, move only the label into open canvas with a paper mask. Do not merge the delivery and embedded-file routes.

- [ ] **Step 4: Rasterize and inspect the repaired standalone SVG**

Use `docs/diagrams/pdfa-pipeline.svg:img` again. Confirm that the delivery connector is visible end to end, the output text is unobstructed, and the footer note remains clear.

- [ ] **Step 5: Commit the focused diagram repair**

```bash
git add docs/diagrams/pdfa-pipeline.svg
git commit -m "docs: reroute PDF/A pipeline connector"
```

Only stage this SVG.

---

### Task 3: Audit remaining diagrams and synchronize the gallery

**Files:**
- Review and modify only if needed: `docs/diagrams/hero.svg`, `architecture.svg`, `state-machine.svg`, `ai-vision.svg`, `finder-quick-action.svg`, `roadmap-open-work.svg`
- Modify: `docs/gallery.html`

**Interfaces:**
- Consumes: all eight standalone SVG files.
- Produces: eight inline gallery SVGs with matching accessibility metadata and geometry, with no duplicate IDs or invalid XML declarations inside HTML.

- [ ] **Step 1: Rasterize every remaining standalone diagram**

Use the repository read tool with `:img` for:

```text
docs/diagrams/hero.svg:img
docs/diagrams/architecture.svg:img
docs/diagrams/state-machine.svg:img
docs/diagrams/ai-vision.svg:img
docs/diagrams/finder-quick-action.svg:img
docs/diagrams/roadmap-open-work.svg:img
```

Inspect node boundaries, label baselines, connector endpoints, legend separation, and clipping. Modify a remaining SVG only when a concrete overlap, clipping issue, or unreadable connector is visible. Preserve its current semantics.

- [ ] **Step 2: Validate standalone XML before synchronization**

Run:

```bash
for f in docs/diagrams/*.svg; do xmllint --noout "$f" || exit 1; done
```

Expected: no output and exit status zero.

- [ ] **Step 3: Replace each gallery SVG with its standalone counterpart**

For each matching gallery card, replace only the inline SVG element through its closing `</svg>` with the current standalone file content. Preserve the surrounding `<section>`, `.card`, header, and tag markup. Remove any `<?xml ...?>` declaration from the inline Finder SVG because XML declarations are not valid inside an HTML body.

Use a deterministic local Python synchronization check after editing:

```python
from pathlib import Path
import re

html = Path("docs/gallery.html").read_text()
for svg_path in sorted(Path("docs/diagrams").glob("*.svg")):
    svg = svg_path.read_text().strip()
    slug = svg_path.stem
    if slug == "finder-quick-action":
        slug = "finder-quick-action"
    assert f'<svg ' in svg
    assert svg in html, f"gallery missing exact SVG: {svg_path}"
print("all standalone SVG bodies are present inline")
```

If exact body matching is not possible because the gallery wrapper intentionally changes whitespace, compare normalized SVG text after removing leading XML declarations and whitespace between tags. Do not use an external asset reference.

- [ ] **Step 4: Check inline SVG ID uniqueness**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import re
from collections import Counter
html = Path('docs/gallery.html').read_text()
ids = re.findall(r'\bid="([^"]+)"', html)
duplicates = sorted(k for k, v in Counter(ids).items() if v > 1)
assert not duplicates, duplicates
print(f'{len(ids)} unique inline IDs')
PY
```

Expected: no assertion failure.

- [ ] **Step 5: Render the gallery in Chromium**

Serve the repository root with a local static server and open `docs/gallery.html` in Chromium or Playwright. Capture the full-page render and inspect all eight cards. Confirm the repaired process and PDF/A diagrams match their standalone render and no other card has clipping or overlap.

- [ ] **Step 6: Commit synchronized diagrams and gallery**

```bash
git add docs/diagrams docs/gallery.html
git commit -m "docs: sync diagram gallery sources"
```

Before committing, confirm the staged set contains documentation diagram files only.

---

### Task 4: Enrich README with GitHub-safe HTML

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: current README facts, relative links, and existing Slovak product terminology.
- Produces: a richer, scannable README that remains fully readable as Markdown and renders with GitHub-supported HTML.

- [ ] **Step 1: Preserve the existing factual baseline**

Keep the current claims for macOS 27, Swift 6, 233 tests, 3 skipped, 0 failures, batch signing, AI Vision modes, recent documents, collision-safe naming, PDF/A-2b, EZZK pilot boundaries, and open follow-ups. Do not claim production EZZK interoperability or complete external PDF/A certification.

- [ ] **Step 2: Add a compact status and navigation panel**

Immediately after the hero image and title, add a centered status table using `<code>` labels and relative anchors. Include links to:

- Čo aplikácia rieši
- Pracovné režimy
- AI Vision
- PDF/A a osvedčovacia doložka
- Finder Quick Action
- Architektúra
- Životný cyklus evidencie
- Zostavenie, testy a lokálna inštalácia

Keep the table short enough to scan on a laptop and do not add remote badges.

- [ ] **Step 3: Reframe compliance caveats in a collapsible block**

Move the long compliance note into a `<details>` block with a `<summary>` such as `Compliance a produkčné hranice`. Keep the warning visible in the default collapsed summary and preserve all existing references to the P2E findings and OAuth plan.

- [ ] **Step 4: Add capability and boundary tables**

Add one table that distinguishes current functionality from its boundary, for example:

```html
<table>
  <thead>
    <tr><th>Oblasť</th><th>Aktuálne</th><th>Hranica</th></tr>
  </thead>
  <tbody>
    <tr><td><code>Podpisovanie</code></td><td>KEP, PAdES, QTS, ASiC-E, dávka</td><td>Vyžaduje dostupnú podpisovú identitu</td></tr>
    <tr><td><code>ZaKo</code></td><td>Analýza, AI Vision, doložka, PDF/A-2b</td><td>P2E pilot, externá validácia zostáva potrebná</td></tr>
    <tr><td><code>EZZK</code></td><td>Mock a guarded OAuth2 transport</td><td>Sandbox receipt a produkčný POST kontrakt otvorené</td></tr>
  </tbody>
</table>
```

Adapt wording to the current README and do not duplicate the same long explanation in several sections.

- [ ] **Step 5: Improve shortcut and privacy presentation**

Use `<kbd>⌘O</kbd>` and `<kbd>⌘⏎</kbd>` in the signing workflow. Add a short blockquote or table row that distinguishes on-device, local-network, and cloud AI processing, including the existing warning that custom cloud APIs may receive document images.

- [ ] **Step 6: Add an explicit open-work block**

Use `<details>` for the release blockers already listed in the roadmap: native OAuth callback, EZZK sandbox smoke test, exact POST/receipt/idempotency contract, signed ASiC record workflow, official P2E v1.3 artifacts, accessibility pass, AppKit visual-signature overlay, 20-hour CEZZK warning, and external PDF/A validation. Link to `docs/diagrams/roadmap-open-work.svg` and the editable Excalidraw source.

- [ ] **Step 7: Check README links and whitespace**

Run a relative-link check that resolves every local Markdown and image link from the repository root. Then run:

```bash
git diff --check
```

Expected: all local links resolve and no whitespace errors are reported.

- [ ] **Step 8: Commit the README update**

```bash
git add README.md
git commit -m "docs: enrich Autogram README"
```

Only stage `README.md`.

---

### Task 5: Final verification and delivery

**Files:**
- Verify: `README.md`, `docs/gallery.html`, `docs/diagrams/*.svg`

**Interfaces:**
- Consumes: the repaired and committed documentation files.
- Produces: rendered evidence and a clean documentation-only final diff ready for delivery.

- [ ] **Step 1: Run standalone SVG XML validation**

```bash
for f in docs/diagrams/*.svg; do xmllint --noout "$f" || exit 1; done
```

Expected: exit status zero.

- [ ] **Step 2: Run diagram accessibility and self-contained checks**

Run the installed diagram self-check against the gallery:

```bash
python3 /Users/Magneto/.claude/skills/diagram-design/scripts/self_check.py docs/gallery.html
```

If the repository contains a geometry verifier, run it against every standalone SVG. Report the actual path used and its result. Do not invent a verifier if it is absent.

- [ ] **Step 3: Perform visual verification**

Rasterize all eight standalone SVGs and render the complete gallery in Chromium. Inspect at least the reported process and PDF/A collision regions at the final display size. Confirm the README hero, tables, details blocks, and diagram links render without broken HTML structure.

- [ ] **Step 4: Confirm repository scope**

Inspect the final changed-file list and verify that only the README, gallery, diagram SVGs, and the approved design and plan documents changed. The user's unfinished EZZK files must remain unstaged and uncommitted.

- [ ] **Step 5: Run final whitespace check**

```bash
git diff --check HEAD~1..HEAD
```

Expected: no output and exit status zero for the final documentation commit range.

- [ ] **Step 6: Push the documentation refresh if still required by the original request**

```bash
git push origin main
```

Report the actual commit IDs pushed and explicitly note any unrelated user changes left untouched.
