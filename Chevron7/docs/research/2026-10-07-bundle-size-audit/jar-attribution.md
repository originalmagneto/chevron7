# Chevron7 engine: why each of the 96 dependency jars is there

Scope: `Chevron7/.build/engine/Contents/app/dependency-jars` (96 jars, 83.5 MiB), `autogram.jar`, jlink runtime `Contents/runtime` (170 MB). Read-only analysis; the repo was not modified (`git status` identical before/after: only the 3 pre-existing untracked `.impeccable/zako/*` files). All scratch material is in this directory.

Evidence levels used below:
- **static**: `jdeps` (JDK 25.0.4.1 Zulu FX) class-level graph, `-recursive`, plus a BFS over that graph from `digital.slovensko.autogram.Main` (with every edge into `ui.gui.*` cut) and from `PdfaNormalize`. Scripts: `reach.py`, `bfs.py`, `refs.py`, graph in `graph.json`.
- **runtime-trace**: real runs of the built engine with `-Xlog:class+load` (under `sandbox-exec ... (deny network*)`, throw-away PKCS12 keystore, files only in `run/`): machine v1 `CAPABILITIES`, `INSPECT` (signed PDF, CAdES ASiC-E, plain PDF), human CLI sign of PDF (PAdES-B), plain XML (XAdES), text file (ASiC-E XAdES), human CLI `--pdfa`, `PdfaNormalize`. Logs `run/load-*.log`, summary `loaded.json`.
- **trial**: the same flows re-run against a scratch copy of the engine with jars deleted (`trial.sh`, copies in `trial-*`), plus re-inspection of the signed outputs (valid/integrity true).

## 1. Short answer

| bucket | jars | MB | evidence |
|---|---:|---:|---|
| REMOVABLE-A: dead on every Chevron7 path | 16 (12 javafx-23.0.1, httpclient 4.5.14, httpcore 4.4.16, commons-codec 1.11, jul-to-slf4j) | 42.1 | static + runtime-trace + trial |
| REMOVABLE-B: only human CLI `--pdfa` (veraPDF stack) | 10 (dss-pdfa, validation-model, parser, pdf-model, core, feature-reporting, metadata-fixer, xmp-core, rhino, stax-utils) | 5.3 | static + trial (all flows pass except `--pdfa`, which then dies with NoClassDefFoundError) |
| UNCERTAIN | xmlresolver-5.3.3-data | 1.0 | trial passes, but purpose is offline DTD/entity catalogs |
| KEEP | 69 | 35.0 | reached or service-loaded |

How to remove (actionable): do it in `Chevron7/scripts/build-engine.sh`, next to the existing `find "${dependency_dir}" -maxdepth 1 -iname '*test*.jar' -delete`, not in `engine/pom.xml`. The javafx deps are still compile-time needed by `ui/gui`, `Logging`, `AppStarter`, `LaunchParameters`, and dropping httpclient 4 from the pom would change Maven mediation (commons-logging 1.2 -> 1.4.0, commons-codec 1.11 -> 1.18.0). For bucket B the clean cut is trial `tier2` (veraPDF jars, rhino, stax-utils AND dss-pdfa together): `dss-pdfa` registers `DocumentValidatorFactory`/`DocumentAnalyzerFactory` via ServiceLoader, and although `tier2b` (dss-pdfa kept) also passed, a factory whose implementation jars are gone is a latent NoClassDefFoundError for any code path that enumerates factories differently.

Evidence level for bucket A javafx jars is stronger than static: zero classes loaded from any of them in all 7 runtime traces, the trial and `java -jar` pass without them.

Bucket B confirmation (the PDF/A check is unreachable from Chevron7): `grep -rIni pdfa engine/protocol` is empty (machine protocol v1/v2 carry no PDF/A flag); every machine-mode `SigningParameters` factory call in `MachineSigningService` (lines 861-915: `buildParameters`, `buildForASiCWithXAdES`, `buildForPDF`) passes `checkPDFACompliance=false`; `Autogram.checkPDFACompliance` is called only from `ui/cli/CliApp.java:51` (human `--pdfa`) and `ui/gui/SigningDialogController.java:137`; nothing under `ui/machine/**` references it. Swift side: the PDF/A option goes through `PDFAConverter`/`PDFAValidator` and `PdfaNormalize` (PDFBox only), no `--pdfa` argument in `Chevron7/Sources` or the Quick Action scripts.

Bigger prize outside the jars: the jlink runtime still ships `javafx.controls/fxml/web/media`. `libjfxwebkit.dylib` alone is 105 MB. A scratch `jlink` image with only `java.base,java.compiler,java.desktop,java.logging,java.naming,java.net.http,java.sql,java.xml,jdk.crypto.cryptoki,jdk.httpserver,jdk.net,jdk.unsupported,javafx.base,javafx.graphics` is 58 MB (runtime 170 MB -> 58 MB) and passed every flow above (`runtime-min`, trial `rtmin-base`, `rtmin-t1`).

## 2. The javafx-*-23.0.1 jars: dead weight, not what is used

- Pulled by the pom's three direct `org.openjfx` deps (controls, fxml, web), each with a plain empty "pom jar" (66 bytes, 6 files) and a `mac-aarch64` classifier jar; javafx-media comes via javafx-web, graphics/base via controls. Total 40.75 MB, of which javafx-web 31.15 MB (it embeds an 86 MB `libjfxwebkit.dylib`).
- The only non-GUI references to JavaFX are `AppStarter -> javafx.application.Application` (only in the non-`--cli` branch `Application.launch(GUIApp...)`) and `Logging.log -> javafx.application.Platform.isFxApplicationThread()` (CLI path: `Main <- AppStarter <- CliApp <- Autogram <- Logging`, executed on every log call because the argument is evaluated eagerly). `LaunchParameters` (used only by `GUIApp`) refs `Application` too.
- Which JavaFX actually serves them: the **runtime's** JavaFX 25 modules. In the `-Xlog:class+load` of a PAdES sign the `javafx.base` and `javafx.graphics` classes come from `jrt:/` and **no class is ever loaded from any javafx-23.0.1 jar** (0 in all 7 traces). Reason: `javafx.*` modules in the image are default root modules for a classpath launch, and named-module packages shadow same-named classpath packages. `AutogramCLI-arm64` also passes `--enable-native-access=ALL-UNNAMED,javafx.graphics`, i.e. the module.
- jdeps itself resolves `javafx.base/controls/fxml/graphics/web` as system modules ("split package" warnings for every javafx package confirm the classpath copies are shadowed).
- Trial `tier1` (all 12 javafx jars deleted) passes all flows; `java -jar autogram.jar` (how `JavaEngineLocator` launches, manifest `Class-Path` tolerates missing jars) also passes.
- Constraint: the runtime must keep `javafx.base` + `javafx.graphics` (or `Logging` must stop calling `Platform`). The pom needs the javafx deps for compiling `ui/gui`, `Logging`, `AppStarter`, `LaunchParameters`, so removal belongs in `build-engine.sh` (like the existing `find ... -iname '*test*.jar' -delete`), not in the pom.

## 3. Flagged jars: who references them, needed on CLI / PdfaNormalize?

"reach" = classes of that jar reachable from `Main` (GUI edges cut) / from `PdfaNormalize` in the static graph; "traced" = classes actually loaded in my runtime traces.

| jar(s) | MB | referenced by (class evidence) | CLI/machine path | PdfaNormalize | verdict |
|---|---:|---|---|---|---|
| javafx-{base,controls,fxml,graphics,media,web}-23.0.1 (+6 empty pom jars) | 40.75 | pom direct deps; only non-GUI refs are `Logging -> Platform`, `AppStarter/LaunchParameters -> Application` | runtime's javafx 25 `base`+`graphics` serve them; jar classes never loaded | no | dead weight, remove (A) |
| rhino-1.7.13 | 1.25 | only `core-jakarta` (veraPDF `BaseValidator -> NativeJavaObject`, 8 refs), all reachable only via `Autogram.checkPDFACompliance` | static reach 328 classes (via PDF/A check); traced 286 only in `--pdfa` runs; 0 otherwise | no | (B) |
| guava-33.5.0-jre | 2.88 | `TargetPath -> com.google.common.io.Files` (1 ref); DSS `IUtils` implementation `dss-utils-google-guava` by ServiceLoader (0 static refs) | needed; 52-62 classes traced in sign/inspect | no | KEEP |
| jna-5.16.0 | 1.91 | `ui.machine.MacNativeFileSystem` (14 refs; `Native.load(Platform.C_LIBRARY_NAME, ...)` in `createForCurrentPlatform()`, called from the `MachineSigningService` constructor, i.e. machine `SIGN`), `util.macos.MacOSNotification` (GUI only) | 11/14 refs reachable from Main; not traced because machine SIGN needs a card (untested) | no | KEEP (machine sign) |
| httpclient-4.5.14, httpcore-4.4.16 | 0.75 + 0.31 | single main-code user: `core.LaunchParameters` (`URIBuilder`, `NameValuePair`), used only by `ui.gui.GUIApp`; `SignHttpSmokeTest`/server tests (test scope in practice) | 0 reachable from Main; 3+21 only with GUI edges | no | remove (A) |
| httpclient5-5.5.2 (+ httpcore5, httpcore5-h2) | 0.92 + 0.87 + 0.23 | `dss-service` (online OCSP/CRL/TSP/TL loaders), engine `MachineSigningService$MachineTimestampDataLoader -> HttpClientBuilder, BasicHeader` | needed (traced 13 + 19 classes even offline); h2 never traced, 4 reachable refs from httpclient5 | no | KEEP |
| Saxon-HE-12.10 | 5.52 | pom direct dep, **0 class references** anywhere; `META-INF/services/javax.xml.transform.TransformerFactory` makes it the default for `TransformerFactory.newInstance()` in `XMLUtils.getSecureTransformerFactory()` (callers `EFormUtils`, `XDCBuilder`, `SignatureValidator`) | traced: 338 Saxon classes loaded when signing plain XML; none on PDF sign/inspect | no | KEEP: removal silently swaps in JDK XSLTC (output/serialization differences in XDC/eForm transforms, which are signed content); only removable after XDC/Transformation tests are green on both |
| xmlresolver-5.3.3 | 0.16 | only Saxon-HE | 31 classes traced with Saxon | no | KEEP with Saxon |
| xmlresolver-5.3.3-data | 0.99 | only Saxon-HE (catalogs for W3C DTD/entity/MathML resolution); no repo reference | never loaded | no | UNCERTAIN (trial `xrdata` passes; matters only for inputs with DOCTYPE/XHTML entities) |
| veraPDF: validation-model-jakarta 0.42, parser 2.26, core-jakarta 0.87, pdf-model 0.16, feature-reporting-jakarta 0.07, metadata-fixer-jakarta 0.03, verapdf-xmp-core-jakarta 0.14 (+ dss-pdfa 0.01, stax-utils 0.12) | 4.08 + 0.13 | only `dss-pdfa` (`PDFAStructureValidator`) <- engine `Autogram.checkPDFACompliance` <- `CliApp` (human CLI `--pdfa`) and GUI. Not called from `ui/machine/**`; no `--pdfa` anywhere in `Chevron7/Sources`, Quick Action scripts or `AutogramCLI` callers | no machine-protocol path; traced only in `--pdfa` runs (parser 157, validation-model 112, core 96, pdf-model 101, rhino 286 classes) | no | (B) |
| woodstox-core-6.5.1 + stax2-api | 1.51 + 0.19 | runtime dep of `xmlsec`; **0 class references**; `META-INF/services/javax.xml.stream.*` make it the active StAX provider (JAXB/DSS report marshalling) | traced 59 + 36 classes in every sign run | no | KEEP: trial `wstx` passes (JDK SJSXP takes over) but TL/report parsing paths were not exercised (no network) |
| JAXB: jaxb-runtime 0.87, jaxb-core 0.13, txw2 0.07, istack-commons-runtime 0.03, jakarta.xml.bind-api 0.12, jakarta.activation 0.06 | 1.28 | every DSS facade (`DiagnosticDataFacade`, `SimpleReportFacade`, `DetailedReportFacade`, policy, `specs-*` TL/XAdES bindings) calls `JAXBContext.newInstance`; the implementation is found via `META-INF/services/jakarta.xml.bind.JAXBContext` (0 static refs to jaxb-runtime) | traced: jaxb-runtime 278 classes, api 67 per sign (post-sign validation report) | no | KEEP |
| gson-2.14.0 (+ error_prone_annotations) | 0.30 + 0.02 | 62 engine refs (`MachineProtocolCodec`, v2 codec, `Updater`, server DTOs); 57 reachable from Main | traced 162 classes on CAPABILITIES | no | KEEP |
| commons-codec-1.11 | 0.32 | only httpclient 4 (`BasicScheme`, NTLM, GGSS) and xmlsec's StAX API `org.apache.xml.security.stax.*` (230 classes; only 8 constant classes reachable from DSS) | 0 reachable; never loaded | no | remove (A) |
| commons-logging-1.2 | 0.06 | pdfbox (267 refs), fontbox (63), pdfbox-io (8): `org.apache.commons.logging.Log`; also httpclient 4 | traced 9-16 classes | **yes, 9 reachable, 16 traced** | KEEP (must stay if httpclient 4 goes: pdfbox needs it, Maven would fall back to 1.4.0) |
| bcprov 8.10 / bcpkix 1.11 / bcutil 0.67 | 9.88 | DSS everywhere (`dss-spi` 167+84+39 refs, cades, pades, cms, xades, service) and PDFBox encryption (`PublicKeySecurityHandler`) | traced 819 bcprov classes per PDF sign | PDFBox statically only; none traced | KEEP |
| jul-to-slf4j-2.0.18 | 0.01 | pom direct dep; nothing installs `SLF4JBridgeHandler` (repo grep: only the pom mentions it) | never loaded | no | remove (A, trivial) |

Pull graph facts worth knowing (from `tree-verbose.txt`): httpclient 4 wins Maven mediation for `commons-logging` (1.2 over pdfbox's 1.4.0) and `commons-codec` (1.11 over xmlsec's 1.18.0), so jar versions would change if httpclient 4 were dropped in the pom instead of in the build script. `jspecify` and `error_prone_annotations` come from guava/gson (annotations only, never loaded). `jakarta.xml.bind-api` shows up in the tree under test-scoped xmlunit but is a compile dep of jaxb/DSS.

## 4. jdeps module analysis vs `runtime_modules`

`runtime_modules` in `Chevron7/scripts/build-engine.sh`: `java.compiler,java.base,java.xml,java.desktop,java.naming,java.datatransfer,java.net.http,jdk.net,java.logging,java.sql,java.scripting,javafx.base,javafx.controls,javafx.fxml,javafx.graphics,javafx.web,jdk.unsupported,jdk.httpserver,jdk.crypto.cryptoki`; the resulting image also contains `javafx.media` and `jdk.jsobject` (javafx.web dependencies), `java.prefs`, `java.security.sasl`, `java.transaction.xa`, `jdk.xml.dom` (transitive).

`jdeps --print-module-deps --ignore-missing-deps --multi-release 25` results (note: print-module-deps lists a transitively reduced set, so `java.xml/java.logging/java.datatransfer` are implied by `java.desktop`/`java.sql`):

| input | result |
|---|---|
| autogram.jar (with ui.gui), class path = all jars | java.base, java.desktop, java.management, java.naming, java.net.http, java.prefs, java.security.jgss, java.sql, java.xml.crypto, javafx.fxml, javafx.web, jdk.httpserver, jdk.net, jdk.unsupported |
| autogram.jar with `ui/gui/**` deleted (`autogram-nogui.jar`), same class path | java.base, java.desktop, java.management, java.naming, java.net.http, java.prefs, java.security.jgss, java.sql, java.xml.crypto, **javafx.graphics**, jdk.httpserver, jdk.net, jdk.unsupported |
| nogui jar + all non-JavaFX jars as roots | same plus java.compiler |

Reading it:
- `javafx.controls`, `javafx.fxml`, `javafx.web` (and so `javafx.media`, `jdk.jsobject`) are required only by `ui.gui`. Non-GUI code needs only `javafx.graphics` (-> `javafx.base`), solely via `Logging`/`AppStarter`. `java.scripting` is not required by non-GUI code (it is in the list because of javafx.web). Scratch jlink with the minimal list above: 58 MB vs 170 MB.
- `jdk.httpserver` is referenced only from the engine's `server` package, but `Autogram -> server.CertificatesResponder -> ErrorResponseBuilder` keeps 15 `server.*` classes (and `com.sun.net.httpserver.Headers/HttpExchange`) statically reachable from Main, so the module is cheap insurance (tiny).
- The shipped runtime does NOT contain `java.management`, `java.security.jgss`, `java.xml.crypto` although jdeps lists them. Inspected: no reachable class references `java.lang.management`/`javax.management`/`org.ietf.jgss` (only httpclient 4 GGSS, unreachable); `javax.xml.crypto.dsig.CanonicalizationMethod` in `SigningParameters`/`ServerSigningParameters` is a leftover constant-pool Class entry of inlined String constants (no instruction uses it), `javax.xml.crypto.MarshalException` appears only in `xmlsec ECKeyValue` error branches, `XMLSignature` in `dss-xades CounterSignatureBuilder` (counter signatures). All sign/inspect flows ran fine without them; only an ECDSA KeyValue error path / counter-signing could hit NoClassDefFoundError (untested).

## 5. Repo-wide grep before calling anything removable

Searched `engine/src` (main, test, resources), `engine/pom.xml`, `engine/scripts`, `Chevron7/Sources`, `Chevron7/scripts`, `Chevron7/Assets`, `build_app.sh`, `Package.swift`, plus `META-INF/services` inside every jar (listing in section 6) and `Class.forName` / `ServiceLoader` / `getResourceAsStream` in the engine.

| package | hits | conclusion |
|---|---|---|
| `javafx.` | `ui/gui` (35 src, 25 resources, 4 tests), `core/AppStarter`, `core/LaunchParameters`, `util/Logging`, launcher flag `--enable-native-access=...,javafx.graphics`, `main/scripts/package.sh` | main-code users outside gui: Logging, AppStarter, LaunchParameters only |
| `org.apache.http.` | `core/LaunchParameters`, 2 tests | GUI-only in main code |
| `org.apache.commons.codec` | none | none |
| `org.verapdf` | only `simplelogger.properties` (a log level) | no code reference; reached through `dss-pdfa` |
| `org.mozilla.javascript` | none | |
| `net.sf.saxon`, `org.xmlresolver` | pom only | selected via ServiceLoader, not by name |
| `com.ctc.wstx`, `org.codehaus.stax2` | none | selected via ServiceLoader |
| `SLF4JBridgeHandler`, `org.slf4j.bridge` | none (only the pom dependency) | jul-to-slf4j unused |
| `com.sun.jna` | `ui/machine/MacNativeFileSystem`, `util/macos/MacOSNotification`, 1 test | keep |
| `com.google.common` | `core/TargetPath`, 1 test | keep |
| `Class.forName` in main | `com.apple.eawt.*` (GUI), `NativePkcs11SignatureToken` (sun.security.pkcs11 wrapper classes) | no dependency on any removable jar |
| `ServiceLoader` services present in jars | Saxon-HE (TransformerFactory), woodstox (XMLInputFactory/OutputFactory/EventFactory + stax2 validation), jaxb-runtime (JAXBContext), slf4j-simple, bcprov (Provider), dss-* (ASiC/CAdES/PAdES/XAdES/PDFA factories, IUtils, ICMSUtils, ICRLUtils, IPdfObjFactory, ValidationPolicyFactory, MimeTypeLoader) | these have 0 static refs, which is why jdeps never shows them; all KEEP. `dss-pdfa` registers `DocumentAnalyzerFactory`/`DocumentValidatorFactory`: with veraPDF removed but dss-pdfa kept, ServiceLoader enumeration still works (trial `tier2b` inspect/sign pass) |
| manifest `Class-Path` | `autogram.jar` lists every jar (maven-jar-plugin); `JavaEngineLocator` uses `java -jar`, the launcher and `PDFAConverter.normalizeWithEngine` use `-cp autogram.jar:dependency-jars/*` | missing manifest entries are ignored (verified with `-jar` on trial `tier1`), wildcard follows the directory |

## 6. Trial results (scratch copies, all offline, `trial.sh`)

Flows: machine v1 CAPABILITIES; machine v1 INSPECT of 3 files; human CLI sign PDF (PAdES-B), plain XML (XAdES), text file (ASiC-E/XAdES); `PdfaNormalize`; re-INSPECT of signed PDF and ASiC-E (valid=true, cryptographicIntegrity=true); human CLI `--pdfa` on a PdfaNormalize output.

| trial | removed | jars / size | result |
|---|---|---|---|
| baseline | nothing | 96 / 84 MB | all pass |
| tier1 | 12 javafx-23.0.1, httpclient 4, httpcore 4, commons-codec | 81 / 41 MB | all pass (also `java -jar` INSPECT) |
| tier2 | tier1 + veraPDF 7 jars + dss-pdfa + rhino + stax-utils | 71 / 36 MB | all pass except `--pdfa`: `NoClassDefFoundError: eu/europa/esig/dss/pdfa/PDFAStructureValidator` |
| tier2b | tier2 but dss-pdfa kept | 72 / 36 MB | all pass except `--pdfa`: `NoClassDefFoundError: org/verapdf/...` |
| saxon | tier1 + Saxon-HE + xmlresolver + data | 78 / 35 MB | passes (but see Saxon verdict: output equivalence not compared) |
| xrdata | tier1 + xmlresolver-data only | 80 / 41 MB | all pass |
| wstx | tier1 + woodstox + stax2 | 79 / 40 MB | all pass |
| rtmin-base | baseline jars on the minimal jlink runtime (58 MB) | 96 / 84 MB | all pass |
| rtmin-t1 | tier1 jars on the minimal runtime | 81 / 41 MB | all pass |

## 7. What this analysis could NOT cover

- Machine protocol SIGN (v1 and v2, the real Chevron7 path) needs a card driver; not run. JNA (`MacNativeFileSystem`), `httpclient5` TSA calls (`MachineTimestampDataLoader`), trusted-list/OCSP/CRL network loading (`dss-tsl-validation`, `specs-trusted-list*`, `specs-xades`, `specs-xmldsig`) were only established statically (those jars show "loaded: no" in the table because TL loading needs network, which my sandbox denied).
- eForm / XDC / UPVS-ORSR-FS resolver paths (Saxon-selected `TransformerFactory`, `XDCBuilder`) were not run end to end; a plain-XML XAdES sign exercised Saxon only lightly.
- jdeps and `ignore-missing-deps` cannot see reflection beyond the services files and `Class.forName` strings listed above; DSS also uses reflection-free `ServiceLoader` only.
- "loaded in my runs = no" is not proof of non-use; the verdict column uses static reachability and trials as well.

## 8. Per-jar table (96 jars)

Verdict codes: REMOVABLE-A = dead on all Chevron7 paths; REMOVABLE-B = needed only for human-CLI `--pdfa`; KEEP = referenced, service-loaded, or too risky/small; UNCERTAIN = see section 3. "pulled by" is the Maven parent(s) of the artifact (test-scope branches excluded; `direct pom dep` = declared in `engine/pom.xml`). "static reach" = reachable classes from Main (GUI cut) / from PdfaNormalize.

| jar | MB | pulled by (Maven) | used for | static reach CLI/Pdfa (classes) | loaded in my runs | verdict |
|---|---:|---|---|---|---|---|
| Saxon-HE-12.10.jar | 5.52 | direct pom dep | XSLT 3.0 processor; becomes default TransformerFactory via ServiceLoader (XDC, eForm transform, report HTML) | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| bcpkix-jdk18on-1.83.jar | 1.11 | via dss-spi | BouncyCastle PKIX: CMS, OCSP, TSP, cert path | 227 / 115 | yes | KEEP (needed) |
| bcprov-jdk18on-1.83.jar | 8.10 | via bcutil-jdk18on, dss-crl-parser | BouncyCastle provider and ASN.1 (everything signing) | 1419 / 1232 | yes | KEEP (needed) |
| bcutil-jdk18on-1.83.jar | 0.67 | via bcpkix-jdk18on | BouncyCastle ASN.1 utilities | 93 / 43 | yes | KEEP (needed) |
| commons-cli-1.11.0.jar | 0.11 | direct pom dep | CLI option parsing (AppStarter) | 46 / 0 | yes | KEEP (needed) |
| commons-codec-1.11.jar | 0.32 | via httpclient, xmlsec | Codec used by HttpClient 4 (BasicScheme) and xmlsec StAX classes (unused) | 0 / 0 | no | REMOVABLE-A |
| commons-logging-1.2.jar | 0.06 | via fontbox, httpclient, pdfbox, pdfbox-io | Logging facade for PDFBox/fontbox/pdfbox-io (and httpclient 4) | 9 / 9 | yes | KEEP (needed) |
| core-jakarta-1.28.2.jar | 0.87 | via feature-reporting-jakarta, metadata-fixer-jakarta, validation-model-jakarta | veraPDF core (profiles, rhino-based rule engine) | 230 / 0 | yes | REMOVABLE-B (loses human-CLI --pdfa) |
| dss-alert-6.4.jar | 0.01 | via dss-spi, dss-xml-common | DSS alert classes (LogOnStatusAlert used by SigningJob) | 18 / 0 | yes | KEEP (needed) |
| dss-asic-cades-6.4.jar | 0.09 | direct pom dep | ASiC-E/S with CAdES | 37 / 0 | yes | KEEP (needed) |
| dss-asic-common-6.4.jar | 0.10 | via dss-asic-cades, dss-asic-xades | ASiC container common code | 42 / 0 | yes | KEEP (needed) |
| dss-asic-xades-6.4.jar | 0.06 | direct pom dep | ASiC-E/S with XAdES | 25 / 0 | yes | KEEP (needed) |
| dss-cades-6.4.jar | 0.16 | via dss-asic-cades, dss-pades | CAdES signing/validation (also base of PAdES) | 48 / 0 | yes | KEEP (needed) |
| dss-cms-6.4.jar | 0.03 | via dss-cades, dss-cms-object | DSS CMS helpers on BouncyCastle | 17 / 0 | yes | KEEP (needed) |
| dss-cms-object-6.4.jar | 0.01 | direct pom dep | DSS CMS implementation (ICMSUtils/CMSGenerator, ServiceLoader) | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| dss-crl-parser-6.4.jar | 0.01 | via dss-crl-parser-stream, dss-spi | DSS CRL parsing (BouncyCastle based) | 4 / 0 | yes | KEEP (needed) |
| dss-crl-parser-stream-6.4.jar | 0.02 | direct pom dep | DSS streaming CRL parser; loaded by ServiceLoader (ICRLUtils) | 0 / 0 | no | KEEP (service-loaded / behavior) |
| dss-detailed-report-jaxb-6.4.jar | 0.09 | via dss-validation | DSS detailed report JAXB model | 58 / 0 | yes | KEEP (needed) |
| dss-diagnostic-jaxb-6.4.jar | 0.23 | via dss-validation | DSS diagnostic data JAXB model | 136 / 0 | yes | KEEP (needed) |
| dss-document-6.4.jar | 0.04 | via dss-asic-common, dss-cades, dss-xades | DSS document helpers (FileDocument, containers) | 17 / 0 | yes | KEEP (needed) |
| dss-enumerations-6.4.jar | 0.14 | via dss-model, dss-xml-common | DSS enums (SignatureLevel, DigestAlgorithm, MimeType ...) | 100 / 0 | yes | KEEP (needed) |
| dss-i18n-6.4.jar | 0.04 | via dss-validation | DSS validation messages | 2 / 0 | yes | KEEP (needed) |
| dss-jaxb-common-6.4.jar | 0.01 | via dss-jaxb-parsers, specs-xmldsig | DSS JAXB facade base (JAXBContext) | 2 / 0 | yes | KEEP (needed) |
| dss-jaxb-parsers-6.4.jar | 0.03 | via dss-detailed-report-jaxb, dss-diagnostic-jaxb, dss-policy-jaxb, dss-simple-certificate-report-jaxb, dss-simple-report-jaxb, specs-trusted-list, specs-trusted-list-v211, specs-validation-report, specs-xades | DSS JAXB adapters | 1 / 0 | yes | KEEP (needed) |
| dss-model-6.4.jar | 0.16 | via dss-crl-parser, dss-policy-jaxb, dss-spi, dss-token, dss-xml-utils | DSS model: DSSDocument, parameters, CertificateToken | 141 / 0 | yes | KEEP (needed) |
| dss-pades-6.4.jar | 0.35 | via dss-pades-pdfbox, dss-pdfa | PAdES signing/validation framework | 114 / 0 | yes | KEEP (needed) |
| dss-pades-pdfbox-6.4.jar | 0.07 | direct pom dep | PAdES PDFBox backend (IPdfObjFactory, ServiceLoader), visible signature | 6 / 0 | yes | KEEP (needed) |
| dss-pdfa-6.4.jar | 0.01 | direct pom dep | DSS PDFAStructureValidator (veraPDF wrapper) | 2 / 0 | yes | REMOVABLE-B (loses human-CLI --pdfa) |
| dss-policy-jaxb-6.4.jar | 0.08 | direct pom dep | DSS validation policy JAXB (ValidationPolicyFactory ServiceLoader) | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| dss-service-6.4.jar | 0.07 | direct pom dep | DSS online sources (OCSP, CRL, TSP data loaders); CommonsDataLoader on httpclient5 | 17 / 0 | yes | KEEP (needed) |
| dss-simple-certificate-report-jaxb-6.4.jar | 0.05 | via dss-validation | DSS simple certificate report JAXB model | 0 / 0 | no | KEEP (low-risk, see notes) |
| dss-simple-report-jaxb-6.4.jar | 0.05 | via dss-validation | DSS simple report JAXB model (SignatureValidator HTML report) | 24 / 0 | yes | KEEP (needed) |
| dss-spi-6.4.jar | 0.42 | via dss-cms, dss-document, dss-service, dss-validation | DSS core SPI: certificate/ASN.1 utilities, validation SPI, trusted-list-independent cert verifier | 185 / 0 | yes | KEEP (needed) |
| dss-token-6.4.jar | 0.03 | direct pom dep | DSS token API (Pkcs11/Pkcs12 signature tokens) | 15 / 0 | yes | KEEP (needed) |
| dss-tsl-validation-6.4.jar | 0.18 | direct pom dep | DSS trusted list (TSL/LOTL) loading and validation | 106 / 0 | yes | KEEP (needed) |
| dss-utils-6.4.jar | 0.01 | via dss-asic-common, dss-spi, dss-utils-google-guava, dss-xml-utils | DSS IUtils API | 2 / 0 | yes | KEEP (needed) |
| dss-utils-google-guava-6.4.jar | 0.01 | direct pom dep | DSS IUtils implementation on Guava (ServiceLoader eu.europa.esig.dss.utils.IUtils) | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| dss-validation-6.4.jar | 0.94 | direct pom dep | DSS validation engine (reports, SignedDocumentValidator) | 468 / 0 | yes | KEEP (needed) |
| dss-xades-6.4.jar | 0.34 | via dss-asic-xades, dss-tsl-validation | XAdES signing/validation (eForms, ASiC-E with XAdES) | 122 / 0 | yes | KEEP (needed) |
| dss-xml-common-6.4.jar | 0.03 | via dss-jaxb-common, dss-xml-utils | DSS XML common (DomUtils, XML transformers factories) | 21 / 0 | yes | KEEP (needed) |
| dss-xml-utils-6.4.jar | 0.02 | via dss-asic-common, dss-xades | DSS XML utilities, Santuario init (SantuarioInitializer) | 6 / 0 | yes | KEEP (needed) |
| error_prone_annotations-2.48.0.jar | 0.02 | via gson, guava | Guava/gson annotations | 4 / 0 | no | KEEP (low-risk, see notes) |
| failureaccess-1.0.3.jar | 0.01 | via guava | Guava companion | 0 / 0 | no | KEEP (low-risk, see notes) |
| feature-reporting-jakarta-1.28.2.jar | 0.07 | via validation-model-jakarta | veraPDF feature reporting | 31 / 0 | no | REMOVABLE-B (loses human-CLI --pdfa) |
| fontbox-3.0.8.jar | 1.57 | via pdfbox | PDFBox font library | 190 / 190 | no | KEEP (low-risk, see notes) |
| gson-2.14.0.jar | 0.30 | direct pom dep | JSON: machine protocol codec, Updater, server DTOs | 199 / 0 | yes | KEEP (needed) |
| guava-33.5.0-jre.jar | 2.88 | via dss-utils-google-guava | Guava: DSS IUtils impl and TargetPath (Files.getFileExtension) | 880 / 0 | yes | KEEP (needed) |
| httpclient-4.5.14.jar | 0.75 | direct pom dep | Apache HttpClient 4: only LaunchParameters.URIBuilder (GUI --url) and tests | 0 / 0 | no | REMOVABLE-A |
| httpclient5-5.5.2.jar | 0.92 | via dss-service | HTTP client behind DSS online sources and TSA requests (and engine MachineTimestampDataLoader) | 246 / 0 | yes | KEEP (needed) |
| httpcore-4.4.16.jar | 0.31 | via httpclient | HttpClient 4 core | 0 / 0 | no | REMOVABLE-A |
| httpcore5-5.3.6.jar | 0.87 | via httpclient5, httpcore5-h2 | httpclient5 core | 243 / 0 | yes | KEEP (needed) |
| httpcore5-h2-5.3.6.jar | 0.23 | via httpclient5 | httpclient5 HTTP/2 support (runtime peer of httpclient5) | 4 / 0 | no | KEEP (low-risk, see notes) |
| istack-commons-runtime-4.0.1.jar | 0.03 | via jaxb-core | JAXB runtime helper | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| j2objc-annotations-3.1.jar | 0.02 | via guava | Guava annotations | 0 / 0 | no | KEEP (low-risk, see notes) |
| jakarta.activation-2.0.1.jar | 0.06 | via jaxb-core, jaxb-runtime | Jakarta Activation (JAXB peer) | 31 / 0 | yes | KEEP (service-loaded / behavior) |
| jakarta.xml.bind-api-3.0.1.jar | 0.12 | via core-jakarta, dss-jaxb-common, dss-jaxb-parsers, feature-reporting-jakarta, jaxb-core, xmlsec | Jakarta XML Binding API | 73 / 0 | yes | KEEP (service-loaded / behavior) |
| javafx-base-23.0.1-mac-aarch64.jar | 0.72 | via javafx-base, javafx-graphics | JavaFX base (GUI) | 0 / 0 | no | REMOVABLE-A |
| javafx-base-23.0.1.jar | 0.00 | via javafx-base, javafx-graphics | JavaFX base (GUI) | 0 / 0 | no | REMOVABLE-A |
| javafx-controls-23.0.1-mac-aarch64.jar | 2.49 | direct pom dep; via javafx-controls, javafx-fxml, javafx-web | JavaFX controls (GUI) | 0 / 0 | no | REMOVABLE-A |
| javafx-controls-23.0.1.jar | 0.00 | direct pom dep; via javafx-controls, javafx-fxml, javafx-web | JavaFX controls (GUI) | 0 / 0 | no | REMOVABLE-A |
| javafx-fxml-23.0.1-mac-aarch64.jar | 0.12 | direct pom dep; via javafx-fxml | JavaFX FXML (GUI) | 0 / 0 | no | REMOVABLE-A |
| javafx-fxml-23.0.1.jar | 0.00 | direct pom dep; via javafx-fxml | JavaFX FXML (GUI) | 0 / 0 | no | REMOVABLE-A |
| javafx-graphics-23.0.1-mac-aarch64.jar | 4.71 | via javafx-controls, javafx-graphics, javafx-media | JavaFX graphics (GUI) | 0 / 0 | no | REMOVABLE-A |
| javafx-graphics-23.0.1.jar | 0.00 | via javafx-controls, javafx-graphics, javafx-media | JavaFX graphics (GUI) | 0 / 0 | no | REMOVABLE-A |
| javafx-media-23.0.1-mac-aarch64.jar | 1.56 | via javafx-media, javafx-web | JavaFX media (javafx-web dependency) | 0 / 0 | no | REMOVABLE-A |
| javafx-media-23.0.1.jar | 0.00 | via javafx-media, javafx-web | JavaFX media (javafx-web dependency) | 0 / 0 | no | REMOVABLE-A |
| javafx-web-23.0.1-mac-aarch64.jar | 31.15 | direct pom dep; via javafx-web | JavaFX WebView incl. 86 MB WebKit dylib (GUI) | 0 / 0 | no | REMOVABLE-A |
| javafx-web-23.0.1.jar | 0.00 | direct pom dep; via javafx-web | JavaFX WebView incl. 86 MB WebKit dylib (GUI) | 0 / 0 | no | REMOVABLE-A |
| jaxb-core-3.0.2.jar | 0.13 | via dss-pdfa, jaxb-runtime | JAXB runtime core (glassfish) | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| jaxb-runtime-3.0.2.jar | 0.87 | via core-jakarta, dss-jaxb-common, dss-jaxb-parsers, feature-reporting-jakarta | JAXB implementation (JAXBContext provider via ServiceLoader) | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| jna-5.16.0.jar | 1.91 | direct pom dep | JNA: MacNativeFileSystem (machine sign file handling), MacOSNotification (GUI only) | 102 / 0 | no | KEEP (machine sign) |
| jspecify-1.0.0.jar | 0.00 | via guava | Guava nullness annotations | 1 / 0 | no | KEEP (low-risk, see notes) |
| jul-to-slf4j-2.0.18.jar | 0.01 | direct pom dep | JUL to slf4j bridge (declared directly, no class references) | 0 / 0 | no | REMOVABLE-A |
| listenablefuture-9999.0-empty-to-avoid-conflict-with-guava.jar | 0.00 | via guava | Guava empty stub | 0 / 0 | no | KEEP (low-risk, see notes) |
| metadata-fixer-jakarta-1.28.2.jar | 0.03 | via validation-model-jakarta | veraPDF metadata fixer | 11 / 0 | no | REMOVABLE-B (loses human-CLI --pdfa) |
| parser-1.28.2.jar | 2.26 | via feature-reporting-jakarta, metadata-fixer-jakarta, validation-model-jakarta | veraPDF PDF parser | 284 / 0 | yes | REMOVABLE-B (loses human-CLI --pdfa) |
| pdf-model-1.28.2.jar | 0.16 | via core-jakarta, validation-model-jakarta | veraPDF PDF model | 304 / 0 | yes | REMOVABLE-B (loses human-CLI --pdfa) |
| pdfbox-3.0.8.jar | 1.97 | direct pom dep; via dss-pades-pdfbox | PDFBox: PdfaNormalize, PDFVisualization, PdfFormAppearances, DSS PAdES backend | 728 / 637 | yes | KEEP (needed) |
| pdfbox-io-3.0.8.jar | 0.05 | via fontbox, pdfbox | PDFBox I/O | 19 / 19 | yes | KEEP (needed) |
| rhino-1.7.13.jar | 1.25 | via core-jakarta | Mozilla Rhino JavaScript engine (veraPDF validation rules) | 328 / 0 | yes | REMOVABLE-B (loses human-CLI --pdfa) |
| slf4j-api-2.0.18.jar | 0.07 | direct pom dep; via dss-alert, dss-crl-parser, dss-enumerations, dss-i18n, dss-jaxb-common, dss-jaxb-parsers, dss-spi, dss-token, dss-validation, dss-xml-common, httpclient5, jul-to-slf4j, slf4j-simple, specs-validation-report, xmlsec | Logging API (DSS, engine) | 49 / 0 | yes | KEEP (needed) |
| slf4j-simple-2.0.18.jar | 0.01 | direct pom dep | slf4j binding (ServiceLoader) | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| specs-trusted-list-6.4.jar | 0.09 | via dss-tsl-validation, dss-xades | ETSI TS 119 612 trusted list JAXB bindings | 72 / 0 | no | KEEP (low-risk, see notes) |
| specs-trusted-list-v211-6.4.jar | 0.06 | via specs-validation-report | ETSI TL v2.1.1 bindings | 48 / 0 | no | KEEP (low-risk, see notes) |
| specs-validation-report-6.4.jar | 0.09 | via dss-validation | ETSI TS 119 102-2 validation report JAXB | 61 / 0 | yes | KEEP (needed) |
| specs-xades-6.4.jar | 0.17 | via specs-trusted-list, specs-trusted-list-v211, specs-validation-report | ETSI XAdES XSD JAXB bindings | 151 / 0 | no | KEEP (low-risk, see notes) |
| specs-xmldsig-6.4.jar | 0.03 | via specs-trusted-list, specs-trusted-list-v211, specs-validation-report, specs-xades | W3C XMLDSig JAXB bindings | 24 / 0 | no | KEEP (low-risk, see notes) |
| stax-utils-20070216.jar | 0.12 | via core-jakarta | StAX utilities for veraPDF | 0 / 0 | no | REMOVABLE-B (loses human-CLI --pdfa) |
| stax2-api-4.2.1.jar | 0.19 | via woodstox-core | woodstox API | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| txw2-3.0.2.jar | 0.07 | via jaxb-core | JAXB runtime XML writer | 0 / 0 | no | KEEP (service-loaded / behavior) |
| validation-model-jakarta-1.28.2.jar | 0.42 | via dss-pdfa | veraPDF validation model (PDF/A rules) | 313 / 0 | yes | REMOVABLE-B (loses human-CLI --pdfa) |
| verapdf-xmp-core-jakarta-1.28.2.jar | 0.14 | via core-jakarta, metadata-fixer-jakarta | veraPDF XMP model | 61 / 0 | yes | REMOVABLE-B (loses human-CLI --pdfa) |
| woodstox-core-6.5.1.jar | 1.51 | via xmlsec | StAX provider chosen by ServiceLoader (runtime dep of xmlsec); active for JAXB (59 classes loaded when signing) | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| xmlresolver-5.3.3-data.jar | 0.99 | via Saxon-HE | XML Resolver (Saxon dependency) | 0 / 0 | no | UNCERTAIN |
| xmlresolver-5.3.3.jar | 0.16 | via Saxon-HE | XML Resolver (Saxon dependency) | 0 / 0 | yes | KEEP (service-loaded / behavior) |
| xmlsec-3.0.6.jar | 1.14 | via dss-xml-utils | Apache Santuario XML signature/c14n used by DSS XAdES | 273 / 0 | yes | KEEP (needed) |
