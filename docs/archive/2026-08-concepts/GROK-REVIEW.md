# Review of Grok's fixes and performance suggestions

Date: 2026-09-15
Code reviewed: `cf78047e` and the current working tree.

## Verdict

Most security concerns identify real weaknesses. The document is useful for prioritization, but several fixes need redesign and several performance claims are incorrect or unmeasured. Do not implement the list verbatim.

The strongest immediate candidates are the mandate false positive, web-bridge authentication and filename handling, truthful signature qualification, prompt cancellation, and using trusted validation for signature checks. The simplest performance improvements are combining the duplicate ink render and removing unnecessary driver probes after measuring their frequency.

This is a technical code review, not a legal determination, live penetration test, certificate-policy audit, dependency advisory scan, or performance benchmark. No application code was changed. The original Grok document was preserved.

## Important corrections

1. **ZaKo already invokes the Java normalizer once.** `PDFAConverter.convertData` injects intermediate metadata; `normalizeForDelivery` invokes Java after XML attachment. Removing the initial conversion would change the raster/vector preparation and the bytes fingerprinted into the clause. The main-thread blocking concern remains valid.
2. **The Foundation Models judge is already an actor.** Actors can accept another call while an earlier call awaits inference. Limiting in-flight inference requires an explicit permit or queue. Neither adding an actor nor serializing inference guarantees a latency improvement. See [Apple's actor reentrancy explanation](https://developer.apple.com/videos/play/wwdc2021/10133/).
3. **There is no v2 `DRIVERS` operation.** Both Swift and Java enums omit it. The v2 certificate handler also requires a nonempty PIN, unlike Swift's existing optional-PIN discovery interface. This migration requires protocol work.
4. **AVM uses a real encryption key for server-side storage.** The client sends plaintext document content inside HTTPS and supplies the key to the server, so this is not end-to-end encryption. Calling the key merely an access token is inaccurate. The [upstream architecture](https://github.com/slovensko-digital/avm-server#architekt%C3%BAra-servera) describes encryption at rest and server-side document processing. Adding client-side AES-GCM would require changes to the phone and signing service, not just the Mac uploader.
5. **Do not stamp a returned signed PDF.** The appearance must be included in the content being signed. Use neutral wording before signing, validate the result, then show verified signer details in the UI or a separate report. A later PDF mutation can invalidate the signature or become an unsigned revision.
6. **Do not replace PDF parsing with a tail-only scan.** Metadata and output-intent objects need not be at the end and may be compressed. Removing a duplicate string conversion is reasonable; narrowing the scan would introduce false results.
7. **Empty pages already skip the layered detector's render and OCR.** `LayeredDetectionProvider` filters on `pageAnalyses.isEmpty` before preparing pages. Other detector paths would need separate measurement.

## High security findings

### H1. Unauthenticated XPC: confirmed; fix with role-specific peer trust

Both listeners accept every connection. The rendezvous exports registration and lookup to the same unauthenticated peer, and registration replaces the saved endpoint. The app's comment about extension entitlements is not an authentication check.

Evidence: [rendezvous](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/autogram-webbridge-agent/main.swift:16), [app listener](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/WebBridgeListener.swift:62).

Viable correction:

- Authenticate both client and server peers. Bind release requirements to the expected signing authority/team and bundle identifier; a bundle identifier alone is forgeable.
- Separate app registration from extension lookup/signing authorization, using connection-specific exported objects or distinct interfaces.
- The extension should authenticate the endpoint's peer as well as the rendezvous.
- Derive origin from browser-provided sender/frame information in the extension, not a page-supplied JSON field. Bind that origin and the displayed preview to the exact request bytes.
- Provide a development-only trust path for the probe and ad-hoc builds.

Apple exposes [NSXPCConnection.setCodeSigningRequirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement%28_%3A%29), which is worth preferring over custom low-level authentication where it meets the role requirements. Configure it before resuming the connection. A preview helps users assess the document; a hash alone is useful only when they have a trusted value to compare.

### H2. Personal qualified certificate classified as mandate: confirmed

For an ordinary display name, issuer `I.CA EU Qualified CA-SK`, and qualification `QESIG`, the final expression returns true. `mandateRequirementSatisfied` consumes this boolean together with qualification and private-key availability. The existing test covers an I.CA name containing `OPRÁVNENIE` and a personal eID issuer, but misses this negative case.

Evidence: [classification](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramKit/Signing/JavaEngine/EngineBridgeSigningProvider.swift:522), [gate](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/ZakoSessionStore.swift:829).

Remove the `QESIG && qualified` fallback and add that negative case. This is a small, viable fix. Longer term, use authenticated certificate attributes and an explicit policy mapping. Generic QC type OIDs, middleware identity, and issuer substrings alone do not establish a mandate. This review does not prescribe the legally sufficient certificate policy.

### H3. ATS and configurable endpoints: confirmed, with transport corrections

The app bundle enables arbitrary loads, and endpoint settings accept HTTP. Require HTTPS for remote AVM and cloud AI endpoints, restrict the release AVM endpoint, and explicitly handle loopback HTTP for local model servers. Validate redirects as well as initial URLs. Restrict local mode's destination; this client does not control the model server's listening interface.

Evidence: [ATS configuration](/Users/magneto/Projects/Autogram-macOS/Autogram/build_app.sh:187), [AVM client](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramKit/Signing/AVM/AVMClient.swift:38).

Two corrections: enabling ATS does not reject every user-installed trusted root, and app ATS policy does not secure the Java helper's HTTP stack. Apply endpoint rules to each transport. Pinning is a separate operational decision with certificate rotation implications. See [Apple's ATS scope and trust requirements](https://developer.apple.com/documentation/security/preventing-insecure-network-connections).

### H4. AVM result trust: confirmed; larger than an `engine.validate` call

`AVMResultMapper` derives qualification and mandate status from JSON signer labels. Nonempty signer arrays can be treated as qualified even without issuer data. The client accepts a free-form GUID and interpolates it into the QR URL. The Settings claim that only the Mac knows the key is incorrect.

Evidence: [mapper](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramKit/Signing/AVM/AVMResultMapper.swift:19), [GUID and QR handling](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramKit/Signing/AVM/AVMClient.swift:106), [Settings copy](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/Views/SettingsView.swift:1291).

Validate the signed result, its actual signer certificate, and its relationship to the submitted content. A whole-file hash comparison between input and signed PAdES necessarily differs. For PAdES, verify the signed revision and permitted signing changes; for ASiC, verify the expected payload entries and their signature coverage. Comparing hashes of extracted payloads can help for the latter.

The current Swift validation model does not expose everything needed for this certificate-policy and input-binding decision. Extend the result contract and keep missing or inconclusive validation distinct from success. GUID validation and structured URL construction are small independent fixes. Keep the QR secret, but retaining a transferable QR credential is intrinsic to the current workflow.

### H5. Keychain fallback presented as KEP: confirmed

The factory falls back to Keychain when the helper is unavailable; that provider sets `isLegallyBinding: true`, and the result UI translates the boolean into KEP. PKCS#11 qualification also has the reported issuer-exists shortcut.

Evidence: [factory](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramKit/Signing/SigningProvider.swift:433), [Keychain result](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramKit/Signing/KeychainXAdESSigningProvider.swift:70), [UI badge](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramApp/Views/SigningFlowViews.swift:905).

Use explicit states such as verified qualified, non-qualified, unverified, and demo. Block qualified workflows when required evidence is unavailable. Merely having the Java executable is insufficient proof of qualification, and `isLegallyBinding` is a poor name for a technical verification result. A blanket local-signing shutdown should also account for the separately configured mobile route and its validation requirements.

### H6. Helper overrides and environment: confirmed; release engineering work

Release currently retains helper/module environment overrides, the PKCS#11 child inherits the full environment, and the build script ad-hoc signs. Restrict overrides in release and allowlist the PKCS#11 helper environment. Verify any necessary middleware loader settings with each supported driver.

Evidence: [PKCS#11 environment](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramKit/Signing/PKCS11BridgeClient.swift:86), [module override](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramKit/Signing/PKCS11Module.swift:61), [build signing](/Users/magneto/Projects/Autogram-macOS/Autogram/build_app.sh:320).

Developer ID, hardened runtime, and notarization are viable distribution goals. They require signing credentials, nested-binary configuration, and testing of third-party PKCS#11/JVM loading. Removing library-validation exceptions without testing those native dependencies can break signing. Treat same-user malware scenarios as hardening boundaries, not proof of a remote exploit.

### H7. Java HTTP server: confirmed but dormant in the normal app path

The GUI can enable the server; wildcard CORS, unbounded body reads, and unused key/nonce getters are present. The Swift machine entrypoint does not start it. This is conditional attack surface, not a currently listening Swift signing API.

Evidence: [GUI startup](/Users/magneto/Projects/Autogram-macOS/engine/src/main/java/digital/slovensko/autogram/ui/gui/GUIApp.java:66), [CORS](/Users/magneto/Projects/Autogram-macOS/engine/src/main/java/digital/slovensko/autogram/server/filters/AutogramCorsFilter.java:34).

Disable the GUI/server entrypoint in this product's packaging first. Remove `jdk.httpserver` only after validating the resulting runtime and remaining entrypoints. A module deletion by itself is not an authentication fix. If the API is retained, enforce authorization tokens and bounded requests; CORS alone is not authorization.

### H8. Quick Action bundle discovery: confirmed with narrower conditions

The resolver tries `/Applications`, then the user's Applications directory, then Spotlight results. It does not blindly choose Spotlight ahead of an installed working app, but it also does not verify any candidate's signing identity.

Evidence: [resolver](/Users/magneto/Projects/Autogram-macOS/Autogram/Assets/Autogram%20Finder%20Quick%20Action.workflow/Contents/Resources/autogram-cli-sign.sh:8).

Verify the selected app and nested runner against the intended signing authority. Removing Spotlight is reasonable, but hard-coding `/Applications` unnecessarily excludes the currently supported user installation. This depends on establishing the release signing identity in H6.

## Medium and residual security proposals

| Grok item | Verdict and viable correction |
| --- | --- |
| Web archive filename | **Confirmed, high priority.** `WebSigningCoordinator.archive` appends an untrusted filename stem. Sanitize it to a basename, verify directory containment, and reserve an output without replacing an existing file. Relative path components can escape the intended directory. |
| Late payload cap | **Confirmed.** JSON and base64 decode occur before the 32 MB content check; ancillary eForm strings are outside it. Bound encoded messages before decode and count every field. Account for base64 expansion. XPC has already materialized its `Data` argument at that boundary, so earlier browser/extension caps also matter. |
| Red close button | **Confirmed.** `WebSigningPrompt` has a closable panel and no delegate handling user close. Cancel the pending continuation exactly once; avoid recursively cancelling during programmatic `hide()`. |
| Per-site disable | **Confirmed.** The content script sends `autogram-macos-set-enabled`, but neither injected script handles it. Define disable/reload semantics and test restoration of the portal's original signer. |
| Broad hosts / all frames | **Hardening with compatibility risk.** The manifest includes the test host and wildcard production hosts. Reduce release scope after inventorying real portal subdomains and signing frames. Removing `all_frames` blindly may break legitimate embedded forms. |
| Page-controlled eForm resolution | **Partly mitigated already.** The builder recognizes specific namespaces; FS uses a fixed S3 base and ORSR checks URL prefixes. Harden parsed hosts, paths, redirects, and response sizes. Simply disabling automatic resolution can break the portal support deliberately implemented here. |
| Output overwrite / symlink | **Overwrite confirmed; symlink behavior needs a dedicated test.** UI writes use `.atomic`, which is not exclusive creation. Reuse the Swift output-reservation abstraction where feasible. Atomic replacement does not by itself prove that a final symlink's target is overwritten. Parent-directory races need separate handling. |
| Retained PIN strings | **Confirmed.** Both stores retain `signingPIN` and a second certificate-load copy; some reset/card-change paths clear them, but success does not consistently do so. Clear at terminal workflow boundaries. Assigning an empty Swift String does not guarantee zeroization of earlier copies. |
| Mobile appearance says KEP | **Confirmed, proposed remedy unsafe.** Use neutral pre-sign content and post-validation UI status. Do not alter signed document content afterward. |
| RFC 3161 verification | **Confirmed.** The parser does not verify signature, imprint, nonce, or TSA trust. It is also called by native XAdES/PAdES paths, not only the Settings probe. Route real timestamped signing through a verifier that checks these properties. |
| Archive/PDF resource bombs | **Confirmed.** ASiC extraction allocates from declared uncompressed size; PDF ink analysis derives bitmap height from page aspect ratio. Add per-entry, aggregate, count, aspect-ratio, and pixel-area limits with checked arithmetic before allocation. |
| Plaintext evidence / VisionBank | **Confirmed at application-storage level.** Directory creation does not request private permissions. Set private directory/file modes. Backup exclusion is a retention choice, especially for a user-trained bank. This review did not inspect the user's disk encryption or actual file permissions. |
| LaunchAgent / SMAppService | **Optional packaging improvement.** Keep launch-on-demand. SMAppService does not replace XPC peer authentication. A non-launching status operation is reasonable if startup is reserved for signing. |
| EZZK OAuth | **Mixed.** No ephemeral browser preference is set; enabling it changes SSO behavior. `productionAuthorityGate = false` blocks production selection, so it is a safety gate rather than an authentication bypass. Fixed issuer/custom callback need protocol-specific checks. Legacy password values are still loaded and saved, so deletion requires a reference/migration check. |
| INSPECT follows symlinks | **Confirmed, lower severity than writes.** It reads through `FileDocument`; consider common bounded input validation for INSPECT, VALIDATE, and PREVIEW. Decide whether user-selected symlink inputs remain supported. |
| eForm XPath / generic loader | **XPath concatenation confirmed.** Bind XPath variables or validate identifiers. Normalize and constrain resource paths/redirects. Existing namespace and prefix checks mean arbitrary-host exploitation is not established merely by finding a generic loader. |
| Java updater | **Confirmed conditional surface.** It downloads and opens the DMG without an application-level signature/hash check. It is outside normal Swift execution. Disable it in the shipped product or adopt verified updates if retained. |
| Mandate override evidence | **Confirmed useful improvement.** Persist use of the override with the selected identity and result. Do not silently remove an existing user-visible workflow in a security cleanup. |

Other low findings:

- The PDF/A compatibility methods really return success without conversion/validation; treat this as an interoperability correctness issue and return an honest unsupported/failure result until implemented.
- `getSigningTime` uses the current clock; source it from the result where the protocol expects actual signing time.
- Shared AVM URLSession and persistent browser authentication are privacy/configuration choices. Ephemeral sessions are viable where cookies and caches are unnecessary, but do not provide signature verification.
- Keychain accessibility changes and Quick Action path cleanup are secondary hardening. Test app/background behavior when changing accessibility.
- Version and decoding details are low-value disclosures. Keep useful diagnostics out of release page responses where possible, without sacrificing local logs.
- Dependency freshness, absence of secrets, actual backup behavior, and universal claims about all XML parsers were not independently certified in this review. Grok's version list is not an advisory scan.

## Performance proposals

| Proposal | Verdict | Required changes / limits |
| --- | --- | --- |
| Persistent JVM for discovery/signing | **Viable, meaningful protocol work.** | The 3-second refresh and 2.5-second driver cache are present. Add v2 DRIVERS and preserve optional-PIN discovery semantics. `CardPresenceMonitor` has no callers, but confirm that every PKCS#11 middleware emits useful CryptoTokenKit events before deleting fallback refresh. Actual probe frequency includes operation duration and store guards. The 1.5-4 second startup estimate was not measured. |
| Use v2 VALIDATE for preflight | **Viable and valuable for correctness.** | The provider calls `engine.inspect`; the Java default inspection is structural. `validate` uses trusted validation. Preserve unavailable results and per-file failures. Trusted validation may initially be slower than structural inspection; the speed benefit is reuse across later validations, not a guaranteed faster first batch. |
| Detach PDF/A and normalize once | **Partly valid; duplicate-normalizer claim false.** | Move synchronous preparation and the single post-attachment normalizer off MainActor. Prefer an async process wrapper with cancellation and timeout. Use a worker-owned PDF document reconstructed from captured bytes. Preserve the intermediate fingerprint/XML sequence. Do not tail-scan metadata. |
| Serialize / reduce Foundation Models | **Experiment, not an established speed win.** | `SystemFoundationJudge` already is an actor. Add bounded in-flight inference if measurements show contention. Its current timeout cancels the task but deliberately does not await potentially non-cooperative inference. An unconditional wait would defeat that timeout. Gate actual inference lifetime and define fallback behavior. Lower budgets/high-confidence heuristic bypass can change both false positives and false negatives. |
| Reuse page rasters / thumbnails | **Duplicate ink render and thumbnail caching are viable.** | Return coverage and ink count from one render. Cache thumbnails by document identity, page, and rendering parameters. Keep fresh worker-owned PDF objects off the UI thread. A 760-pixel detector image is not automatically suitable for zoomed review or training data; benchmark memory and inspect quality. Empty pages already bypass layered OCR. |
| Prefetch batch PDF/A / all signing over v2 | **Viable after process lifecycle is hardened.** | A bounded preparation window can overlap CPU work with serial card use. Preserve cancellation, item ordering, progress, and memory limits. Combined ASiC changes output semantics and should remain a user choice. |

### Persistent-session prerequisites Grok omits

[MachineSessionProcess](/Users/magneto/Projects/Autogram-macOS/Autogram/Sources/AutogramKit/EngineBridge/CLI/MachineSessionProcess.swift:55) does not currently apply `ProcessConfiguration.timeout` or the configured stdout-line limit. Cancellation removes the pending request; a later event for that request is treated as malformed output and terminates the session. Token-permit waiters do not have the cancellation handling present in `CLIHelperOperationGate`.

Define timeouts, bounded output, late-event handling, and cancellation-safe queueing before making every signing operation depend on this persistent process. Maintain exclusivity across old and new paths during migration. Java v2 processes requests sequentially, so persistence alone does not provide concurrent preflight and signing.

### Smaller performance items

- A single PDF context for multi-page image input avoids the current per-page PDF creation and merge. Worth doing when multi-page images are common.
- Avoid full-PDF UTF-8 conversions in structural fallbacks, but keep the result explicitly structural and test compressed/incrementally updated documents. A streamed substring search is not a signature validator.
- The PKCS#11 helper polling sleeps exist. Consolidating onto the engine is more coherent than tuning two signing backends independently.
- ExampleBank eviction, evidence-storage redesign, and skipping contour/saliency are workload-dependent. Deleting learned examples or bypassing candidates changes behavior; measure before changing them.
- `foundationModelSeconds` aggregates call durations. With overlap, it is not the same as elapsed user-visible wall time. Record both when comparing concurrency policies.

## Recommended order

1. Correct mandate and qualification claims; add the missing negative cases and preserve an explicit unverified state.
2. Fix web filename confinement, prompt cancellation, message caps, and authenticated origin/peer handling. Establish release signing identity alongside XPC/Quick Action trust.
3. Correct AVM privacy wording and endpoint handling; design actual result validation and content binding.
4. Wire trusted batch validation and harden persistent-session cancellation/timeouts before broadening its use.
5. Combine duplicate ink renders, cache thumbnails, and move PDF/A work off the main actor.
6. Measure helper launches and model inference; then migrate discovery and tune detector concurrency/budgets.
7. Address dormant Java GUI/server/updater surface in packaging and test the resulting shipped runtime.

## Verification performed

Read the Swift call paths, Java v1/v2 implementations, Safari extension scripts, packaging scripts, and relevant existing tests. Checked Apple documentation for ATS and XPC peer requirements and upstream AVM architecture for encryption semantics.

Ran from the Autogram package directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'EngineBridgeTests|AVMResultMapperTests|AVMClientTests|WebSignRequestWireFormatTests|TwoStageClassifierTests|FoundationModelClassifierTests|PDFAnalysisEngineTests|PDFAConverterTests'
```

Result: **53 tests passed, 0 failures**. Test log: `/tmp/autogram-grok-review-tests.log`.

These existing tests validate current behavior; they do not prove the proposed fixes or demonstrate that the reported vulnerabilities are absent. No live card, phone, Safari portal, hostile XPC peer, decompression bomb, or release performance benchmark was exercised. AGENTS.md and CLAUDE.md were already identical and were left intact.
