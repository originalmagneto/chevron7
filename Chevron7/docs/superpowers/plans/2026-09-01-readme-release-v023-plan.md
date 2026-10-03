# README and v0.2.3 Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enrich the existing Autogram macOS README, verify the current application, and publish v0.2.3 with the I.CA SecureStore fix.

**Architecture:** Keep the existing Slovak README, SVG diagram gallery, Swift package, and shell-based app assembly. Add documentation presentation only in README.md and preserve the current release packaging flow, including the bundled Java helper patch applied by build_app.sh.

**Tech Stack:** Markdown, GitHub HTML/ Mermaid, Swift 6, SwiftPM, macOS 27, Xcode 27, shell, create-dmg, GitHub CLI.

**Spec:** Approved chat scope: README enrichment, existing diagram presentation, I.CA feature documentation, v0.2.3 patch release.

## Global Constraints

- Keep README end-user copy in Slovak and code comments in English.
- Never add secrets, PINs, or personal certificate data.
- Preserve existing SVG diagrams and links.
- Do not add new runtime dependencies.
- Do not use em dashes in new text.
- Verify the app build, tests, bundle, and release artifact before claiming completion.

---

### Task 1: Audit README and release inputs

**Files:**
- Read: `README.md`, `docs/diagrams/*`, `Autogram/build_app.sh`, `Autogram/Assets/LegacyEnginePatches/*`
- Inspect: current version metadata, GitHub remote, release tooling

- [ ] Confirm current README language, feature claims, diagram paths, and missing release details.
- [ ] Confirm current version is 0.2.2 and target is 0.2.3.
- [ ] Confirm `gh`, `create-dmg`, and release signing prerequisites available.

### Task 2: Update README presentation

**Files:**
- Modify: `README.md`

- [ ] Add polished HTML badges and a compact capability header.
- [ ] Add feature descriptions for signing, I.CA SecureStore, ASiC-E inspection, ZaKo, AI Vision, PDF/A, evidence, Finder Quick Action, and EZZK boundaries.
- [ ] Add keyboard shortcut and workflow tables.
- [ ] Add one Mermaid architecture flow while preserving the existing SVG gallery.
- [ ] Document that trusted-list validation and structural inspection are separate states.

### Task 3: Verify documentation

**Files:**
- Verify: `README.md` links and referenced diagrams

- [ ] Check every README-local link target exists.
- [ ] Check Mermaid and HTML blocks are closed and renderable.
- [ ] Check new text contains no em dashes or unsupported claims.

### Task 4: Prepare and verify v0.2.3

**Files:**
- Modify: release metadata only if required by current project conventions
- Build: `Autogram/build_app.sh`

- [ ] Commit README and any required release metadata with the existing source fixes.
- [ ] Run `swift test`.
- [ ] Build the release app with Xcode 27.
- [ ] Verify bundle contents, code signature, version, and helper patch entry.
- [ ] Create a DMG using the available project release tooling.

### Task 5: Push and publish release

**Files:**
- Git commit and tag: `v0.2.3`

- [ ] Push the branch and tag to `origin`.
- [ ] Create the GitHub release with the DMG and concise release notes.
- [ ] Verify the release URL and uploaded asset.
