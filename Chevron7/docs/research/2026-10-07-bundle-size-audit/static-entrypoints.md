# Static audit: what part of the bundled Java engine Chevron7 can reach

Scope: read-only. Nothing in the repo was edited. Evidence = file:line (paths relative to /Users/magneto/Projects/Chevron7).
Tools used besides grep/read: `jdeps`, `javap`, `jmod describe/extract` from the Zulu FX 25 JDK, run on the BUILT
`Chevron7/.build/engine/Contents/app/{autogram.jar,dependency-jars}`; raw output in this folder
(`jdeps-summary.txt`, `jdeps-verbose.txt`, `edges.txt`; `fxg/` holds the extracted javafx.graphics jmod used for javap).
Nothing was executed from the bundled runtime. Dynamic confirmation commands are at the end.

## A. Every place Chevron7 starts the engine or java

All Swift engine launches go through the C launcher `Contents/Helpers/AutogramCLI-arm64`, which `execv`s
`runtime/bin/java` (launcher: engine/scripts/native-macos/autogram-cli-launcher.c:13-17 refuses anything whose first arg is
not `--cli`, exit 64; :47-51 builds java path and classpath `app/autogram.jar:app/dependency-jars/*`; :60-75 java args
`--add-exports/--add-opens` for sun.security.pkcs11, `--enable-native-access=ALL-UNNAMED,javafx.graphics`,
`-Djava.awt.headless=true`, `-cp`, main class `digital.slovensko.autogram.Main`, then all caller args).

| # | Caller | Command line | Where |
|---|--------|--------------|-------|
| 1 | Main app, one-shot machine protocol v1 (DRIVERS, CERTIFICATES, INSPECT, SIGN) | `AutogramCLI-arm64 --cli --machine-readable --protocol-version 1 --operation <OP>`; JSON request on stdin | Chevron7/Sources/Chevron7Kit/EngineBridge/CLI/CLIProcessRunner.swift:93-100; ops in AutogramCLIEngine.swift:56 (.drivers), :86 (.certificates), :129 (.inspect), :251/:265 (.sign via runner) |
| 2 | Main app, long-lived machine protocol v2 session (SIGN, PREVIEW, VALIDATE, TIMESTAMP, CAPABILITIES) | `AutogramCLI-arm64 --cli --machine-readable --protocol-version 2` | Chevron7/Sources/Chevron7Kit/EngineBridge/CLI/MachineSessionProcess.swift:105-106; used at AutogramCLIEngine.swift:149 (.preview), :184 (.validate, separate `validationSession`), :375 (.sign v2), :487 (`machineSession.send`) |
| 3 | PDF/A normalisation of the ZaKo deliverable | `runtime/bin/java -cp app/autogram.jar:app/dependency-jars/* digital.slovensko.autogram.core.PdfaNormalize <in> <out> <sRGB.icc> <title>` (java directly, NOT the launcher: no headless flag, no --enable-native-access, no --cli gate) | Chevron7/Sources/Chevron7Kit/PDFA/PDFAConverter.swift:90-114; sole caller `normalizeForDelivery` ZakoSessionStore.swift:1422 |
| 4 | Finder Quick Action | Automator workflow -> `chevron7-quick-action.sh` -> `chevron7-cli-sign.sh` -> `AutogramQuickActionRunner-arm64 --operation CERTIFICATES|SIGN ...` -> runner spawns `AutogramCLI-arm64 --cli --machine-readable --protocol-version 1 --operation <OP>` | Chevron7/Assets/Chevron7 Finder Quick Action.workflow/Contents/document.wflow:39,67; .../Resources/chevron7-quick-action.sh; .../chevron7-cli-sign.sh:68-82; engine/scripts/native-macos/autogram-quick-action-runner.swift:317-324 (args), :411 (helper path) |
| 5 | Build smoke test | `AutogramCLI-arm64 --url http://localhost:37200` must exit 64; `... --cli --machine-readable --protocol-version 1 --operation CAPABILITIES` | Chevron7/scripts/build-engine.sh:105-117 |

Other facts for A:
- Quick Action dialogs are NOT Java and NOT AppKit: all of them (driver list, certificate list, PIN, alerts) are `/usr/bin/osascript`
  `choose from list` / `display dialog ... with hidden answer` / `display alert` in chevron7-quick-action.sh:11-69. The runner
  (autogram-quick-action-runner.swift) is a headless Swift CLI that reads the PIN from stdin and speaks machine protocol v1
  (`CERTIFICATES`, `SIGN` only; payload built at :390-411). It always passes `--cli --machine-readable --protocol-version 1`.
- The Safari web bridge never starts java. `Chevron7WebBridge`, `Chevron7WebExtensionHandler`, `chevron7-webbridge-agent`
  contain no java/jar/Process launch of the engine; web requests are served by the app (WebSigningCoordinator.swift), which uses
  `SigningProviderFactory.makeDefault()` -> `EngineBridgeSigningProvider` -> the same `AutogramCLIEngine` (entries 1 and 2).
  Other Swift `Process()` users are unrelated (pkcs11-helper, launchctl, lipo, xmllint, pbs, ditto).
- `JavaEngineInstallation.launchArguments` (`-jar autogram.jar --cli ...`, JavaEngineLocator.swift:23-25) has no caller anywhere
  in Sources or Tests (grep -rn launchArguments Chevron7/Tests returns nothing), so a `-jar` launch is dead code; only `javaExecutableURL`, `jarFileURL` (PdfaNormalize) and
  `helperURL` (availability check, SigningProvider.swift:583-585) are used.
- build_app.sh:79-118 is not a launch path but decides what ships: it copies Helpers, autogram.jar, dependency-jars and runtime from `.build/engine/Contents`, else from `CHEVRON7_LEGACY_APP_ROOT`, else from any installed `/Applications/*.app` or `~/Applications/*.app` that has them. A legacy bundle can carry a different runtime module list than build-engine.sh:73; the audit above is of `.build/engine`.
- Overrides: env `CHEVRON7_CLI_HELPER` (AutogramCLIEngine.swift:807), `CHEVRON7_JAVA_ENGINE_ROOT` (JavaEngineLocator.swift:29,
  :40). Child env is an allowlist (HOME, TMPDIR, USER, LOGNAME, LANG, LC_*), no JAVA_TOOL_OPTIONS (ProcessConfiguration.swift:37-56).
- The engine is never started in GUI mode: `AppStarter` GUI branch (`Application.launch(GUIApp.class,...)`, AppStarter.java:73) needs
  neither `--cli`, and the launcher refuses a first argument other than `--cli`. The human-readable `--cli` (CliApp) mode is
  also unused by Chevron7: every caller adds `--machine-readable` (the old shell `chevron7-cli-sign.sh` goes through the runner,
  not `--cli -s`).

## B. What code runs per entry point, and javafx references outside ui/gui

Flow: `Main.main` -> `AppStarter.start` (core/AppStarter.java:50). `--cli` + `--machine-readable` -> `machineCliStart`
(:90-98): protocol "2" -> `MachineV2CliApp.start`, else `MachineCliApp.start`; then `terminateCliProcess` SIGKILLs itself (:66-67, :104-113).
PdfaNormalize has its own `main` (core/PdfaNormalize.java:39) and never touches AppStarter.

### javafx references in engine/src/main/java
`grep -rl javafx` finds 38 files: 35 under ui/gui plus exactly three outside:

1. `core/AppStarter.java:7` `import javafx.application.Application;` and :73 `Application.launch(GUIApp.class, args)`; also `:5` imports GUIApp.
   Only the GUI branch executes it; on the CLI branch the javafx class is never loaded (ldc of a Class constant and an invokestatic
   resolve lazily; nothing in `start` needs the verifier to load them). Runs on: entry points 1, 2, 4 (class loads, javafx not touched).
2. `core/LaunchParameters.java:10` (`javafx.application.Application.Parameters` as a parameter type in `fromParameters`).
   Only caller is `ui/gui/GUIApp.java:50`. Not loaded on any CLI/machine path.
3. **`util/Logging.java:9,17` `javafx.application.Platform.isFxApplicationThread()` inside `Logging.log(String)`, evaluated eagerly as a
   log argument, so it always executes regardless of log level.** This one IS reachable from the machine path:
   - `core/SigningJob.java:57` `signWithKeyAndRespond` calls `Logging.log(...)` first thing;
   - `ui/machine/MachineSigningService.java:808` (`DefaultSigningSession.sign`) calls `job.signWithKeyAndRespond(key)`; this is the
     SIGN operation of both protocol v1 and v2 (v2 builds a `MachineSigningService`, ui/machine/v2/MachineV2CliApp.java:102).
   - (Human `--cli` SIGN also hits it via CliUI -> Autogram.sign -> SigningJob; also `core/Batch.java`, `BatchStartCallback`,
     `Autogram.java:179` batch paths, not used by Chevron7.)
   - Bytecode check (javap on the extracted javafx.graphics jmod): `Platform.isFxApplicationThread()` ->
     `PlatformImpl.isFxApplicationThread()` -> `Toolkit.getToolkit()` + `isFxUserThread()`. `Toolkit.getToolkit()` reads
     `javafx.toolkit`, resolves the default toolkit class, `Class.forName(...)`, `getDeclaredConstructor().newInstance()` and calls
     `init()` (com.sun.javafx.tk.Toolkit.getToolkit). `PlatformImpl`'s static initialiser also touches
     `javafx.beans.property.SimpleBooleanProperty` (javafx.base). So a signing run loads javafx.graphics + javafx.base,
     instantiates the Quantum toolkit object (it does not start the FX application thread or open a window), and may load
     glass/prism native libs. This is the likely reason the launcher passes `--enable-native-access=...,javafx.graphics`.
   - It does NOT happen for CAPABILITIES, DRIVERS, CERTIFICATES, INSPECT, PREVIEW, VALIDATE or PdfaNormalize (none reach
     `SigningJob`/`Logging`; grep: `Logging` is used only by core/{Autogram,Batch,BatchStartCallback,SigningJob}, ui/{BatchGuiFileResponder,SaveFileFromBatchResponder}, ui/gui/BatchDialogController).
     TIMESTAMP is rejected by the engine (`OPERATION_UNAVAILABLE`, ui/machine/v2/MachineV2CliApp.java:96), so it reaches nothing.

### Indirect (non-import) javafx links, i.e. classes outside ui/gui that depend on a ui/gui class that extends/uses javafx
- `core/UserSettings.java:4,27,142,197` uses `ui/gui/SignatureLevelStringConverter` (`extends javafx.util.StringConverter`, javafx.base).
  Line 27 `DEFAULT_SIGNATURE_LEVEL = SignatureLevelStringConverter.PADES` is a compile-time constant (inlined, no class load).
  Lines 142 (`save`) and 197 (`setSignatureType`, called only from `load()`/`reset()`) do `new SignatureLevelStringConverter()`.
  `UserSettings.load/save/reset` callers: ui/gui/GUIApp.java:35, GUIUtils.java:83, SigningDialogController.java:152,162,
  SettingsDialogController.java:423, SettingsResetDialogController.java:34 only. `MachineSettings` and `CliSettings` use the plain
  constructor and never call them. So javafx.base is NOT loaded through UserSettings on CLI/machine paths.
- `ui/machine/MachineSecretUI.java:13`, `ui/cli/CliUI.java:39`, `ui/UI.java:7`, `core/FailedVisualizationException.java:3` import
  `ui/gui/IgnorableException`, which has no javafx (only `AutogramException` + `SigningJob`). Harmless.
- `ui/BatchGuiFileResponder.java:68-84` does `instanceof ui.gui.GUI` (javafx-heavy class); only runs in GUI batch, not used by Chevron7.
- `ui/SupportedLanguage.java:56,60` and `server/AutogramServer.java:126` load the `ui/gui/language/l10n` ResourceBundle (properties only, no javafx).
- `core/Autogram.java:7,336,363` names `server.CertificatesResponder` (which has a `com.sun.net.httpserver.HttpExchange` field) only as method
  parameter types and lambda captures; nothing loads it unless `consentCertificateReadingAndThen/getCertificates` run (GUI HTTP API only).
- Static initialisers worth knowing: `core/Configuration.java` loads `configuration.properties` (no javafx); `Logging` has a static SLF4J
  logger only; no static initialiser outside ui/gui references javafx.

### Per entry point, what loads
- 1/2/4 CAPABILITIES, DRIVERS, CERTIFICATES, INSPECT, PREVIEW, VALIDATE: MachineCliApp/MachineV2CliApp, MachineDriverService,
  MachineInspectionService, MachineTrustService, DSS, PDFBox, PKCS#11 (cryptoki). No javafx.
- 1/2/4 SIGN: same + `SigningJob` -> `Logging.log` -> javafx.graphics/javafx.base (above). Nothing else javafx.
- 3 PdfaNormalize: PDFBox 3 only (`Loader`, `PDDocument`, `PDOutputIntent`, imports in core/PdfaNormalize.java:3-9); java.desktop via PDFBox (ICC profile
  handling). No javafx, no DSS, no AppStarter. Classpath is the full `dependency-jars/*` but only pdfbox*, fontbox, commons-logging, bc* are touched.

## C. Removal candidates, module by module

Method: (1) grep of engine sources, (2) `jdeps -s` / `-verbose:class` of autogram.jar + all 90 non-javafx jars
(`jdeps-summary.txt`, `jdeps-verbose.txt`), (3) `jmod describe` of the javafx jmods, (4) javap on the few classes that decide a
verdict. Runtime actually contains: java.base java.compiler java.datatransfer java.xml java.prefs java.desktop java.logging
java.security.sasl java.naming java.net.http java.scripting java.transaction.xa java.sql javafx.base jdk.unsupported javafx.graphics
javafx.controls javafx.fxml javafx.media jdk.jsobject jdk.xml.dom javafx.web jdk.crypto.cryptoki jdk.httpserver jdk.net
(runtime/release; the jlink list in build-engine.sh:73 plus its transitive closure). JavaFX in the runtime is 25.0.4
(runtime/lib/javafx.properties) while dependency-jars carries JavaFX 23.0.1 (see "classpath javafx jars" below).

| Module | Verdict for machine/CLI/PdfaNormalize | Evidence |
|---|---|---|
| javafx.graphics | NEEDED today, solely through `Logging.log` on SIGN. Removable only after patching Logging (engine/src/main/java/digital/slovensko/autogram/util/Logging.java:17: drop the `Platform.isFxApplicationThread()` call) | section B item 3. Also required by javafx.controls/fxml/web/media (all GUI). Its natives: libglass, libprism_*, libjavafx_font/iio, libdecora_sse (small) |
| javafx.base | Needed transitively by javafx.graphics (and `PlatformImpl` static init uses `SimpleBooleanProperty`). Needed only if javafx.graphics stays. Also requires java.desktop | jmod describe; javap PlatformImpl `<clinit>` |
| javafx.controls | NOT needed. Only ui/gui classes import it (jdeps: autogram.jar -> javafx.controls; grep shows all in ui/gui) | grep javafx outside ui/gui = 3 files, none uses controls |
| javafx.fxml | NOT needed (FXMLLoader only in ui/gui; 25 .fxml files). It is the ONLY module in the image that requires java.scripting | jmod describe javafx.fxml |
| javafx.web | NOT needed. WebView only in ui/gui (visualisation of eForms/HTML, about/update dialogs). Biggest item: `runtime/lib/libjfxwebkit.dylib` = 105 MB of the 170 MB runtime, javafx.web.jmod 38.9 MB. Pulls javafx.media, jdk.jsobject, jdk.xml.dom, java.net.http | jmod describe; `du` on runtime/lib |
| javafx.media (+ jdk.jsobject, jdk.xml.dom) | NOT needed; present only because javafx.web requires them (libjfxmedia, libgstreamer-lite, libglib-lite ~3 MB). They disappear from the image with javafx.web | runtime/release; jmod describe javafx.web |
| jdk.httpserver | NOT needed. `com.sun.net.httpserver` appears only in `server/` (12 files). `AutogramServer` is instantiated only at ui/gui/GUIApp.java:66; the other outside reference is the unloaded `CertificatesResponder` parameter type (Autogram.java:336,363). Also provides `runtime/bin/jwebserver`. 173 KB | grep; section D |
| java.net.http | NOT needed on these paths. Only `core/Updater.java:8-10,59` uses it; Updater's callers: ui/gui/UpdateController.java and a compile-time constant read in ui/cli/CliUI.java:217 (`LATEST_RELEASE_URL` is `public static final String`, inlined). The 3 jars that make HTTP calls (DSS CommonsDataLoader, TSA, TL download) use Apache httpclient5, not java.net.http. Required by javafx.web only otherwise | jdeps-verbose (only Updater); `grep HttpClient` |
| java.scripting | NOT needed by any code. No engine source, and no jar in jdeps (rhino-1.7.13 does not reference javax.script; jdeps lists only java.base/desktop/xml). Only javafx.fxml requires it. Safe to drop together with javafx.fxml, and even without that change nothing calls it | grep `javax.script|ScriptEngine|org.mozilla` in engine = 0; jdeps rhino row |
| java.sql | NOT needed in practice. Engine sources: 0 refs. Jars: dss-spi `JdbcCacheConnector`/`JdbcRevocationSource`, dss-service `JdbcCache{CRL,OCSP,AIA}Source` (only if a JDBC cache source is instantiated; the engine has no "Jdbc" reference), BouncyCastle `x509.util.LDAPStoreHelper` (LDAP cert store only), gson `internal.sql.*` (guarded: `SqlTypesSupport.<clinit>` does `Class.forName("java.sql.Date")` in try/catch, verified with javap). Risk low, but a missing java.sql in an unexpected DSS path would be a NoClassDefFoundError, not a graceful fallback. Tiny (82 KB). Recommend: "probably removable, confirm dynamically; negligible gain, so keep unless you want the last 82 KB" |
| java.compiler | UNCERTAIN, keep (141 KB). Only user: JAXB `org.glassfish.jaxb.core.api.impl.NameConverter$Standard.toPackageName` and `NameConverter$2.toConstantName` call `javax.lang.model.SourceVersion.isKeyword`; the runtime JAXB model classes (`TypeInfoImpl`, `AttributePropertyInfoImpl`, `JAXBRIContext`) reference `NameConverter`, and DSS builds its reports/diagnostics through JAXB, so a call from validation (INSPECT/VALIDATE) is plausible but not proven. Nothing in engine sources | jdeps-verbose; javap on NameConverter |
| java.naming | NEEDED. `javax.naming.ldap.LdapName/Rdn` in core/SigningKey.java:4-6,37 (every SIGN, certificate CN), util/DSSUtils.java:12-14, ui/machine/TimestampTrustAnchors.java:9-10,92; dss-service `CommonsDataLoader` (javax.naming.Context), bouncycastle | grep + jdeps |
| java.datatransfer | NEEDED as long as java.desktop is (java.desktop `requires transitive java.datatransfer`). Engine sources reference it only in ui/gui/GUIUtils.java (clipboard) | jmod rules; grep |
| jdk.unsupported | Not needed by Chevron7 code. `javafx.graphics` requires it (comment in engine/pom.xml:441-442). Guava lists `requires static jdk.unsupported` but touches `sun.misc.Unsafe` reflectively (jdeps finds no class edge), with fallbacks. jna 5.16 has no jdk.unsupported edge in jdeps. 29 KB. Drop only together with javafx.graphics; confirm Guava fallback dynamically if desired | jdeps-summary (module requires only); pom.xml:441 |
| jdk.net | NEEDED. httpclient5 `DefaultHttpClientConnectionOperator.<clinit>` calls `jdk.net.Sockets.supportedOptions(Socket.class)` and `ExtendedSocketOptions.TCP_KEEP*` unconditionally (javap), and dss-service uses httpclient5 for TSA, trusted lists, CRL/OCSP; `MachineSigningService.java:33,989` subclasses its builder. Removing it would break the first online request (timestamp) with NoClassDefFoundError | javap DefaultHttpClientConnectionOperator; jdeps |
| java.desktop (out of scope, confirmed) | NEEDED: autogram.jar (PDFVisualization ImageIO), dss-pades, dss-pades-pdfbox, pdfbox, fontbox, jna, jaxb-runtime, verapdf parser, rhino | jdeps-summary |
| jdk.crypto.cryptoki (out of scope, confirmed) | NEEDED: NativePkcs11SignatureToken.java:28-30 (`sun.security.pkcs11.wrapper.*`), launcher `--add-exports/--add-opens` (autogram-cli-launcher.c:62-65) | grep |

Modules the jars need that the runtime does NOT have (pre-existing, informational; note: no change needed unless a path hits them):
- `java.xml.crypto`: referenced by autogram.jar (core/SigningParameters.java:3 and server/dto/ServerSigningParameters.java:21 import
  `javax.xml.crypto.dsig.CanonicalizationMethod`; javap -v on SigningParameters shows a Class constant-pool entry but no Fieldref/getstatic to it),
  dss-xades, dss-xml-utils, xmlsec. No jar provides `javax/xml/crypto/` (unzip scan) and the image lacks the module, yet the shipped build signs
  XAdES/ASiC-E, so these references are not executed on the paths Chevron7 uses. Takeaway: a jdeps edge is not proof of runtime need (same logic as java.sql/java.compiler below).
- `java.management`: veraPDF `core-jakarta` `LogsFileHandler`/`LogsFormatter` (RuntimeMXBean). `java.security.jgss`: httpclient 4.5 / httpclient5 Kerberos schemes.

### Jar groups (96 dependency jars, 84 MB)
- JavaFX group, 12 jars: javafx-{web 32.7 MB, graphics 4.9, controls 2.6, media 1.6, base 0.76, fxml 0.13}-23.0.1-mac-aarch64.jar
  (about 42.7 MB) + six 300-byte `javafx-*-23.0.1.jar` stubs. They come from `org.openjfx` Maven deps (engine/pom.xml:196-211, "keeps the
  fork buildable with a normal JDK"). While the runtime has javafx.* modules, packages in those named boot-layer modules win over the
  classpath copies, so these jars are shadowed (runtime is 25.0.4, jars are 23.0.1, so two versions ship). If javafx.* is dropped from
  the runtime but these jars stay on `-cp`, `Logging.log` would silently start working from the jar (classes from the unnamed module, natives
  extracted by `NativeLibLoader` to `~/.openjfx/cache/23.0.1/...`). So remove the runtime modules AND the jars (or patch Logging) together; do not
  do one half. The release script signs native libraries inside every jar (scripts/sign-release.sh:50-60), so these jars also add
  notarisation work. NOT needed once Logging is patched. UNCERTAIN until then.
- `httpclient-4.5.14`, `httpcore-4.4.16`: used by engine only in core/LaunchParameters.java:7-8 (`URIBuilder`, GUI launch). jar reverse deps (edges.txt): httpclient-4.5.14 is
  required by autogram.jar only; httpcore-4.4.16 by autogram.jar and httpclient-4.5.14. NOT needed on CLI/machine paths. `commons-codec-1.11` is also used by
  xmlsec-3.0.6 (keep). `commons-logging-1.2` is used by pdfbox, pdfbox-io, fontbox (keep).
- `httpclient5-5.5.2`, `httpcore5`, `httpcore5-h2`: NEEDED (DSS dss-service data loader, MachineSigningService.java:33-34).
- `Saxon-HE-12.10` + `xmlresolver-5.3.3` (+ `-data`): no class references Saxon, but Saxon registers `META-INF/services/javax.xml.transform.TransformerFactory` (unzip) and the engine creates transformers through `XMLUtils.getSecureTransformerFactory()` (core/SignatureValidator.java:169, core/eforms/EFormUtils.java:159,313, core/eforms/xdc/XDCBuilder.java:88). So it is very likely the active XSLT engine for INSPECT/XDC/eForm paths: keep (confirm via class-load log).
- `rhino-1.7.13` (+ `stax-utils`): only referenced by veraPDF `core-jakarta` (jdeps), whose validation rules are JavaScript expressions; it runs when PDF/A compliance is checked (dss-pdfa, `Autogram.checkPDFACompliance`), so keep. It has no META-INF/services and no javax.script edge, which confirms java.scripting is unused.
- `woodstox-core`, `stax2-api`, `jul-to-slf4j`, `slf4j-simple`, `jna-5.16.0` (used by autogram.jar, ui/machine/MacNativeFileSystem.java:6, :54): no static edges for woodstox, stax2, jul-to-slf4j,
  slf4j-simple (all are provider/service-loader style); do not remove on static evidence. `slf4j-simple` is the logger binding (simplelogger.properties).
- pdfbox/fontbox/pdfbox-io, DSS 6.4 family, bcprov/bcpkix/bcutil, xmlsec, guava, gson, commons-cli, jaxb-*: needed (jdeps edges from autogram.jar and DSS).

## D. Is the HTTP server (jdk.httpserver) reachable from `--cli`?

No, by three independent gates:
1. `AutogramServer` is created in exactly one place, `ui/gui/GUIApp.java:66`, run from `GUIApp` only (JavaFX `Application` subclass).
   grep: no other `new AutogramServer`; the rest of `server/` is called only by it (the one outside reference, `core/Autogram.java:7`, is `CertificatesResponder`, used by `server/CertificatesEndpoint`).
2. `AppStarter.start` takes the CLI branch whenever `--cli` is present (:62-71) and reaches `Application.launch(GUIApp.class, ...)` only in the final `else` (:72-74).
   `--url` and `--cli` are one mutually exclusive `OptionGroup` (:16-19), so `--cli --url ...` fails to parse (ParseException printed, no server).
3. The launcher refuses any first argument other than literally `--cli` (autogram-cli-launcher.c:13-17), checked at build time (build-engine.sh:105-108). The PdfaNormalize call bypasses the launcher but runs a different main class.
   Caveat: gate 3 only checks argv[1]; gates 1 and 2 are what stop a later `--url`. Also a stored `SERVER_ENABLED=true` Java pref (UserSettings.java:35-37 comment) only matters in GUIApp, not here.

## E. JavaFX-only resources inside autogram.jar (built jar is 1.39 MB, 304 classes)

Uncompressed sizes from `unzip -l autogram.jar`:
- `digital/slovensko/autogram/ui/gui/**`: 33 non-class files, 343 KB: 25 `.fxml` (81 KB), css (`macos-native.css` 61 KB, `macos-native-dark.css` 16 KB, `idsk.css` 27 KB, ...), `Autogram.png` 102 KB, `logo_OPII_ESIF.png` 54 KB,
  `language/l10n*.properties` (4 files, 101 KB; the ResourceBundle is also read from non-GUI code, so keep unless you verify `SupportedLanguage` is never needed), empty dir `ui/gui/vendor/pdfjs/`.
- `server/` assets (HTTP API only): `swagger-ui-bundle-v5.11.0.js` 1.40 MB, `swagger-ui-v5.11.0.css` 152 KB, `server.yml` 413 KB = 1.97 MB uncompressed (not JavaFX, but unreachable for the same reason as D).
- No fonts (no .ttf/.otf) anywhere in the jar. Engine resources that ARE used by the machine path: `core/lotlKeyStore.p12`, `core/simple-report-template.html` + xslt (SignatureValidator.java:144,174), `core/eforms/xmldatacontainer.xsd` (XDCValidator.java:36), `harica-rsa-2021.pem`, `drivers/FakeTokenDriver.keystore`.
- Net effect: removing GUI + server resources saves well under 1 MB compressed. The size win is in the runtime (libjfxwebkit 105 MB, javafx.web module, media) and in 42.7 MB of JavaFX jars, not in autogram.jar.

## Gaps / what a static read cannot prove, and how to confirm
Nothing below was run (instructions: static only). To confirm, with a scratch copy or the built bundle, from a shell:

    A=.../Chevron7.app/Contents
    # javafx classes touched by CAPABILITIES (expect none) and by SIGN (expect javafx.graphics/base via Logging)
    printf '{"protocolVersion":1,"requestId":"x","operation":"CAPABILITIES","payload":{}}\n' | \
      $A/runtime/bin/java -Xlog:class+load:file=/tmp/cl.log -cp "$A/app/autogram.jar:$A/app/dependency-jars/*" \
      digital.slovensko.autogram.Main --cli --machine-readable --protocol-version 1 --operation CAPABILITIES
    grep -cE 'javafx|jdk.net|java.sql|java.net.http|javax.script|jdk.httpserver|javax.lang.model' /tmp/cl.log
    # then a real or Demo-keystore SIGN (and a TSA request) and repeat the grep; also run PdfaNormalize with -Xlog:class+load.

- Whether `QuantumToolkit.init()` loads libglass/libprism natives in this headless-less (macOS) process is dynamic; the static facts are that the Toolkit object is created.
- Whether JAXB `NameConverter.toPackageName` / Saxon / rhino / woodstox are executed by VALIDATE/INSPECT, XDC and PDF/A paths needs the class-load log for those operations (INSPECT, VALIDATE, SIGN with `--eform`/XDC).
- `MachineTrustService` was not read line by line for javafx usage; grep shows no `Logging`/`Platform` use in ui/machine/**. The v2 TIMESTAMP op is unimplemented in the engine (MachineV2CliApp.java:96).
- Safe removal order if you proceed: (1) patch `Logging.log` to not call `Platform`; (2) drop javafx.controls/fxml/web (media/jsobject/xml.dom, java.scripting and java.net.http follow) and the 12 JavaFX jars; (3) optionally javafx.graphics/base + jdk.unsupported + the `--enable-native-access=...,javafx.graphics` flag; (4) drop jdk.httpserver; (5) keep java.sql/java.compiler unless a class-load log of INSPECT/VALIDATE/SIGN shows them unloaded. Keep jdk.net, java.naming, java.desktop (+java.datatransfer, java.prefs), jdk.crypto.cryptoki. Note an engine source edit is needed (step 1) and the rename boundary (scripts/check-rename-boundary.sh) governs what in engine/ may change.
