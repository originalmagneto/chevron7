---
name: Chevron7 website
description: The public homepage of Chevron7 (qualified electronic signatures, native on the Mac), set in one amber light on a midnight ground.
colors:
  ink-0: "#0a0b1a"
  line: "rgb(214 219 229 / 0.14)"
  line-strong: "rgb(214 219 229 / 0.32)"
  text-0: "#f5f5f7"
  text-1: "#d6dbe5"
  text-2: "#bec8dc"
  text-3: "#8d97ab"
  white-hot: "#ffffff"
  pip-dim: "#6b7080"
  rule-grey: "#777c94"
  amber: "#ffb23e"
  amber-hot: "#ffd27a"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Atkinson Hyperlegible Next', 'Segoe UI', sans-serif"
    fontSize: "clamp(48px, 7.3vw, 96px)"
    fontWeight: 700
    lineHeight: 0.98
    letterSpacing: "-0.035em"
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Atkinson Hyperlegible Next', 'Segoe UI', sans-serif"
    fontSize: "clamp(38px, 4.9vw, 76px)"
    fontWeight: 700
    lineHeight: 1.04
    letterSpacing: "-0.025em"
  lead:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Atkinson Hyperlegible Next', 'Segoe UI', sans-serif"
    fontSize: "clamp(18px, 1.5vw, 23px)"
    fontWeight: 400
    lineHeight: 1.45
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Atkinson Hyperlegible Next', 'Segoe UI', sans-serif"
    fontSize: "19px"
    fontWeight: 700
    letterSpacing: "-0.01em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Atkinson Hyperlegible Next', 'Segoe UI', sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Atkinson Hyperlegible Next', 'Segoe UI', sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.45
rounded:
  pill: "999px"
  focus: "6px"
  track: "3px"
spacing:
  gutter: "clamp(20px, 6.38vw, 98px)"
  section: "clamp(96px, 12vw, 184px)"
  container: "1360px"
components:
  button-primary:
    backgroundColor: "{colors.text-0}"
    textColor: "{colors.ink-0}"
    rounded: "{rounded.pill}"
    padding: "0 26px"
    height: "52px"
  button-primary-hover:
    backgroundColor: "{colors.white-hot}"
    textColor: "{colors.ink-0}"
  button-outline:
    backgroundColor: "transparent"
    textColor: "{colors.text-0}"
    rounded: "{rounded.pill}"
    padding: "0 26px"
    height: "52px"
  nav-cta:
    backgroundColor: "{colors.text-0}"
    textColor: "{colors.ink-0}"
    rounded: "{rounded.pill}"
    padding: "0 16px"
    height: "34px"
  nav-link:
    textColor: "{colors.text-1}"
  nav-link-hover:
    textColor: "{colors.text-0}"
---

# Design System: Chevron7 website

Scope: this file describes the visual system of the public website only (the Astro site in `website/`, Slovak homepage and its English mirror). The macOS app's own SwiftUI interface (Liquid Glass, `DesignSystem.swift`) is documented in `CLAUDE.md` / `AGENTS.md`, not here.

## Overview

**Creative North Star: "The Moment the Seventh Chevron Locks"**

The site is a dark room lit by one lamp. A near-black midnight ground carries cool white type at very large sizes, and the only warm light on the page comes from the lit seventh chevron and the glass app icon, which casts amber down onto a real app window. The product is shown as itself: real captures from the app (DEMO mode, labeled), never an illustrated interface.

Density is low and the pace is Apple-product-page slow: one idea per section, big bold headlines, short leads, then a real screen. Structure comes from hairlines, short grey rules and changes of ground, not boxes. There are no cards and no feature grid of icons; text sits directly on the ground. The one tinted, rounded surface is the media stage: the panel a gallery gives each real app recording or capture (see The Media Stage Rule).

Motion tells a single story. On load seven chevrons on an arc over the glass icon engage one by one, alternating sides from the outside in: each slides in, lands with a small overshoot, flashes amber and settles to white; the seventh locks at the top and keeps the amber, then the icon ignites and its light lands on the window. Scrolling lifts and flattens the window, headlines rise into place, galleries glide in, icons trace themselves, the flow diagrams send packets along their chains, and the relay's time track fills and drains. The default state is always the final, fully visible one.

**Key Characteristics:**
- Midnight ground, cool white type in four quiet steps, one amber light source.
- Seven chevron pips as the one recurring mark; the seventh is always the lit one.
- Real app windows as the product imagery, lifted by soft drop shadows.
- Pill buttons in a white-primary / hairline-outline pair.
- Hairline dividers and short grey rules instead of cards; chapters change the ground (Midnight and Deep Indigo alternate).
- Real app recordings play in horizontal galleries of large media stages, one control pill each.
- Motion that lands on the locked state and is skipped entirely under reduced motion.

## Colors

A cold, nearly monochrome midnight palette with a single warm accent that behaves like light rather than paint.

The direction contract named a ground of #070A14 to #0B1020 and a warm white of #F5F3EE; the build shipped a slightly bluer ground (ink-0) and Apple's cooler white (text-0). The shipped values are the system. The stylesheet also defines #0e1122 and a deep amber (#c77a12) that no rule uses; they are not tokens.

### Primary
- **Seventh-Chevron Amber** (amber): the one light source. Used only for the lit seventh pip, the keyboard focus ring, text selection, the support link hover, and as the tint of glow filters (window underglow, pip halo). It never fills a button or a section.
- **Filament** (amber-hot): the small dot above the seventh chevron, the hottest point of the light.

### Neutral
- **Deep Indigo** (ink-2, #151839): the lifted chapter ground (privacy and download chapters) and the media stage.
- **Night Floor** (#07081a): the footer ground, one step below Midnight.
- **Midnight** (ink-0): page ground, `theme-color`, nav glass base, and the halo ring that cuts stage dots out of their rule. The hero's faint radial lift is a one-off gradient on this ground, not a separate token.
- **Signal White** (text-0): headlines, titles, primary pill fill, emphasized inline text.
- **Mist** (text-1): nav links, the privacy statement, the active language.
- **Haze** (text-2): section leads, sublines, secondary links.
- **Dusk Grey** (text-3): body copy under titles, notes, spec line, captions, footer.
- **Pure White** (white-hot): hover state of the white pill only.
- **Unlit Chevron** (pip-dim): stroke of the six unlit pips and the Zarucena konverzia stage dots.
- **Rule Grey** (rule-grey): the short 40px bar above column titles.
- **Hairline** (line) and **Strong Hairline** (line-strong): dividers, footer rule, outline pill border, stage rule.

### Named Rules
**The One Light Rule.** Amber is light, not a brand fill. It appears only where the seventh chevron or its glow lands, plus focus and selection. A second accent hue, or amber on a button or background, breaks the world.

**The Quiet Steps Rule.** Hierarchy among text is carried by the four white steps (text-0 to text-3), never by color.

## Typography

**Display Font:** the Apple system grotesque (SF Pro Display / SF Pro Text via `-apple-system`), with self-hosted Atkinson Hyperlegible Next (400, 500, 700) as the fallback for non-Apple platforms, then Segoe UI.
**Body Font:** the same stack.

**Character:** one grotesque family at all sizes, bold and tightly tracked at display sizes, plain at reading sizes. The contrast comes from size and weight, not from a second family.

### Hierarchy
- **Display** (700, up to 96px, 0.98, -0.035em): the one statement per page ("Dokumenty ostávajú na vašom Macu."). The hero headline is its own comp-measured instance (700, 4.883cqw on 5.208cqw, -0.02em, about 75px at 1536 wide).
- **Headline** (700, clamp(38px, 4.9vw, 76px), 1.04, -0.025em): section titles, max about 16ch, balanced wrap. Sub-headlines step down through clamp(36px, 3.9vw, 60px), clamp(30px, 3.2vw, 48px) and clamp(28px, 2.8vw, 40px).
- **Lead** (400, clamp(18px, 1.5vw, 23px), 1.45, Haze): one short paragraph under a headline, max about 40ch.
- **Title** (700, 19px, -0.01em; larger steps at clamp(21px, 1.8vw, 26px) and clamp(22px, 1.9vw, 28px)): feature, step and stage titles.
- **Body** (400, 15 to 17px, 1.5 to 1.6, Dusk Grey): copy under titles, max 34 to 52ch.
- **Label** (400, 13 to 14px, 1.4 to 1.55, Dusk Grey): notes, captions, spec line, footer credits.

Weights in use: 400, 500 (brand wordmark), 600 (buttons, privacy statement, small headings), 700 (all headings).

### Named Rules
**The Size Not Style Rule.** Emphasis is size, weight and white step. Tracking tightens with size, from -0.01em at 19px titles to -0.035em at display; body, leads and labels stay at normal tracking and in sentence case.

## Layout

Two layout regimes share one gutter (clamp(20px, 6.38vw, 98px)).

The first viewport (nav, hero, the three "Kartou / Mobilom / V Safari" columns) is measured from the approved comp: absolutely placed elements in container-query units against a 1536-wide stage (aspect ratio 1536 / 852). Below a 760px container it becomes a single column in the same order: headline, subline, pills, spec line, icon, window, pips.

Everything after the hero is fluid: each section has top padding clamp(96px, 12vw, 184px) and no bottom padding, content sits in a 1360px centered container, and splits use asymmetric fractional grids (8 : 3.4, 6 : 5, 5 : 7, 7 : 5) that collapse to one column between 900 and 1000px. Some sections center their heading block; most align left. Screens, not text blocks, take the wider column.

## Elevation & Depth

No box shadows are used for elevation and nothing is raised. Depth is light: raster light plates (the icon's amber glow, a glow and a screen-blended rim under the hero window), soft drop-shadow filters on real app captures, a faint radial lift in the hero ground, and the nav's glass, which fades in over the first 140px of scroll.

### Shadow Vocabulary
- **Capture lift** (`filter: drop-shadow(0 28px 44px rgb(0 0 0 / 0.5)) drop-shadow(0 4px 10px rgb(0 0 0 / 0.35))`): every real app screenshot below the hero.
- **Hero window** (`filter: drop-shadow(0 2.4cqw 3.2cqw rgb(0 0 0 / 0.55)) drop-shadow(0 1.6cqw 4cqw rgb(255 178 62 / 0.12))`): the tilted window under the icon; the amber term is the light landing.
- **Pip halo** (`filter: drop-shadow(0 0.1cqw 0.45cqw rgb(255 178 62 / 0.75))`): the lit seventh chevron only.
- **Nav glass** (`background: rgb(10 11 26 / 0.72); backdrop-filter: saturate(1.6) blur(18px)`, 1px bottom hairline at 0.08 alpha): the fixed header once scrolled.

### Named Rules
**The Media Stage Rule.** A gallery tile is a Deep Indigo stage (radius 28px, 20px on phones, a faint white lift at the top, 1px hairline ring) whose top is exactly one real app recording or capture, whole window, edge to edge, and whose bottom is a free band of 76px (56px on phones). The band carries the gallery's control pill (progress dots plus pause, Midnight glass). Nothing else may sit in a tinted or rounded box: text, lists and buttons stay on the ground.

**The Light Not Lift Rule.** Only real app captures and the lit chevron cast anything. Text and layout blocks stay flat on the ground.

## Shapes

Square by default. The only rounded forms are the full pill (999px) for every button and control pill, the 28px media stage (20px on phones), the 12px icon tile, the 6px radius of the focus ring, the 3px track, and circular dots and arrow buttons. Lines are 1px hairlines; the short column rule is a 40 by 3px bar (2px on phones). The chevron itself (an open "^" with round caps and joins, stroke 2.6 on a 20 by 16 box) is the signature silhouette.

## Components

### Buttons
Confident and quiet: a white pill leads, a hairline pill follows.
- **Shape:** full pill (999px).
- **Primary:** Signal White fill, Midnight text, weight 600, 52px tall with 26px side padding (48px on phones, comp-scaled in the hero).
- **Hover / Focus:** primary brightens to Pure White; outline gains a 0.6 alpha border and a 0.06 alpha fill; 200ms on the shared ease-out; active scales to 0.98; focus is the global 2px amber ring at 3px offset.
- **Outline:** transparent with a 1px Strong Hairline border and Signal White text; the GitHub variant carries the GitHub mark at 18 to 20px.

### Navigation
- A 2px white bar slides under the link of the section in view.
- Fixed, transparent over the hero, turning to Midnight glass as the page scrolls. Brand is the icon plus the wordmark at weight 500. Links in Mist, brightening to Signal White (160ms). Language switch in Dusk Grey with the current language in Mist. A small white pill CTA sits at the right. On phones the links hide and only brand, language and the CTA remain. A skip link appears as a white pill on focus.

### Chevron dial (signature)
Seven chevrons (the open "^", pointing outward) on an arc over the hero icon, at 0 and plus or minus 25, 50 and 75 degrees from the top. They engage in the order 75, -75, 50, -50, 25, -25, 0 at 420ms intervals: slide in 46px, overshoot 5px, flash amber, settle. Six settle to Mist; the seventh keeps Amber with a Filament dot and a glow. No ring, no glyphs, no other gate imagery. A one-line caption under the window fades in once the seventh locks.

### Flow diagram
Three real signing routes (card, phone, Safari) behind a segmented switch whose white thumb slides between them. Five steps each: a 72px Deep Indigo circle with a 30px line icon, a bold 17px label and a 15px Dusk Grey line. Hairline connectors draw in, icons trace themselves, and a white packet crosses the chain three times, pinging each node as it arrives; hover replays it. Vertical on phones.

### Way diagram
The three signing paths under the hero (Kartou, Mobilom, V Safari), drawn in the flow diagram's language on a 330 by 150 grid: three 52-unit Deep Indigo nodes with traced 24px line icons, 2px connectors that stop 5 units short of each node (never through an icon), Haze labels under the nodes and a Signal White label and ring on the last one, the signed document. In view it plays once: nodes arrive, connectors draw, a white packet crosses each connector, the signed document traces itself and rings. Hover replays it. No box around it; the drawing sits on the ground at the measure of the body text.

### Conversion figure
Beside the guaranteed conversion intro: a hairline Mac with a paper original inside (text lines, the cord with its seal, a signature, a stamp), a soft white scan that passes down the page, corner brackets that close around each security element as the scan reaches it, and outside the Mac a dim cloud whose dashed line stops at a cross. It carries the on-device AI promise visually; the promise itself is a ruled title on the ground next to it, never a tinted box. Plays once in view, replays on hover, stands finished without motion. Monochrome: amber stays with the seventh chevron.

### Real capture (Shot)
A responsive app screenshot (1x and 2x WebP) with the capture lift, no frame, no border, no device mockup around it.

### Ruled column title
A title preceded by the 40 by 3px Rule Grey bar, with a Haze sub-line and Dusk Grey body. Used for the three signing paths.

### Media gallery
A horizontal, snapping row of media stages (76% of the viewport up to 1040px, 86% on phones) with the next stage peeking at the right. The current stage plays: a recording runs to its end, a still capture holds for 6 to 7 seconds, then the gallery advances. On phones a still may use a phone crop of the same capture (for example the document stacked over its findings panel). Non-current stages sit at half opacity. The control pill rides in the current stage's bottom band: dots that stretch and fill white with progress, and a round pause/play button. Circular arrow buttons sit at the right, level with the captions. Captions sit under the stage: a bold Signal White lead-in sentence followed by Dusk Grey body in one 17px paragraph; numbers live in the sentence, never in chips. Nothing moves when the gallery is off screen, paused or under reduced motion.

### Stage line
Five stages as plain columns (Signal White title, Dusk Grey body) with no rule or dots; the order carries the sequence. Becomes two columns, then one, on narrow screens.

### Time track
A 3px rounded track (text-1 at 0.12 alpha) whose soft white fill empties from the left as it scrolls into view, with small labels below. Shows the relay copy's life on the phone path.

## Do's and Don'ts

### Do:
- **Do** keep amber for the lit seventh chevron, its glow, focus and selection (The One Light Rule).
- **Do** show the product through real app captures from DEMO mode, lifted with the capture drop shadow.
- **Do** pair a white pill with a hairline pill for calls to action, white first.
- **Do** separate content with 1px hairlines and the short 40 by 3px grey rule.
- **Do** make the final, locked state the default and add motion only under the `.motion` class, so reduced motion shows the finished page.
- **Do** use the four white steps for hierarchy: Signal White titles, Haze leads, Dusk Grey body.

### Don't:
- **Don't** add a second accent color or fill buttons and backgrounds with amber. The one exception is Buy Me a Coffee's own yellow button in the download chapter, shown unchanged as a third-party mark.
- **Don't** put text, lists or buttons in cards, tinted panels or bordered boxes; the ground carries them. The media stage exists only to hold a real recording or capture.
- **Don't** replace real captures with illustrated or invented app interfaces.
- **Don't** use more or fewer than seven chevrons, or light any chevron other than the seventh.
