# README and diagram refresh design

## Goal

Improve the documentation surface of Autogram macOS without touching the unfinished EZZK implementation. Repair visible diagram collisions, keep standalone SVG files and the self-contained gallery aligned, and make `README.md` richer while remaining safe for GitHub rendering.

## Scope

### In scope

- Audit and repair all eight diagrams in `docs/diagrams/`.
- Treat standalone SVG files as the source of truth.
- Synchronize the inline SVG copies in `docs/gallery.html`.
- Remove connector and label collisions, including the reported issues in:
  - `process-zako.svg`
  - `pdfa-pipeline.svg`
- Preserve the existing editorial palette, typography hierarchy, accessible SVG metadata, and content claims.
- Enrich `README.md` with GitHub-compatible HTML elements and clearer information architecture.
- Verify SVG XML, accessibility metadata, geometry, rendered gallery output, relative links, and whitespace cleanliness.

### Out of scope

- Changes to Swift sources, tests, build scripts, package configuration, or EZZK behavior.
- New product claims not supported by the current repository state.
- Replacing inline SVG with external `<img>` references in the gallery.
- Introducing a frontend build step, stylesheet dependency, JavaScript, or remote runtime dependency.

## Diagram design

### Source and synchronization model

Each file in `docs/diagrams/` remains independently viewable and accessible. The gallery keeps inline SVG so it remains self-contained. After editing standalone SVG, the corresponding gallery section will be replaced with the same SVG body and metadata, while preserving the gallery card wrapper.

### Geometry rules

- Use orthogonal connectors only, with rounded bends where a bend is required.
- Keep connector labels off the stroke with an opaque paper mask and visible spacing.
- Use distinct attach points when multiple connectors meet one box edge.
- Route connectors around non-endpoint boxes.
- Keep the legend outside the active diagram area at the bottom.
- Preserve the existing four-pixel coordinate grid where practical and avoid shrinking labels as a workaround.

### Targeted repairs

`process-zako.svg`:

- Move the EZZK request label away from the external lane caption.
- Add masks to connector labels.
- Separate the two external interaction routes and keep their endpoint markers readable.
- Ensure the authorization and conversion connectors terminate at their real endpoint edges without visually touching unrelated elements.

`pdfa-pipeline.svg`:

- Route the delivery connector around the `PDF/A-2b + XML príloha` output box instead of through its text.
- Keep the output marker on the true endpoint edge.
- Preserve the semantic sequence: conversion, hash, XML, embedded file, normalization, validation, output.

Other diagrams:

- Repair only confirmed overlaps, clipping, or unreadable connector relationships found during raster inspection.
- Do not rewrite correct content merely for stylistic variation.

## README design

The README will remain readable in plain Markdown and will use only broadly supported GitHub HTML constructs:

- A compact project status panel using tables, `<code>` labels, and linked section navigation.
- `<details>` and `<summary>` for compliance and production-readiness caveats.
- `<kbd>` for macOS shortcuts.
- Tables for module capabilities, inputs, outputs, and validation boundaries.
- Explicit separation of currently usable functionality, demo or pilot boundaries, and open interoperability blockers.
- Highlighted privacy and fail-closed behavior without changing technical meaning.
- Diagram links placed beside the relevant workflow sections.

The README will not depend on custom CSS, JavaScript, generated badges, or remote image services. Existing relative links and Slovak end-user language remain intact.

## Verification

Run these checks after implementation:

1. Rasterize every standalone SVG and inspect the repaired regions.
2. Render `docs/gallery.html` in Chromium and inspect every diagram card.
3. Run `xmllint --noout` over all standalone SVG files.
4. Run the available diagram accessibility and self-contained checks over `docs/gallery.html`.
5. Verify relative README links resolve.
6. Run `git diff --check`.
7. Confirm no files outside the documentation scope changed.

Success means no visible connector, label, or node overlap in the standalone diagrams or gallery, all eight diagrams remain present and accessible, and the README presents the current product state with richer structure but no unsupported claims.
