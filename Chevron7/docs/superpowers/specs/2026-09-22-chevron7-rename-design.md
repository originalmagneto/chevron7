# Rename Autogram macOS to Chevron7

Date: 2026-09-22
Status: approved; planned in Chevron7/docs/superpowers/plans/2026-09-22-chevron7-rename.md; Phase A (repository) implemented on branch rename/chevron7

## Why

The product is becoming an EU-wide eIDAS signing application. Support for other
national eID cards (Czech, Hungarian, Polish, Slovene and further EU schemes) is
the intended direction, with the Slovak features (zaručená konverzia and the
EZZK register) demoted from peers of the signing core to one country module
among several.

The current name blocks that in three ways. It is the name of another party's
product, it is Slovak-specific, and it collides with that product in the
`autogram://` URL scheme, which the README records as a known limitation.

The new name is **Chevron7**, one word, no space. It is locked.

## Name rationale, recorded so it is not relitigated

Bare "Chevron" was rejected. Chevron Intellectual Property LLC holds roughly 918
marks, Class 9 is core to their portfolio, they hold class 9 software
registrations, and they publish a consumer iOS application called "Chevron".
Launching a class 9 macOS application under that exact word is not a defensible
position. The composite "Chevron7" showed no company, product, mark, application
or GitHub namespace collision.

"Chevron" survives as internal and in-app vocabulary, where it is a generic
heraldic term doing descriptive work.

Other candidates and why they are dead: Sigillum and Certum are both Polish
qualified trust service providers. Signi is a Czech electronic signature
platform backed by Česká spořitelna. Anything in the "autograph" family reads as
Autogram in disguise and implies an endorsement that does not exist.

### Vocabulary

A gate address is six coordinate glyphs plus a seventh point-of-origin symbol
identifying where the dialling happens. The seventh is the one that says who and
where, which is what a signing certificate is.

| Term | Meaning in Chevron7 |
| --- | --- |
| Glyph | A certificate, the symbol identifying a signer |
| Chevron | A step that locks in the signing flow |
| Chevron 7 | The signature itself: point of origin, the final lock |
| Iris | The trusted-origin gate in the Safari extension |
| Event horizon | The point at which the signature is committed |

Every one of these is a public-domain English, physics or heraldic term. The
following must never ship: "Stargate", Chappa'ai, DHD, ZPM, SG-1, character or
race names, and above all the gate ring artwork and the 39 glyph designs, which
are copyrighted art rather than words. The application icon must be original.

## Boundary: what is not renamed

Chevron7 is the product. Autogram is a dependency it talks to and a project it
descends from. The rename stops exactly at that line. A blind
`sed s/autogram/chevron7/` would break all five of the following.

1. **The AVM relay.** `https://autogram.slovensko.digital/api/v1` in
   `AVMClient.publicBaseURL`, the QR link host and the `X-Encryption-Key`
   header. The Autogram v mobile iOS application only opens links for that
   public host, so this is a hard external dependency owned by
   slovensko.digital. It never changes and it is not ours to change. This is the
   NFC phone-signing path.
2. **Slovak UI strings naming their product**, such as "Aplikácia Autogram v
   mobile otvára len odkazy z autogram.slovensko.digital", and the `AVM*` Swift
   type names (`AVMClient`, `AVMSigningSession`, `AVMResultMapper`). AVM stands
   for Autogram v mobile: keeping those names is both technically correct and
   honest attribution.
3. **The entire engine.** 265 Java files under `digital.slovensko.autogram.*`.
   Renaming would break future merges from upstream and muddy the licence trail
   for no benefit.
4. **The `org.autogram.asice` UTI**, declared with `UTType(importedAs:)`, so
   another application owns the type declaration. Renaming it would stop
   `.asice` files being recognised.
5. **The machine protocol**, which is the wire contract with the engine.

Addendum (2026-10-02): the old Autogram macOS bundle identifier also stays, in
`FinderQuickActionService.legacyBundleIdentifier` only. Autogram macOS is
another application now, and the Finder Quick Action cleanup looks it up by that
identifier before moving its old workflow to the Trash. `check-rename-boundary.sh`
requires the constant and allows exactly that line in `--strict`.

### Machine-enforced boundary

The boundary becomes a test rather than a promise:

- a test asserting `AVMClient.publicBaseURL` is exactly
  `https://autogram.slovensko.digital/api/v1`
- a check that no `chevron7` string has leaked into `engine/` or into the AVM
  host

A later refactor then cannot quietly break phone signing.

## What is renamed

| Layer | From | To |
| --- | --- | --- |
| Product | Autogram macOS | Chevron7 |
| Bundle identifiers (12) | `sk.autogram.*` | `app.slovensko.chevron7.*` |
| Mach service, LaunchAgent label | `sk.autogram.Autogram.webbridge` | `app.slovensko.chevron7.webbridge` |
| URL scheme | `autogram://` | `chevron7://` |
| Keychain services, UserDefaults keys | `sk.autogram.*` | `app.slovensko.chevron7.*` |
| Application Support folder | `~/Library/Application Support/Autogram` | `.../Chevron7` |
| Swift modules | `AutogramApp`, `AutogramKit`, `AutogramWebBridge`, `AutogramWebExtensionHandler`, `autogram-webbridge-agent` | `Chevron7*` |
| Installed bundle | `/Applications/Autogram macOS.app` | `/Applications/Chevron7.app` |
| Repository | `autogram-macOS` | `chevron7` |

Roughly 166 references in Swift sources, plus the scripts, the DMG, the Finder
Quick Action and the documentation.

The `sk.` prefix goes regardless: the premise of the rename is that this is no
longer a Slovak-only application.

**Decided 2026-09-22: `app.slovensko.chevron7`.** It is the reverse of
`chevron7.slovensko.app`, a subdomain of `slovensko.app`, which the author owns
(managed through Squarespace and Cloudflare). `chevron7.app` and `chevron7.eu`
were unregistered that day and were knowingly not bought. The trade-off was
accepted: "slovensko" returns to every identifier, and once a bundle identifier
is registered with the Apple Developer Program it is permanent. Changing the
prefix afterwards costs the same as performing this rename again.

The subdomain already names the product, so the application's bundle identifier
is the reversed domain itself, `app.slovensko.chevron7`, without a second
`Chevron7` segment; the web extension, Mach service, Keychain services and
UserDefaults keys hang below it (`app.slovensko.chevron7.WebExtension`,
`app.slovensko.chevron7.webbridge`, `app.slovensko.chevron7.ezzk.soap`,
`app.slovensko.chevron7.settings.v1`). The product website will live at
`chevron7.slovensko.app`; mobile signing does not depend on it and must never
point at it.

## Migration

The application has one user, who accepts re-entering credentials, so there is
**no migration code**. Renaming the bundle identifier and Keychain services
orphans the old state by design.

One one-off action preserves what is worth keeping: move
`~/Library/Application Support/Autogram` to `.../Chevron7`, carrying the
evidence register, the VisionBank learning data and the Output folder. The
evidence register matters most, because a conversion register is a legal record.

The EZZK credentials in the Keychain are re-entered by hand after the rename.

## Licensing and attribution

The name comes off, the credit goes up.

### Split licensing (option ii-a)

- `engine/` keeps **EUPL 1.2**, copyright upstream, unchanged. It is a fork of
  `slovensko-digital/autogram`.
- Everything else is **EUPL 1.2 under the project author's own copyright**.

Same licence on both halves, so there is no Article 5 compatibility question,
while authorship is split and documented. The boundary is already clean in the
tree: `engine/` is the fork, `Autogram/Sources` is the author's work.

EUPL was chosen deliberately over AGPL-3.0 and GPL-3.0, both of which are
Compatible Licences under the Article 5 Appendix and were available:

- its definition of "Distribute or Communicate" includes providing access over a
  network, closing the hole AGPL exists to close
- Articles 14 and 15 put applicable law and jurisdiction with the licensor's
  Member State, meaning Slovak law and a Slovak forum. GPL and AGPL have no
  jurisdiction clause
- it is drafted by the European Commission and equally valid in 23 languages,
  which suits an EU eIDAS tool

The intent is that the zaručená konverzia work cannot be taken proprietary and
must carry attribution. Note the limit, so it is not misremembered: copyleft
compels a distributor of a modified version to license it under the same or a
compatible licence and provide source. It cannot compel anyone to contribute
improvements back upstream.

### Derivative-work boundary

The split rests on the engine being a separate work. Supporting that: it runs as
a separate process with its own jlink runtime in `Contents/Helpers`,
communicating over the machine protocol. Cutting against it: it is bundled and
shipped as a single artifact. This is a deliberate judgment by the author, not
an incidental one.

### Files to add

- a root `LICENSE` (EUPL 1.2), which does not currently exist; the licence text
  is presently only at `engine/LICENSE`
- per-directory `LICENSE` files so the boundary is visible in the tree
- `NOTICE`: the engine is a fork of `slovensko-digital/autogram` under EUPL 1.2;
  mobile NFC signing runs on their Autogram v mobile service and relay; Chevron7
  is neither affiliated with nor endorsed by slovensko.digital
- SPDX headers naming the author in the files he wrote
- a README attribution section near the top, not in an appendix, plus a
  disclaimer that Chevron7 is unaffiliated with Chevron Corporation

## Execution order

Order matters. Two bundles claiming one identifier caused a full debugging
session on 2026-09-22.

1. **Tear down the old install first.** `launchctl bootout` the agent, delete
   its LaunchAgent plist, `lsregister -u` the old application, remove
   `/Applications/Autogram macOS.app`, unregister the old appex.
2. **Move the data folder** to `.../Chevron7`.
3. **Rename in the repository**: modules, identifiers, strings, scripts, docs,
   honouring the boundary above.
4. **Rename on GitHub** and update local remotes. No placeholder repository
   under the old name (decided 2026-09-22): GitHub redirects the old URL only
   while no repository takes that name, so a placeholder would end the redirects.
5. **Rebuild, reinstall, re-register the agent, re-enter the EZZK credentials.**

## Verification

- `pluginkit -m -i app.slovensko.chevron7.WebExtension -vvv`. The `-vvv` is
  required: without it the check passes while resolving to a wrong path, which
  produced a false verification on 2026-09-22
- LaunchServices resolves the new bundle identifier to the new bundle and
  nothing stale remains
- `grep -r "sk\.autogram"` returns nothing outside the boundary exclusions
- `safari-spike.sh` confirms the XPC transport
- full test suite green
- `swift run avm-probe` against the real relay: the direct regression test for
  the NFC path
- the evidence register opens with its records intact

## Out of scope

Two separate projects, each needing its own design:

- **Multi-country eID card support.** The reason for the rename, but months of
  work. Worth a research spike first on which national eIDs expose PKCS#11
  middleware for macOS arm64 and which are locked to Windows-only CSP, because
  the answer determines how much "EU-wide" the product can honestly claim.
- **Donations.** A Stripe Payment Link (Apple Pay, Google Pay and card, no
  backend) plus a GitHub Sponsors button via `.github/FUNDING.yml`. Intended to
  fund the Apple Developer Program membership, which would remove the ad-hoc
  signing friction: a Developer ID signature and notarization mean the Safari
  extension loads without Develop > Allow Unsigned Extensions on every restart.
