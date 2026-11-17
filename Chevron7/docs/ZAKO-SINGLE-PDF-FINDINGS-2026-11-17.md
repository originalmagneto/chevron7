# One PDF with the clause inside: rendering spike (2026-11-17)

Design: `docs/superpowers/specs/2026-11-17-zako-single-pdf-design.md` (5.3 asks for this note). This note covers Task 1 (clause pages from the official presentation) and the first veraPDF results; Task 2 (the engine's clause appender) adds its own results below.

## Blocker for the one-PDF output: the P→E `finalPDF` is not PDF/A

`zako-p2e-final.pdf` (engine test resource) is a real P→E new document: a one-page scan (a raster image drawn into an A4 page through `PDFPage(image:)`), `PDFAConverter.convert(.vectorPreserving)`, then `normalizeForDelivery` with the engine's `PdfaNormalize`. veraPDF 1.28.2 (greenfield, offline from `~/.m2`):

| Flavour | Result | Failed rules |
| --- | --- | --- |
| PDF/A-2B | not compliant | 6.2.8-3 (1x): an image dictionary carries `/Interpolate true` |
| PDF/A-3B | not compliant | 6.2.8-3 (1x); 6.6.4-2: XMP says part 2 (expected, the appender sets part 3) |

So today's delivered P→E PDF/A has only ever passed the in-house marker check (`PDFAValidator`), as the design suspected. The image comes from the source page; neither `convert` nor `PdfaNormalize` drops `/Interpolate`. Revision 1 must stay a byte-exact prefix of the one-PDF output (its SHA-256 is the clause fingerprint), so neither the clause pages nor the appender can repair it: the normalizer has to set `/Interpolate false` (or remove the key) on every image before the fingerprint is taken. This also concerns today's ASiC-E output, whose PDF/A carries the same image. Whether real scans carry the key depends on the scanner software; PDFKit's own image pages do.

## Clause pages (`ClausePresentationRenderer`)

- XSLT: `/usr/bin/xsltproc --nonet -o clause.html form.xslt clause.xml` in a temporary folder, the stylesheet being `OfficialForm.presentation` (clause 1.3 `form.2.html2.xslt`, E→E clause 1.3 `form.19.html2.xslt`). Output to a file, not a pipe: the HTML is about 495 KB because the fonts (Open Sans as WOFF2) and images are inline `data:` URLs.
- Print: an offscreen borderless `NSWindow` (origin -20000, -20000) hosting a `WKWebView` of A4 size, non-persistent website data store, a `WKContentRuleList` compiled into a store in the temporary folder (`WKContentRuleListStore(url:)`, so nothing persists in `~/Library/WebKit`) with `[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]`, `loadHTMLString(html, baseURL: nil)`, and a navigation delegate that allows only `about:blank`. The `data:` fonts still load under the block-everything rule (the PDFs embed Open Sans and Open Sans Bold subsets).
- `printOperation(with:)` with `NSPrintInfo` A4 (595.2756 x 841.8898 pt), portrait, all margins 36 pt, `horizontalPagination = .fit`, `verticalPagination = .automatic`, `jobDisposition = .save` to a file in the temporary folder, `showsPrintPanel = false`, `showsProgressPanel = false`, `operation.view?.frame = webView.bounds`.
- Headless: `runModal(for: window, delegate:didRun:contextInfo:)` on the offscreen window completes inside XCTest (SwiftPM `xctest`, no NSApplication run). Without panels AppKit finishes the modal operation on a thread of its own (`-[NSConcretePrintOperation _continueModalOperationToTheEnd:]` on an `NSThread`), so the callback arrives off the main thread: a `@MainActor` callback trapped (`_dispatch_assert_queue_fail`). The callback lives on a small lock-guarded `NSObject` that resumes a continuation. `run()` was not needed.
- Injected CSS, before `</head>`: `<style>@page{size:A4} body{-webkit-print-color-adjust:exact}</style>`. The brief's `@page{size:A4;margin:0}` was dropped: WebKit lets the CSS margin override the print info, and the pages then printed up to about 4 pt from the paper edge (glyphs at y about 805 of 842). With the print info's 36 pt the text stays inside the page box inset by 30 pt, which `testLongClauseIsPaginatedWithDiacritics` checks for every glyph.
- Results: every page 595 x 842 (PDFKit rounds the media box); the test P→E clause prints on 2 pages, the E→E clause with 6 signatures and 4 timestamps each on 5 pages. WebKit breaks between rows, never inside a line; a section box may continue on the next page. The text layer extracts with diacritics ("Čuprík", "kancelária", "Osvedčovacia doložka").
- Scale: the form lays out at fixed widths (labels of 870 px), so `.fit` scales it to 0.567; body text (12 px) prints at about 6.8 pt, captions (16 px) at about 9 pt. Legible, small; a later change could set a narrower layout width, not done here.
- The output is PDF 1.3 from Quartz (`Producer` macOS Quartz PDFContext), fonts embedded as TrueType subsets (Open Sans, Open Sans Bold, Arial for the value fields).

## veraPDF on the clause pages

Alone (PDF/A-3B), both `clause-pages-p2e.pdf` and `clause-pages-e2e.pdf` fail:

- 6.2.10-2: page with transparency and no OutputIntent needs a page `/Group` with `/CS`;
- 6.2.8-3 (2x): two image XObjects with `/Interpolate true`;
- 6.6.2.1-1: no XMP metadata in the catalog.

Appended to `zako-p2e-final.pdf` (a quick `qpdf --pages` merge, which keeps the first file's catalog with its sRGB OutputIntent and XMP), 6.2.10-2 and 6.6.2.1-1 disappear, so they need nothing from the pages. What remains is 6.2.8-3 (3x: 1 from the final PDF, 2 from the clause pages) and 6.6.4-2 (part number, the appender's job); the merge also showed 6.1.7.1-1/-2 (stream `Length` and EOL), which come from qpdf's rewrite (the pages alone pass those rules) and do not concern the appender.

The two images are 5 x 25 px RGB with a soft mask, almost fully transparent, drawn 8 times at the right edge of the last page together with one glyph, so WebKit paints some invisible decoration of the form there. Neither `*{background-image:none; list-style-image:none}` nor `*{text-shadow:none}` removed them, and no other print CSS was added. The clause pages are new objects in revision 2, so the appender (Task 2) can set `/Interpolate false` on every image XObject it imports, which fixes 6.2.8-3 for the pages without touching the presentation.

## Fixtures (engine test resources, `engine/src/test/resources/digital/slovensko/autogram/core/`)

Written by `ClausePresentationRendererTests.testWriteEngineFixtures` (`CHEVRON7_WRITE_FIXTURES=1`, `CHEVRON7_JAVA_ENGINE_ROOT` set to a built engine's `Contents`; this run used the engine built in the main checkout on 2026-10-11, whose `PdfaNormalize` is unchanged since 2026-09-11):

- `zako-p2e-final.pdf`: the P→E new document above (1 page).
- `clause-p2e.xdcf`: the P→E clause 1.3 XDC whose fingerprint is the SHA-256 of `zako-p2e-final.pdf`.
- `clause-pages-p2e.pdf`: that clause's pages (2).
- `clause-pages-e2e.pdf`: an E→E clause 1.3 with 6 signatures and 4 timestamps each, office "Advokátska kancelária Čuprík, s. r. o." (5 pages).

## Task 2 results

(veraPDF PDF/A-3B of the appended and signed output: to be added by Task 2.)
