# Autogram macOS: security findings and speed suggestions

Date: 2026-09-15
Author: Grok (static code audit)

This is a static review of the Swift app, Safari web bridge, Java signing engine, Finder Quick Action, and build/install scripts. It is not a live pentest: parsers were not fuzzed, a machine was not exploited, and a live CVE feed was not queried.

Nothing in the reviewed paths signs a qualified signature without a human confirm (PIN panel, web prompt, or phone). The serious issues are confused-deputy / local MITM around that confirm, legal-status heuristics that can lie, and transport / App Transport Security holes. The biggest speed problem is unrelated: the UI keeps cold-starting the Java helper.

No em dashes are used in this document.

---

## Threat model (short)

| Attacker | What they can already do | What this audit is about |
|---|---|---|
| Same-user malware | Debug Autogram, skim PIN from helper stdin, replace unsigned binaries | Cheap Mach MITM, helper substitution, Quick Action `mdfind` |
| Network attacker | TLS intercept if a user CA is installed | `NSAllowsArbitraryLoads`, HTTP AVM / LLM / TSA URLs |
| Page on a matched portal (or XSS there) | Raise a signing prompt | Missing origin, no preview/hash, filename-as-path |
| Honest user, missing engine | Sign with Keychain | UI still says KEP |
| Advocate doing ZaKo | Must use a mandate cert | Heuristic treats personal I.CA QES as mandate |

Same-user malware that can debug Autogram can always skim a PIN from the helper stdin pipe. PKCS#11 middleware is trusted native code. AVM inherently gives Slovensko.Digital the document unless you encrypt client-side. XSS on slovensko.sk can always raise a signing prompt; origin plus preview only reduce that.

---

## Security findings

### High

#### 1. Web-bridge XPC is a public user Mach service (document swap is possible)

`sk.autogram.Autogram.webbridge` is looked up by any process in the same GUI session. The sandboxed Safari appex needs an entitlement; the agent and the app do not. Both listeners accept every connection, and `registerApp` is last-writer-wins with no code-requirement check.

```swift
// Autogram/Sources/autogram-webbridge-agent/main.swift:16-27
func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: WebBridgeRendezvousProtocol.self)
    connection.exportedObject = self
    connection.resume()
    return true
}

func registerApp(endpoint: NSXPCListenerEndpoint) {
    lock.lock()
    defer { lock.unlock() }
    self.endpoint = endpoint
}
```

The comment in `WebBridgeListener` that only the extension is entitled to look the service up is wrong. `webbridge-probe` already talks to the live app with no Safari involved.

Same-user malware can:

1. Steal the real endpoint, then replace it.
2. Forward a different document to the real prompt while keeping a convincing filename.
3. Launch Autogram on demand via `appEndpoint`.

The prompt still requires a PIN, but it shows filename, size, and kind only: no origin, no preview, no hash. `WebSignRequest` has no origin field.

**Fix**

- Check `auditToken` / designated requirement on every accept.
- Allow `registerApp` only from `sk.autogram.Autogram`.
- Allow `appEndpoint` / `sign` only from the appex.
- Put `origin` on the request, allowlist it in JS and Swift, and show origin plus a document preview or SHA-256 in `WebSigningSheet`.

#### 2. ZaKo mandate detection treats personal I.CA QES as a mandate cert

```swift
// Autogram/Sources/AutogramKit/Signing/JavaEngine/EngineBridgeSigningProvider.swift:522-529
static func isMandateCertificate(issuer: String, displayName: String, qualification: String? = nil) -> Bool {
    if isCommercialIssuer(issuer) { return false }
    let text = "\(issuer) \(displayName)".lowercased()
    if text.contains("oprávnenie") || text.contains("opravnenie")
        || text.contains("mandát") || text.contains("mandat") {
        return true
    }
    return qualification == "QESIG" && text.contains("qualified")
}
```

I.CA CNs look like `I.CA EU Qualified CA-SK/...`. A personal QESIG cert then sets `isMandateCertificate = true`, so `ZakoSessionStore.mandateRequirementSatisfied` passes without the override toggle. Tests use issuer `eID SR` (no `"qualified"`), so they stay green.

**Fix**

- Mandate only from `OPRÁVNENIE` / `mandát` and/or QC type OIDs / token driver.
- Add a negative test: issuer `I.CA EU Qualified CA-SK`, display name without `OPRÁVNENIE`.

#### 3. ATS is fully off; settings URLs are free-form

```xml
<!-- Autogram/build_app.sh:187-191 -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
```

TSA HTTP exceptions are redundant once arbitrary loads are allowed. AVM, Ollama/oMLX, OpenAI-compatible vision, custom TSA, and any future EZZK HTTP can all go cleartext or through a user-installed MITM CA. There is no pinning. `avmBaseURLValue` accepts `http`. Local LLM modes are not bound to loopback.

**Fix**

- Set `NSAllowsArbitraryLoads` to false.
- Keep HTTP exceptions only for the known RFC 3161 TSAs.
- Lock AVM to `https://autogram.slovensko.digital` in release.
- Bind oMLX/Ollama to `127.0.0.1` / `localhost`.
- Hide custom AVM URL behind a debug flag.

#### 4. AVM "encryption" is an access token, not client-side encryption; results are trusted as JSON

`AVMUploadRequest` sends raw file bytes as base64. `X-Encryption-Key` goes on every request, and the QR is `.../qr-code?guid=&key=`. Anyone who photographs the sheet (or a hostile `avmBaseURL`) can fetch the document.

After download, `AVMResultMapper` treats `signers[].signedBy` / `issuedBy` as ground truth. ZaKo mandate is a substring on those strings. The returned CMS/PAdES is not run through the bundled DSS `validate`.

The Settings copy that the document is encrypted with a key only this Mac knows does not match the wire format.

**Fix**

- Treat the QR as a secret.
- Restrict `guid` to a UUID pattern.
- Lock the host.
- After download, `engine.validate` the bytes against the uploaded digest and read mandate/QES from the certificate, not from JSON labels.
- Prefer client-side AES-GCM of the payload if the relay protocol can be extended.

#### 5. Missing Java engine silently becomes Keychain/DEMO, still shown as KEP

```swift
// Autogram/Sources/AutogramKit/Signing/SigningProvider.swift:432-440
public static func makeDefault() -> any QualifiedSigningProviding {
    if let installation = JavaEngineLocator().locate(),
       FileManager.default.isExecutableFile(atPath: installation.helperURL.path) {
        return EngineBridgeSigningProvider()
    }
    let hasRealIdentity = KeychainIdentityScanner.scanAll().contains { $0.hasPrivateKey }
    return hasRealIdentity ? KeychainXAdESSigningProvider() : DemoSigningProvider()
}
```

The Keychain path sets `isLegallyBinding: true`. The UI then shows "Kvalifikovaný elektronický podpis (KEP)". DEMO is honest; Keychain fallback is not. PKCS#11 also marks almost every token cert qualified (`looksQualified(...) || issuerCN != nil`).

**Fix**

- Refuse qualified / ZaKo flows unless the Java helper is present.
- Set `isLegallyBinding` from DSS qualification of the produced signature.
- Persistent "engine unavailable" banner.

#### 6. Helper / PKCS#11 overrides load unsigned code; `pkcs11-helper` inherits the full environment

`AUTOGRAM_CLI_HELPER` is tried before the bundled CLI. `PKCS11_MODULE_PATH` is `dlopen`'d with no signature check. `PKCS11BridgeClient` copies the parent environment and adds `DYLD_LIBRARY_PATH=/Library/AWP/lib`.

The Java helper correctly allowlists env (`HOME`, `TMPDIR`, locale only). `build_app.sh` ad-hoc signs with `codesign --sign -` and no `--options=runtime`.

**Fix**

- Ignore those env overrides in Release, or require a signed bundle path.
- Apply the same env allowlist to `pkcs11-helper`.
- Ship Developer ID + hardened runtime + notarization.
- Do not enable `allow-dyld-environment-variables` / `disable-library-validation` on the CLI helper if you can avoid it (those entitlements live on the upstream Java GUI recipe).

#### 7. Java HTTP signer still ships in the JAR (CORS `*`, no `key`/`nonce` check)

The Swift app uses `--cli --machine-readable` and does not start this. If anyone launches the Java GUI:

- `SERVER_ENABLED` defaults to true
- bind is `localhost:37200`
- CORS is `Access-Control-Allow-Origin: *`
- LaunchParameters `key`/`nonce` are parsed and never enforced
- after `batchStart`, later `/sign` calls reuse the cached key
- body size is unbounded (`readAllBytes()`)

**Fix**

- Do not start `AutogramServer` in this product; drop `jdk.httpserver` from the jlink image.
- If the GUI API must remain: explicit origins and a real session token.

#### 8. Finder Quick Action picks the first Spotlight hit for the bundle ID

`autogram-cli-sign.sh` searches `/Applications`, `$HOME/Applications`, then `mdfind` for `sk.autogram.Autogram`. No codesign / Team ID check. PIN is piped on stdin (good) to whichever helper wins.

**Fix**

- Resolve only the signed `/Applications/Autogram macOS.app` (or the host workflow's own bundle).
- Verify the designated requirement.

---

### Medium

| Issue | Where | Risk / fix |
|---|---|---|
| Web archive filename is attacker-controlled | `WebSigningCoordinator.swift:113-124` | `appendingPathComponent(stem)` without `lastPathComponent` / sanitizer. Use `ASiCEPackager.sanitizedFileName` and require the final URL under the output dir. Default `webSigningSavesLocally` is true. |
| Payload cap is late | `WebSigningCoordinator.swift:149-152` | 32 MB checked after JSON/base64 decode; eForm schema/XSLT not counted. Cap raw `Data.count` in background, appex, and XPC before decode. |
| Confirmation panel close does not cancel | `WebSigningPrompt` | Red close leaves `pending` set; later requests are `busy`; XPC hangs. `windowWillClose` -> `cancel()`. |
| Per-site disable is a no-op | `ditec.js` | `autogram-macos-set-enabled` is never handled; `window.ditec` is non-configurable. |
| Broad host matches + test UPVS in production extension | `manifest.json` | `*.slovensko.sk`, `*.financnasprava.sk`, `schranka.upvsfixnew.gov.sk`, `all_frames: true`. Explicit hosts; drop the fix environment from release. |
| Page-controlled `autoLoadEform` / `fsFormID` | web request -> engine | Can make DSS `CommonsDataLoader` fetch schemas. Ignore those flags unless the identifier is an allowlisted gov namespace. |
| App output overwrite / symlink | `SigningSessionStore` writes `_podpisane.pdf` with `.atomic` | Engine `OutputService` already uses `lstat`, `mkstemp`, `RENAME_EXCL`. Reuse it for UI/ZaKo/web archive. |
| PIN stays in `@Observable` `String` | `SigningSessionStore.signingPIN`, `lastCertificateLoadPIN` | Engine `Secret` zeroizes; UI does not. Clear after success/cancel; do not keep a second copy. |
| Visible "KEP" stamp before a verified signature | mobile appearance | Burns "Kvalifikovaný elektronický podpis" into the PDF before AVM returns. Stamp after DSS validation, from CMS subject. |
| Swift RFC 3161 client does not verify the TSA token | `RFC3161TimestampClient.parseResponse` | Parses PKIStatus only. Fine as a connectivity probe; do not use this path for `_T` without DSS. Built-in TSAs are `http://` (ecosystem constraint). |
| ASiC inflate / PDF raster bombs | `ASiCEVerifier.swift`, `PDFAnalysisEngine.swift` | `uncompressedSize` and extreme media boxes are uncapped. Cap entry size/count and rendered pixel area. |
| Evidence + VisionBank are plaintext | `~/Library/Application Support/Autogram/` | Attestation XML, page PNGs of legal scans. Dir mode 0700, exclude bank from backup, consider file protection. |
| LaunchAgent is a user-writable phone book | `install-webbridge-agent.sh` | Prefer `SMAppService`. Do not launch the app on `status()`, only on `sign`. |
| EZZK OAuth gaps (core flow is solid) | PKCE S256, constant-time state, redirect deny, Keychain | No ephemeral `ASWebAuthenticationSession`; custom scheme `autogram://`; issuer always production Keycloak; `productionAuthorityGate = false`. Dead `ezzk.password` / `HTTPSEZZKService` should be deleted. |
| Machine `INSPECT` follows symlinks | Java `MachineInspectionService` | `SIGN` uses `NOFOLLOW` + no overwrite. Reuse that for inspect. |
| eForm XPath string concat + generic URL fetch | `FsEFormResources`, `EFormResourceLoader` | Parameterize XPath; HTTPS + host allowlist; reject `full-path` with `://` or `..`. |
| Java GUI updater `open`s a DMG with no hash/codesign | `Updater.java` | Not on the Swift path, but it ships in the JAR. |
| ZaKo non-mandate override | `ZakoSessionStore.setMandateOverride` | Visible toggle, but no durable evidence field that it was used. |

---

### Low / residual

- Decoding errors and app version leak to the page over XPC.
- `ditec.checkPDFACompliance` / `convertToPDFA` always succeed (portal integrity lie).
- `getSigningTime` returns `new Date()`.
- Shared `URLSession` for AVM/LLM (cookies/cache); EZZK OAuth correctly uses ephemeral.
- Keychain `AfterFirstUnlockThisDeviceOnly` rather than `WhenUnlockedThisDeviceOnly`.
- Quick Action `find`/`mktemp` are not absolute-pathed; workflow `NSSendFileTypes` is `public.item`.
- Java `CliUI` caches PIN for the process lifetime.
- Transitive deps: HttpClient 4.5.14, commons-codec 1.11, Rhino 1.7.13. No Log4j-core. DSS 6.4, PDFBox 3.0.8, xmlsec 3.0.6, BouncyCastle 1.83 look current. Track DSS/PDFBox advisories.

---

### What is already in good shape

Do not "fix" these.

- Browser path is native messaging + XPC, not `localhost:37200`. Background worker is the only `sendNativeMessage` caller. Manifest matches are HTTPS state portals. One request at a time. PIN never on XPC.
- Java XML stack: `FEATURE_SECURE_PROCESSING`, no external DTD/schema/XInclude, `disallow-doctype-decl`, tests in `XMLUtilsTest`. Swift XML uses `nodeLoadExternalEntitiesNever`.
- Engine `SIGN` paths: absolute normalized paths, `O_NOFOLLOW`, `O_EXCL` / `RENAME_EXCL`, mode `0600`/`0700`. PIN on stdin JSON, not argv. Swift `Secret` + Java `Arrays.fill`. Token ops serialized. Machine mode requires QTSA and disables custom PKCS#11/keystore.
- EZZK: PKCE, constant-time state, fragment rejected, duplicate params rejected, HTTPS/host binding, redirect-blocking session, tokens in a dedicated Keychain service.
- DEMO provider labels itself and sets `isLegallyBinding: false`.
- No live API keys in the repo. AI keys and TSA credentials go to Keychain.
- Evidence store is JSON, not SQLite: no SQL injection.

---

## Efficiency and speed

These are from code structure plus typical Apple Silicon / jlink costs, not from a timed run on this machine. Highest leverage first.

### High-impact speed wins

#### 1. Stop cold-starting the JVM every few seconds (largest interactive win)

`CLIProcessRunner` starts `AutogramCLI-arm64`, then SIGKILLs it on the terminal JSON line. V1 `DRIVERS` / `CERTIFICATES` / `INSPECT` / `SIGN` all go through that. Cold jlink + DSS is typically 1.5-4 s per spawn.

The signing intake view polls identities every 3 s:

```swift
// Autogram/Sources/AutogramApp/Views/SigningFlowViews.swift:33-38
.task { await store.refreshIdentities() }
.task {
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await store.refreshIdentities()
    }
}
```

Driver-probe cache TTL is **2.5 s**. Identity cache is 6 s but keyed on that fingerprint. While Podpisovanie is open this is roughly one helper process every 3 seconds with no card change. `CardPresenceMonitor` already watches `TKTokenWatcher` and is unused.

A persistent v2 session already exists (`MachineSessionProcess.startIfNeeded`) and is used for `VALIDATE` / `PREVIEW` / some `SIGN`.

**Change**

- Route `drivers`, `certificates`, and `inspect` through that session.
- Drop the 3 s loop; refresh on token insert/remove.
- Raise driver TTL only as a fallback.
- Do not parallelize PKCS#11 (the permit is correct).

**Risk:** PIN/token exclusivity is already gated (`tokenOperationHeld`). Confirm v2 `DRIVERS` payload matches v1. Do not keep PIN material in the process after `CERTIFICATES`.

#### 2. Batch signature checks use v1 `INSPECT`, not the designed v2 `VALIDATE`

Design: `Autogram/docs/superpowers/specs/2026-08-31-batch-signature-validation-optimization-design.md`.

`engine.validate(files:)` (persistent helper, DSS trust-list cache, one request for N files) is implemented in `AutogramCLIEngine.swift:168-191` and never called from the provider. Preflight still calls `engine.inspect`, which is a new JVM and structural-only.

**Change:** Wire `inspectInputSignatures` to `engine.validate`. First VALIDATE in a session still pays TSL init (can be several seconds); after that a batch should be one TL load + N DSS validates.

**Risk:** Map missing `validation.completed` entries to unavailable, as the design requires.

#### 3. PDF/A normalize blocks the main thread and runs twice on ZaKo

`SigningSessionStore` / `ZakoSessionStore` are `@MainActor`. `PDFAConverter.normalizeWithEngine` uses `Process.waitUntilExit()` (another JVM). ZaKo normalizes, attaches XML, then normalizes again. `PDFAValidator` UTF-8-decodes the entire PDF twice.

**Change**

- Move convert/normalize/validate to `Task.detached` (copy `Data` / a fresh `PDFDocument`, do not share the UI document).
- One PdfaNormalize after the XML attach.
- Async `terminationHandler` instead of `waitUntilExit`.
- Scan XMP/OutputIntent on a tail window; stop decoding the whole file as UTF-8.

**Risk:** PDFKit is not thread-safe. Skipping the first normalize is safe only if the post-attach rewrite is the artifact you sign.

#### 4. Empty VisionBank makes Foundation Models the hot path

Default `useFoundationModelClassifier` is true. kNN needs `supportCount >= 3` and margin 0.25, so a new bank is always unsure. Up to 12 crops/page, **fresh `LanguageModelSession` per crop**, 8 s timeout. Pages in a chunk run concurrently, so several sessions contend. A 10-page scan can be tens of seconds to minutes, dominated by `foundationModelSeconds`.

**Change (in order of safety)**

1. Serialize FM through one actor. Keep page-level kNN/contour concurrent.
2. Skip FM when built-in `hintConfidence` is already high.
3. Lower the budget (3-5) until the bank has examples.
4. Do not attach every crop to one growing transcript (that constraint in the code is right).

**Risk:** (2) and (3) can miss odd elements. (1) is a latency win with little accuracy change.

#### 5. Pages are rasterized many times

`PDFAnalysisEngine.analyze` draws a 480 px gray bitmap twice (`inkCoverage` and `inkPixelCount`). Detection then renders 760 px color. The canvas renders 1240 px. LLM vision renders 640 px. ExampleBank records 1200 px. Thumbnails in `AnalysisCanvasView` are built inside `body` and rebuild on every `analysisProgressText` tick.

**Change**

- Merge the two gray passes into one function returning `(coverage, inkPixels)`.
- Cache thumbnails off the main thread; key the cache on the current document id.
- Reuse the 760 `PreparedPage` for LLM JPEG and, if quality allows, the canvas.
- Skip accurate OCR on pages already classified empty.

**Risk:** Sharing 760 with the canvas is a slight quality tradeoff.

#### 6. Batch PAdES pays N helper launches around a serial card

PKCS#11 must stay serial. The waste is CPU work around the card: per item, `PDFDocument(url:)`, optional 200 dpi PDF/A, `PDFAValidator` full-string scan, temp write, then a new v1 sign process unless appearance/eForm forces v2.

**Change**

- Prefetch the next file's PDF/A on a background task while the current file is on the token (window of 1-2 files).
- Use the persistent v2 session for every batch sign.
- Combined ASiC (one sign) is already the better path.

**Risk:** Prefetch memory for 200 dpi rasters. Do not parallelize the token.

---

### Medium speed wins

- Skip accurate OCR when fast OCR + ink say the page is empty.
- Stream-scan `/FT/Sig` instead of loading + UTF-8-decoding whole PDFs in the structural fallback.
- `PKCS11BridgeClient` `Thread.sleep(0.05)` on the caller; `PKCS11Module` sleeps 0.3 s on init. Prefer the engine path only.
- Cap/evict ExampleBank; kNN is a linear scan of the snapshot (snapshot-per-run is already correct).
- `ImageToPDFConverter` builds one PDF per image then merges: write once into a single PDF context.
- Evidence JSON rewrite is fine until the register is large.
- Contour + saliency re-run Vision on the same `CGImage` after OCR; skip if built-in already covered the region.
- After FM timeout, abandoned `respond` tasks can pile up: wait/cancel before the next crop.

---

### Do not "optimize"

- One shared render + fast OCR + accurate OCR into `PreparedPage` for built-in / contour / saliency / classify.
- Chunked pages so peak bitmaps scale with `maxConcurrentPages`.
- kNN before FM, candidate quality filter, hinted-first budget, bank snapshot per run, FM timeout.
- Token-operation serialization.
- AVM 1 s poll with `If-Modified-Since` / 304.
- JPEG raster PDF/A (quality 0.82) instead of raw bitmaps.
- Identity cache (6 s) and driver cache (2.5 s) as an idea; only the TTLs vs the 3 s poll are wrong.
- Webbridge LaunchAgent as on-demand start for browser signing. Do not pre-launch the JVM at login.

---

### What to measure first

Release build. Prefer `os_signpost` / `DetectionRunStats` / Instruments Time Profiler. For the scan smoke test: `caffeinate -dimsu swift test -c release -Xswiftc -enable-testing` with `AUTOGRAM_DIAG_PDF`.

| Probe | How | What "good" looks like |
|---|---|---|
| JVM spawn | Signpost around `CLIProcessRunner.start` / `MachineSessionProcess.startIfNeeded` | First start 1.5-4 s; later v1 calls should disappear if migrated |
| `DRIVERS` while idle on Podpisovanie | Count process launches of `AutogramCLI-arm64` over 30 s | Should be 0 after first probe |
| Batch preflight | Signpost `inspect` vs `validate`; log engine `validation.completed` count | One v2 request, N file events, no new process |
| `PDFAnalysisEngine.analyze` | Signpost; compare 1 vs 2 gray rasters | About half after merging ink passes |
| Detection: render+OCR vs classify vs FM | `foundationModelCalls`, `foundationModelSeconds`, `filteredCandidates` | Empty bank: FM seconds >> OCR; trained bank: FM calls << candidates |
| Real scan | `AUTOGRAM_DIAG_PDF` + `RealScanSmokeTests` | Baseline before/after FM serialization |
| ZaKo authorize | Signpost convert, embed, `normalizeWithEngine`, `PDFAValidator`, sign | Main-thread hitch should drop to ~0 if detached |
| Canvas | SwiftUI Instrument; count `PDFPage.thumbnail` | Once per page per document, not per progress tick |
| Raster PDF/A | Peak dirty memory on a 20-page scan at 200 dpi | Should not hold all page CGImages if you stream JPEG pages |
| Bank | `entries().count` and kNN time per crop | Linear scan fine until a few thousand vectors |

Do not optimize contour/saliency or AVM 1 s polling until the JVM spawn and FM budget are measured. Those two dominate interactive latency.

---

## Suggested order of work

Security first (legal/signing integrity, then local confused deputy, then transport):

1. Rewrite `isMandateCertificate`; add the I.CA personal-QES negative test.
2. Authenticate XPC; show origin + preview/hash; sanitize archive filenames; cap raw payload size.
3. Fail closed when the Java helper is missing; never badge Keychain output as KEP.
4. Turn off `NSAllowsArbitraryLoads`; lock AVM/LLM URLs; validate AVM results with DSS.
5. Pin Quick Action to the signed bundle; stop `mdfind`.
6. Strip or never start `AutogramServer` in this product.

Then speed (these do not fight the security work):

1. Persistent v2 helper for drivers / certificates / inspect / sign; kill the 3 s identity poll.
2. Call `engine.validate` for batch preflight.
3. Detach PDF/A from the main actor; one normalize on ZaKo.
4. Serialize / budget Foundation Model until the bank is trained; merge duplicate PDF rasters.

---

## File index (primary)

| Area | Paths |
|---|---|
| Web bridge / XPC | `Autogram/Sources/autogram-webbridge-agent/main.swift`, `Autogram/Sources/AutogramApp/WebBridgeListener.swift`, `Autogram/Sources/AutogramWebBridge/WebSigningBridge.swift`, `Autogram/Sources/AutogramApp/WebSigningCoordinator.swift`, `Autogram/WebExtension/dist/` |
| Mandate / KEP heuristics | `Autogram/Sources/AutogramKit/Signing/JavaEngine/EngineBridgeSigningProvider.swift`, `Autogram/Sources/AutogramApp/ZakoSessionStore.swift`, `Autogram/Sources/AutogramKit/Signing/SigningProvider.swift` |
| AVM | `Autogram/Sources/AutogramKit/Signing/AVM/`, `Autogram/Sources/AutogramKit/Support/AppSettings.swift` |
| ATS / build | `Autogram/build_app.sh`, `engine/src/main/scripts/resources/Autogram.entitlements` |
| Engine process | `Autogram/Sources/AutogramKit/EngineBridge/CLI/CLIProcessRunner.swift`, `MachineSessionProcess.swift`, `AutogramCLIEngine.swift`, `ProcessConfiguration.swift` |
| Java HTTP API | `engine/src/main/java/digital/slovensko/autogram/server/`, `UserSettings.java`, `LaunchParameters.java` |
| Quick Action | `Autogram/Assets/Autogram Finder Quick Action.workflow/` |
| Vision / PDF | `Autogram/Sources/AutogramKit/VisionAI/`, `Autogram/Sources/AutogramKit/Analysis/PDFAnalysisEngine.swift`, `Autogram/Sources/AutogramKit/PDFA/` |
| Batch validation design | `Autogram/docs/superpowers/specs/2026-08-31-batch-signature-validation-optimization-design.md` |
