# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

This record covers the product website at `chevron7.slovensko.app`. The product itself is a native macOS app (SwiftUI, macOS 27+, Apple Silicon); the site presents and distributes it.

## Stack

Delegated, with a binding ambition from the owner: the site must be beautiful, dynamic, rich and motion-driven, use the most current capabilities of the modern web (graphics, visual effects, animation, advanced UI and UX), and work as a showcase of modern UI and UX design.

Choice: Astro (static output) for SK and EN routes, zero JavaScript by default and interactive islands only where motion or interaction earns it; native View Transitions and CSS scroll-driven animations first, a motion or WebGL library only where CSS cannot do the job. Reason: two languages, content pages (features, download, changelog, credits) and static hosting behind a subdomain, without giving up rich motion.

Hosting: undecided. Output is static, so any host that can serve `chevron7.slovensko.app` works.

## Users

Primary: anyone who signs with a qualified electronic signature (KEP) on a Mac. In practice that means people in Slovakia today, with an eID card, an I.CA or other PKCS#11 card, or an iPhone with Autogram v mobile, who sign PDFs and submit forms on state portals (slovensko.sk, nove.slovensko.sk, ORSR, Financna sprava).

Secondary: Slovak advocates doing guaranteed conversion (zarucena konverzia, ZaKo) under Act No. 305/2013 Z. z. with a mandate certificate and EZZK. For the site this is a module and a section, not the headline.

## Product Purpose

Chevron7 is a native macOS workbench for trustworthy legal documents: qualified signing, guaranteed conversion and a local register, in one local workflow. Nothing from a document leaves the Mac unless the user explicitly chooses a path that does (mobile signing relay, optional external AI models).

The site succeeds when a Mac user who needs to sign understands in seconds that this is the native way to do it on a Mac, trusts it enough to install it, and downloads it.

## Positioning

- Native to the Mac: SwiftUI throughout, Finder Quick Action, Keychain, Quick Look, a Safari extension. Not a Java desktop UI and not a web app.
- Local first: documents stay on the Mac; the signing engine runs as a local process.
- Signs on state portals from Safari over native messaging with no open HTTP port, with every request confirmed in a floating panel.
- Signs without a card reader: a QR code, an iPhone with Autogram v mobile and an NFC eID card.
- For advocates: guaranteed conversion with layered on-device AI detection of security elements and mandatory human review.
- Free and open source under EUPL-1.2.

## Operating Context

- Documents: PDFs mostly; outputs PAdES PDF, ASiC-E containers, XDCF on state portals, PDF/A-2b plus XML clause for ZaKo.
- Entry points: open or drop a file in the app, `Cmd+O`, Finder Quick Action on a PDF, batch signing, a signing request raised from a state portal in Safari.
- Signing devices: Slovak eID (BOK entered in the eID client's virtual keyboard), I.CA SecureStore, SAK advocate cards, Disig and other PKCS#11 tokens, Keychain identities, iPhone with Autogram v mobile over NFC.
- ZaKo workflow: import and origin confirmation, page analysis, AI-suggested security elements with mandatory review, attestation clause, authorization with a mandate certificate (which allocates the evidence number from EZZK and sends the signed conversion record to CEZZK), local register.

## Capabilities and Constraints

Shipped (per README, release v0.13.0 of 2026-09-24):

- Signing: KEP, PAdES, ASiC-E, qualified timestamp, visible signature, batch signing with one full DSS validation, safe cancel.
- Mobile signing through the Autogram v mobile app and the relay run by Slovensko.Digital; the server decrypts the document only in memory at signing and deletes it within 24 hours.
- Safari extension for state portals: the portal decides the format; confirmation required for every request, with a card or with a phone.
- Guaranteed conversion (ZaKo): 16 kinds of security elements, three-layer on-device detection (candidates, feature-print kNN plus on-device Foundation Model, human review), learning from confirmed and rejected findings, Create ML export, PDF/A-2b, clause, mandate certificate, EZZK evidence numbers.
- EZZK: production and test environments work with the advocate's own EZZK account: the evidence number is allocated at authorization, the signed conversion record is sent to CEZZK and its processing state shows in the register. A guaranteed conversion needs a card with a mandate certificate.
- Register: local records, status filter, search, CSV export.
- Zero Swift package dependencies; signing engine bundled with its own Java runtime.

Requirements: macOS 27 or later, Apple Silicon (the bundled engine runtime is arm64).

Terminology: KEP (kvalifikovany elektronicky podpis), eIDAS, eID, BOK, ZaKo (zarucena konverzia), EZZK / CEZZK, mandatny certifikat, osvedcovacia dolozka. Slovak for end-user strings, English version alongside.

Undecided or not yet true, and must not be claimed:

- Support for other national eID cards (CZ, HU, PL, SI and others) is the stated direction, not shipped. Czechia is researched and planned (`Chevron7/docs/research/2026-10-02-czech-signing.md`, plan in `Chevron7/docs/superpowers/plans/2026-10-02-czech-signing.md`); claim it only once it ships. Czech guaranteed conversion (autorizovaná konverze) cannot be offered: it runs only inside Czech POINT.
- GitHub repository is being renamed to `originalmagneto/chevron7`; release titles still read "Autogram macOS".
- Hosting provider for the site.

## Brand Commitments

- Name: Chevron7, one word, no space. Never bare "Chevron" in public copy.
- Voice (owner's decision, 2026-10-02): the site is marketing for advocates and other people who sign, who are not technical. Say what Chevron7 does for them in plain Slovak and English; no file formats (PAdES, XAdES, ASiC-E beyond ".asice"), ports, engines, processes, PKCS#11, licences, notarization, code signing or other build and infrastructure details in the copy. The download section may say the app installs in a minute and updates itself.
- No company names on the site (owner's decision, 2026-10-02): not Slovensko.Digital, Apple, the Software s.r.o. or Chevron Corporation. App and service names users need stay (Autogram v mobile, slovensko.sk, EZZK). The footer carries one neutral line instead of the former credits and disclaimers: Chevron7 is an independent project and its signing core builds on the open source Autogram project. Full attribution stays in the app's NOTICE and the repository.
- For advocates the strongest promise is confidentiality: the security element AI runs on the Mac (Apple Vision and the on-device Apple model, the default `builtInOnDevice` mode), nothing goes to a server or the cloud and the learning bank stays on the Mac; cloud AI only when the advocate turns it on. The site says this in a callout in the guaranteed conversion section. Keep it true: if the default ever changes, change the site.
- The hero offers only the download and the video; the source code is a quiet link in the download section, never a hero button.
- Nothing that implies the site or app is an official state or Slovensko.Digital product.
- The name comes from Stargate: the seventh chevron is the point of origin, where the connection comes from (Earth's is a pyramid with the sun above it). A qualified signature proves a document's origin, and Chevron7 signs locally, so the point of origin is the user's Mac. The owner wants this story in the background only (a quiet nod such as the seventh chevron locking at the moment of signing), never as the site's theme. An explicit section explaining the name was tried and rejected by the owner on 2026-09-23 as embarrassing: never explain the name on the site.
- Internal vocabulary may appear sparingly (chevron as a locked step, the seventh chevron as the signature itself, iris as the trusted-origin gate). Never use Stargate names, the gate ring artwork, the 39 glyph designs or any MGM property.
- Standing preference (2026-09-22): the website is Apple-style, native like the app, executed at the craft level of apple.com (macOS and Pro app pages), Things (Cultured Code) and Raycast. The owner chose this over the bolder rolled directions.
- New icon: original, inspired by the seventh symbol but not copying it: a lit, locked chevron with the point of origin above its apex, in the macOS 27 icon style. Never the literal pyramid-and-sun glyph.
- App icon: the current `Chevron7/Assets/AppIcon.iconset` is an Autogram-era render whose badge still carries the letter A. The owner wants a new original Chevron7 icon designed as part of the website's visual world (later adopted by the app); see the new icon line above. The README hero and diagrams in `docs/diagrams/` predate this site and are not binding.
- Owner-named failures: the site must not look like a state or government portal, must not read as a generic SaaS or AI landing page, and must not feel dry, papery or like a law firm.
- Voluntary support: Buy Me a Coffee at `buymeacoffee.com/chevron7`.
- Text rule: no em dashes anywhere; use hyphens, colons or parentheses.

## Evidence on Hand

- Product documentation: `README.md`, `docs/releases/v0.4.0.md`, diagrams in `docs/diagrams/` (architecture, AI vision, mobile signing, PDF/A pipeline, ZaKo process).
- GitHub releases v0.3.0, v0.3.1, v0.4.0.
- `design_assets/*.jpg` are early concept renders, not screenshots of the shipped app; do not present them as the product.
- No real app screenshots prepared for the site yet. Agreed: they are captured from the running app in DEMO mode (signing, Safari signing panel, ZaKo review) and the site's live demonstrations are built from them. DEMO signatures are not legally binding and must be labeled as such wherever they appear.
- No testimonials, user counts, press, partner logos, benchmarks or certifications exist. Do not invent any.

## Product Principles

1. Trust is the product: every claim on the site must be true of the shipped build today, with limits stated plainly.
2. Native Mac craft over feature lists: show how it feels to sign on a Mac, not only what it supports.
3. Local first and transparent about every exception (relay, optional external models).
4. Signing for everyone leads; advocate tools are a deep, clearly separate module.
5. Credit the open-source origins generously and never borrow authority from them.

## Accessibility & Inclusion

Owner requires heavy motion, so motion must respect `prefers-reduced-motion` with a complete static equivalent, keep content readable without JavaScript, and meet WCAG 2.2 AA. Slovak diacritics must render correctly in every chosen typeface.
