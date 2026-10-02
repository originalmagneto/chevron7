# Czech Qualified Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chevron7 signs PDFs with Czech qualified certificates (Czech I.CA cards, PostSignum and eIdentity tokens, the eObčanka) on macOS, asks for the right code (PIN or QPIN) the right way, and steers Czech filings to PAdES.

**Architecture:** The Java engine learns to report each token's protected-authentication-path flag and gains the missing Czech PKCS#11 drivers; the Swift provider derives its PIN behaviour from that flag instead of the driver name, never re-sends a per-signature QPIN, and names Czech cards correctly. Czech timestamp services with credentials come last, on top of the in-flight TSA fix. ZaKo, EZZK and the mandate certificate stay Slovak and untouched.

**Tech Stack:** Java 25 engine (DSS, SunPKCS11, java.lang.foreign), Swift 6 / SwiftUI app (Chevron7Kit, Chevron7App), JUnit 5, XCTest, the Finder Quick Action shell script.

**Spec:** `Chevron7/docs/research/2026-10-02-czech-signing.md` (sections 4, 6 and 7 are the requirements; section 7.4 lists what must be measured on hardware first).

**Depends on (merge first, then rebase this branch):**
- The fix for the driver list and the TSA choice (task "Fix driver list and TSA choice in engine signing"): per-driver resolution in `AutogramCLIEngine.drivers()` and the TSA choice reaching the engine, including TSA credentials.
- The fix for XPC caller validation of the Safari web bridge (no file overlap expected, but it touches `WebSigningPrompt`/listener code near Task 8).

## Global Constraints

- Never use em dashes in any code comment, string or document; use hyphens, colons or parentheses.
- End-user strings are Slovak; code, comments and docs are English.
- Keep `AGENTS.md` and `CLAUDE.md` in complete sync.
- Tests never touch `~/Library/Application Support/Chevron7`, `~/Library/Caches/Chevron7`, named `UserDefaults` suites or `UserDefaults.standard` (`RealStorageGuard`, `MemoryUserDefaults`, `makeSettingsStore()`).
- Apple Silicon only; a driver without an arm64 slice is skipped (behaviour of the dependency fix), never loaded.
- Do not change `Config/*.entitlements`; `disable-library-validation` already lets third-party PKCS#11 libraries load in `java` and `pkcs11-helper`.
- ZaKo, EZZK, `MandateCertificate` and the SAK profile stay out of scope.
- Rename boundary: `Chevron7/scripts/check-rename-boundary.sh --strict` must stay as green as on main (its one known finding, `ServicesProvider.legacyBundleIdentifier`, predates this work).
- A signed build must sign with a real card before release (`Chevron7/docs/RELEASING.md`).
- Build and test commands: engine `cd engine && ./mvnw -q test` with `JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca"`; app `cd Chevron7 && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`; engine bundle `Chevron7/scripts/build-engine.sh` with `AUTOGRAM_JAVA_HOME` set the same way.

## Review Focus

1. **A token whose flag cannot be read** (`C_GetTokenInfo` fails, older middleware): the app must behave exactly as today (eID protected, everything else typed PIN). Pinned in Task 3 (`testUnknownFlagFallsBackToTheDriverRule`).
2. **A remembered PIN re-sent to a QPIN token:** three wrong QPINs block an eObčanka for good. The app must never reuse a stored code for a token that asks per signature. Pinned in Task 5 (`testQPINIsNeverRemembered`).
3. **Two cards at once** (Slovak eID plus a Czech card): the driver order decides; the eID must keep winning and the Czech card must still be listed. Pinned in Task 2 (`macDriversKeepTheEIDFirst`).
4. **An eIdentity or PostSignum certificate named as the Slovak ID card:** "eid" is a substring of "eidentity". Pinned in Task 4 (`testEIdentityIsNotTheSlovakIDCard`).
5. **A trusted-list setting inherited from an installed upstream Autogram without CZ:** Czech qualifications would come out undecided. Pinned in Task 6 (`machineSettingsAlwaysTrustSlovakAndCzechLists`).

---

### Task 1: Hardware fact sheet (measurement, no production code)

Everything after this task assumes facts the research could not verify. This task measures them and records them as test fixtures.

**Files:**
- Create: `Chevron7/docs/research/2026-10-czech-hardware-facts.md`
- Create: `engine/src/test/resources/digital/slovensko/autogram/czech/` (certificate DER files, public parts only, one per device)

**Interfaces:**
- Produces: the fact sheet table (library path, arm64, protected path flag, `CKA_ALWAYS_AUTHENTICATE`, issuer CN, key type and size, QC statements) that Tasks 2 to 5 cite; DER fixtures for Task 4.

- [ ] **Step 1: Install the middleware on the Mac Studio** (each from the vendor; record version and date): eObčanka 3.7.0 (info.identita.gov.cz), I.CA SecureStore 8.3.1 (already installed), Thales SafeNet Authentication Client 10.9, Bit4id PKI Manager (if a PostSignum TokenME is available), MONET+ ProID+ (if a ProID+Q token is available).

- [ ] **Step 2: Record architecture of every library**

```bash
for f in /usr/local/lib/eOPCZE/libeopproxyp11.dylib /usr/local/lib/pkcs11/libICASecureStorePkcs11.dylib /usr/local/lib/libeTPkcs11.dylib /usr/local/lib/libIDPrimePKCS11.dylib /Library/bit4id/pkcs11/libbit4xpki.dylib /usr/local/lib/ProIDPlus/libproidqcm11.dylib; do [ -e "$f" ] && echo "$f: $(lipo -archs "$f")"; done
```

Expected: each present library lists `arm64` (or note that it does not).

- [ ] **Step 3: Record token flags and key attributes** with OpenSC's `pkcs11-tool` (`brew install opensc`) for each inserted card:

```bash
pkcs11-tool --module /usr/local/lib/eOPCZE/libeopproxyp11.dylib -T
pkcs11-tool --module /usr/local/lib/eOPCZE/libeopproxyp11.dylib -O
```

Note from `-T` whether "PIN pad present" or "protected authentication path" appears in the token flags; from `-O` (with `--login` only if needed) whether the signing private key shows `always authenticate`.

- [ ] **Step 4: Export the public certificates** (`pkcs11-tool --module ... -r --type cert --id <id> -o cz-eop.der`) into the fixtures folder and record issuer CN, `C=`, key algorithm and curve, and the QC statements (`openssl x509 -inform DER -in cz-eop.der -text -noout`).

- [ ] **Step 5: Sign once through the current app build** with each card (expect failures: the point is to see which PIN window appears, how many times, and what the engine reports). Record the exact behaviour per device.

- [ ] **Step 6: Commit**

```bash
git add Chevron7/docs/research/2026-10-czech-hardware-facts.md engine/src/test/resources/digital/slovensko/autogram/czech
git commit -m "docs: Czech card hardware facts and certificate fixtures"
```

---

### Task 2: Engine reports the protected-authentication-path flag and lists the Czech drivers

**Files:**
- Modify: `engine/src/main/java/digital/slovensko/autogram/drivers/PKCS11TokenPresenceProbe.java`
- Modify: `engine/src/main/java/digital/slovensko/autogram/drivers/TokenDriver.java:34-36`
- Modify: `engine/src/main/java/digital/slovensko/autogram/drivers/PKCS11TokenDriver.java:30-32`
- Modify: `engine/src/main/java/digital/slovensko/autogram/ui/machine/MachineDriverService.java:101-114`
- Modify: `engine/src/main/java/digital/slovensko/autogram/core/DefaultDriverDetector.java:15-34,69-80`
- Modify: `engine/src/main/java/digital/slovensko/autogram/core/AppStarter.java:29`
- Test: `engine/src/test/java/digital/slovensko/autogram/drivers/PKCS11TokenPresenceProbeTest.java`
- Test: `engine/src/test/java/digital/slovensko/autogram/ui/machine/MachineDriverServiceTest.java`
- Create test: `engine/src/test/java/digital/slovensko/autogram/core/DefaultDriverDetectorTest.java`

**Interfaces:**
- Produces: DRIVERS payload field `"protectedAuthenticationPath"`: `true`, `false` or JSON `null` (unknown). Short names `"safenet"` and `"bit4id"`.

- [ ] **Step 1: Write the failing probe test** (pure flag decoding, no library needed)

```java
@Test
void protectedAuthenticationPathFlagIsBit0x100() {
    assertTrue(PKCS11TokenPresenceProbe.hasProtectedAuthenticationPath(0x100L));
    assertTrue(PKCS11TokenPresenceProbe.hasProtectedAuthenticationPath(0x100L | 0x400L));
    assertFalse(PKCS11TokenPresenceProbe.hasProtectedAuthenticationPath(0x400L));
    assertFalse(PKCS11TokenPresenceProbe.hasProtectedAuthenticationPath(0L));
}

@Test
void tokenInfoFlagsSitAfterTheFourFixedFields() {
    // CK_TOKEN_INFO: label[32], manufacturerID[32], model[16], serialNumber[16], then CK_FLAGS.
    assertEquals(96L, PKCS11TokenPresenceProbe.TOKEN_INFO_FLAGS_OFFSET);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd engine && ./mvnw -q test -Dtest=PKCS11TokenPresenceProbeTest`
Expected: compilation failure, `hasProtectedAuthenticationPath` not defined.

- [ ] **Step 3: Implement the probe**

Add to `PKCS11TokenPresenceProbe`:

```java
private static final long CKF_PROTECTED_AUTHENTICATION_PATH = 0x100L;
static final long TOKEN_INFO_FLAGS_OFFSET = 96L;
/** CK_TOKEN_INFO is 208 bytes with 8-byte CK_ULONG on macOS and Linux; 256 leaves room. */
private static final long TOKEN_INFO_SIZE = 256L;
private static final FunctionDescriptor GET_TOKEN_INFO = FunctionDescriptor.of(ValueLayout.JAVA_LONG,
        ValueLayout.JAVA_LONG, ValueLayout.ADDRESS);

static boolean hasProtectedAuthenticationPath(long flags) {
    return (flags & CKF_PROTECTED_AUTHENTICATION_PATH) != 0;
}

/** Empty when the library cannot be opened, no token is present or C_GetTokenInfo fails. */
static Optional<Boolean> protectedAuthenticationPath(Path libraryPath) {
    try (var arena = Arena.ofConfined()) {
        var session = open(libraryPath, arena);
        if (session == null) {
            return Optional.empty();
        }
        try {
            var tokenSlots = slotIds(session, arena, true);
            if (tokenSlots.length == 0) {
                return Optional.empty();
            }
            var symbols = SymbolLookup.libraryLookup(libraryPath, arena);
            var getTokenInfo = downcall(symbols, "C_GetTokenInfo", GET_TOKEN_INFO);
            var info = arena.allocate(TOKEN_INFO_SIZE);
            if (invoke(getTokenInfo, tokenSlots[0], info) != CKR_OK) {
                return Optional.empty();
            }
            return Optional.of(hasProtectedAuthenticationPath(
                    info.get(ValueLayout.JAVA_LONG, TOKEN_INFO_FLAGS_OFFSET)));
        } finally {
            session.close();
        }
    } catch (Throwable ignored) {
        return Optional.empty();
    }
}
```

In `TokenDriver` add `public Boolean protectedAuthenticationPath() { return null; }`; in `PKCS11TokenDriver` override it with `return PKCS11TokenPresenceProbe.protectedAuthenticationPath(getPath()).orElse(null);`.

- [ ] **Step 4: Write the failing payload test** in `MachineDriverServiceTest.driversExposeOnlyExpectedMetadata`, after the `tokenPresent` asserts:

```java
assertTrue(listed.has("protectedAuthenticationPath"));
assertTrue(listed.get("protectedAuthenticationPath").isJsonNull());
```

Run: `./mvnw -q test -Dtest=MachineDriverServiceTest` and expect FAIL.

- [ ] **Step 5: Emit the field** in `MachineDriverService.driverPayload`, mirroring `tokenPresent`:

```java
var protectedPath = driver.protectedAuthenticationPath();
if (protectedPath == null) {
    payload.add("protectedAuthenticationPath", com.google.gson.JsonNull.INSTANCE);
} else {
    payload.addProperty("protectedAuthenticationPath", protectedPath);
}
```

- [ ] **Step 6: Write the failing driver-list test** (`DefaultDriverDetectorTest`; make `getMacDrivers()` package-private for it)

```java
@Test
void macDriversKeepTheEIDFirst() {
    var drivers = new DefaultDriverDetector(new FakeDriverDetectorSettings()).getMacDrivers();
    assertEquals("eid", drivers.get(0).getShortname());
}

@Test
void macDriversCoverTheCzechMiddleware() {
    var paths = new DefaultDriverDetector(new FakeDriverDetectorSettings()).getMacDrivers().stream()
            .map(d -> d.getPath().toString()).toList();
    assertTrue(paths.contains("/usr/local/lib/eOPCZE/libeopproxyp11.dylib"));
    assertTrue(paths.contains("/usr/local/lib/libeTPkcs11.dylib"));
    assertTrue(paths.contains("/Library/bit4id/pkcs11/libbit4xpki.dylib"));
}
```

Use the existing settings fake if one exists under `engine/src/test`; otherwise create `FakeDriverDetectorSettings` implementing `DriverDetectorSettings` with empty custom paths. Run and expect FAIL.

- [ ] **Step 7: Add the drivers** in `TokenDriverShortnames` (`SAFENET = "safenet"`, `BIT4ID = "bit4id"`) and in `getMacDrivers()` in this order: eID, eObčanka, I.CA SecureStore, MONET+ ProID+Q, Thales SafeNet (`/usr/local/lib/libeTPkcs11.dylib`, name "Thales SafeNet (PostSignum, eIdentity)"), Bit4id (`/Library/bit4id/pkcs11/libbit4xpki.dylib`, name "Bit4id (PostSignum TokenME)"), then the existing Gemalto, keystore, fake and custom entries. Keep a path only if Task 1 confirmed it. Set `HELPER_TEXT_CZ_EID` to: `"\n\nNa eObčanke je potrebný kvalifikovaný certifikát od poskytovateľa (napríklad PostSignum alebo I.CA). Pri každom podpise sa zadáva QPIN, nie PIN ani BOK."`. Add the two short names to the CLI help in `AppStarter.java:29`.

- [ ] **Step 8: Run the engine tests**

Run: `cd engine && ./mvnw -q test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add engine/src
git commit -m "feat(engine): report the protected PIN path and list Czech PKCS#11 drivers"
```

---

### Task 3: The app decides the PIN behaviour from the token flag

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/EngineBridge/Models/EngineModels.swift:16-28`
- Modify: `Chevron7/Sources/Chevron7Kit/EngineBridge/CLI/AutogramCLIEngine.swift` (`drivers()`, as reshaped by the dependency fix)
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/JavaEngine/EngineBridgeSigningProvider.swift:320-374,749-783`
- Test: `Chevron7/Tests/Chevron7KitTests/EngineBridgeTests.swift`

**Interfaces:**
- Consumes: DRIVERS field `protectedAuthenticationPath` (Task 2).
- Produces: `SigningDriver.protectedAuthenticationPath: Bool?`; `EngineBridgeSigningProvider.requiresPIN(driverID: String, protectedPath: Bool?) -> Bool`. The one-argument `requiresPIN(driverID:)` stays and delegates with `nil`.

- [ ] **Step 1: Write the failing tests**

```swift
func testTheTokenFlagDecidesThePINWindow() {
    XCTAssertFalse(EngineBridgeSigningProvider.requiresPIN(driverID: "cz_eid", protectedPath: true))
    XCTAssertTrue(EngineBridgeSigningProvider.requiresPIN(driverID: "eid", protectedPath: false))
}

func testUnknownFlagFallsBackToTheDriverRule() {
    XCTAssertFalse(EngineBridgeSigningProvider.requiresPIN(driverID: "eid", protectedPath: nil))
    XCTAssertTrue(EngineBridgeSigningProvider.requiresPIN(driverID: "secure_store", protectedPath: nil))
    XCTAssertTrue(EngineBridgeSigningProvider.requiresPIN(driverID: "cz_eid", protectedPath: nil))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd Chevron7 && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter EngineBridgeTests`
Expected: compilation failure.

- [ ] **Step 3: Implement**

```swift
/// Whether the app has to collect the PIN. A token that reports
/// CKF_PROTECTED_AUTHENTICATION_PATH asks in its own window; without the flag
/// only the Slovak eID is known to do so.
public static func requiresPIN(driverID: String, protectedPath: Bool?) -> Bool {
    if let protectedPath { return !protectedPath }
    return driverID != Self.driverID
}

public static func requiresPIN(driverID: String) -> Bool {
    requiresPIN(driverID: driverID, protectedPath: nil)
}
```

Add `let protectedAuthenticationPath: Bool?` (default `nil`) to `SigningDriver`, read it in `AutogramCLIEngine.drivers()` with `bool(in: candidate["protectedAuthenticationPath"])`, keep a `[String: Bool?]` of flags next to the cached driver fingerprint in the provider, and pass the flag of the chosen driver everywhere `requiresPIN(driverID:)` is called today (`signsWithoutCertificateDiscovery`, `enginePIN`, `syntheticIdentity`, `identityInfo`, `sign`). Give those functions a `protectedPath: Bool? = nil` parameter so existing call sites and tests keep compiling.

- [ ] **Step 4: Run the Kit tests**

Run: `swift test --filter EngineBridgeTests`
Expected: PASS, including the unchanged eID tests.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7Kit Chevron7/Tests/Chevron7KitTests/EngineBridgeTests.swift
git commit -m "feat(signing): decide the PIN window from the token, not the driver name"
```

---

### Task 4: Czech cards and issuers are named correctly

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/SigningProvider.swift:46-51` (`cardKindLabel`), `:519-520` (`qualifiedIssuerHints`), `:942-954` (`issuerHint`)
- Modify: `Chevron7/Sources/Chevron7App/CardReaderStatus.swift:75` (empty-state text)
- Test: `Chevron7/Tests/Chevron7KitTests/EngineBridgeTests.swift`, `Chevron7/Tests/Chevron7AppTests/SmartcardBadgeTests.swift`

**Interfaces:**
- Produces: labels "eObčanka (CZ)", "Token PostSignum", "Token eIdentity", "Karta I.CA" (CZ and SK alike).

- [ ] **Step 1: Write the failing tests**

```swift
func testEIdentityIsNotTheSlovakIDCard() {
    let cert = SigningIdentityInfo(id: "engine-cert:7", label: "Jan Novák",
                                   issuerSummary: "eIdentity ACAeID3.2", requiresPIN: true)
    XCTAssertEqual(cert.cardKindLabel, "Token eIdentity")
    XCTAssertEqual(KeychainIdentityScanner.issuerHint(from: "eIdentity ACAeID3.2"), "eIdentity")
}

func testCzechIssuersAreNamed() {
    let post = SigningIdentityInfo(id: "x", label: "Jan Novák",
                                   issuerSummary: "PostSignum Qualified CA 4", requiresPIN: true)
    XCTAssertEqual(post.cardKindLabel, "Token PostSignum")
    let icaCZ = SigningIdentityInfo(id: "y", label: "Jan Novák",
                                    issuerSummary: "I.CA EU Qualified CA2/RSA 06/2022", requiresPIN: true)
    XCTAssertEqual(icaCZ.cardKindLabel, "Karta I.CA")
}
```

Replace the issuer strings with the exact CNs recorded in Task 1 before running.

- [ ] **Step 2: Run to verify they fail** (`swift test --filter EngineBridgeTests`).

- [ ] **Step 3: Implement**

```swift
public var cardKindLabel: String? {
    let text = "\(label) \(issuerSummary)"
    if text.localizedCaseInsensitiveContains("eIdentity") || text.contains("ACAeID") { return "Token eIdentity" }
    if text.localizedCaseInsensitiveContains("PostSignum") { return "Token PostSignum" }
    if text.contains("I.CA") { return "Karta I.CA" }
    if usesProtectedAuthenticationPath || text.localizedCaseInsensitiveContains("eID") {
        return "Občiansky preukaz (eID)"
    }
    return nil
}
```

The eObčanka has no distinctive issuer (its certificate comes from PostSignum or I.CA), so name it from the driver: in `syntheticIdentity` and `identityInfo`, when the chosen driver id is `cz_eid`, set the label prefix so `cardKindLabel` returns "eObčanka (CZ)" (add that branch first in `cardKindLabel`, matching a `driverKind` field you add to `SigningIdentityInfo` with default `nil`). In `issuerHint` check `"eidentity"` before `"eid"` and add `"postsignum"`; add both to `qualifiedIssuerHints`. Change the empty text in `CardReaderStatus` to "Vložte podpisovú kartu".

- [ ] **Step 4: Update the existing label tests** in `SmartcardBadgeTests` to the new empty text, run `swift test --filter SmartcardBadgeTests` and `--filter EngineBridgeTests`, expect PASS.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources Chevron7/Tests
git commit -m "feat(signing): name Czech cards and issuers"
```

---

### Task 5: QPIN, asked per signature and never remembered

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/JavaEngine/EngineBridgeSigningProvider.swift` (new `pinKind`)
- Modify: `Chevron7/Sources/Chevron7App/SigningSessionStore.swift` (PIN field label, remembered PIN, batch note)
- Modify: `Chevron7/Sources/Chevron7App/Views/SigningFlowViews.swift` (PIN field title, batch hint)
- Test: `Chevron7/Tests/Chevron7KitTests/EngineBridgeTests.swift`, `Chevron7/Tests/Chevron7AppTests/SigningBatchTests.swift`

**Interfaces:**
- Produces: `enum SigningPINKind: Equatable, Sendable { case pin, qpin, middlewareWindow }` and `EngineBridgeSigningProvider.pinKind(driverID: String, protectedPath: Bool?) -> SigningPINKind`; `SigningPINKind.mayBeRemembered: Bool` (false for `.qpin`).

- [ ] **Step 1: Write the failing tests**

```swift
func testEObcankaAsksForTheQPIN() {
    XCTAssertEqual(EngineBridgeSigningProvider.pinKind(driverID: "cz_eid", protectedPath: false), .qpin)
    XCTAssertEqual(EngineBridgeSigningProvider.pinKind(driverID: "cz_eid", protectedPath: true), .middlewareWindow)
    XCTAssertEqual(EngineBridgeSigningProvider.pinKind(driverID: "secure_store", protectedPath: nil), .pin)
    XCTAssertEqual(EngineBridgeSigningProvider.pinKind(driverID: "eid", protectedPath: nil), .middlewareWindow)
}

func testQPINIsNeverRemembered() {
    XCTAssertFalse(SigningPINKind.qpin.mayBeRemembered)
    XCTAssertTrue(SigningPINKind.pin.mayBeRemembered)
}
```

In `SigningBatchTests`, add a test that a batch on a `cz_eid` provider identity does not reuse the first entered code for the second document (use the existing `RecordingSigningProvider`, assert each recorded request after the first carries an empty PIN so the engine path prompts).

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement** `SigningPINKind` in Chevron7Kit next to `SigningIdentityInfo`, `pinKind` in the provider (`.middlewareWindow` when `!requiresPIN(driverID:protectedPath:)`, `.qpin` for `cz_eid` and for any driver Task 1 found with `always authenticate`, otherwise `.pin`). In `SigningSessionStore`, do not store or reuse the entered code when the selected identity's kind has `mayBeRemembered == false`; label the field "QPIN (kód pre kvalifikovaný podpis)" for `.qpin`; in batch mode with `.qpin` show "Pri každom dokumente zadáte QPIN znova." in the batch settings card.

- [ ] **Step 4: Run all app tests** (`swift test`), expect PASS.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources Chevron7/Tests
git commit -m "feat(signing): ask for the QPIN per signature and never remember it"
```

---

### Task 6: Slovak and Czech trusted lists are always on

**Files:**
- Modify: `engine/src/main/java/digital/slovensko/autogram/ui/machine/MachineSettings.java:31-33`
- Test: `engine/src/test/java/digital/slovensko/autogram/ui/machine/MachineSettingsTest.java`

- [ ] **Step 1: Write the failing test**

```java
@Test
void machineSettingsAlwaysTrustSlovakAndCzechLists() {
    assertEquals(List.of("AT", "SK", "CZ"), MachineSettings.withRequiredCountries(List.of("AT")));
    assertEquals(List.of("SK", "CZ"), MachineSettings.withRequiredCountries(List.of("SK", "CZ")));
    assertEquals(List.of("SK", "CZ"), MachineSettings.withRequiredCountries(List.of()));
}
```

- [ ] **Step 2: Run to verify it fails** (`./mvnw -q test -Dtest=MachineSettingsTest`).

- [ ] **Step 3: Implement**

```java
static List<String> withRequiredCountries(List<String> configured) {
    var countries = new java.util.ArrayList<>(configured);
    for (var required : List.of("SK", "CZ")) {
        if (!countries.contains(required)) {
            countries.add(required);
        }
    }
    return List.copyOf(countries);
}
```

and in the constructor `trustedList = withRequiredCountries(loaded.getTrustedList());`.

- [ ] **Step 4: Run engine tests, expect PASS. Rebuild the engine** (`Chevron7/scripts/build-engine.sh`).

- [ ] **Step 5: Commit**

```bash
git add engine/src
git commit -m "fix(engine): always load the Slovak and Czech trusted lists"
```

---

### Task 7: Steer Czech filings to PAdES

Czech courts accept PAdES in PDF/A and MS Praha refuses ASiC-E (research section 2).

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/Views/SigningFlowViews.swift` (format picker in the inspector)
- Modify: `Chevron7/Sources/Chevron7Kit/Models/UXLabels.swift`
- Create test: `Chevron7/Tests/Chevron7KitTests/UXLabelsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testASiCHintMentionsCzechCourts() {
    let hint = UXLabels.asicCountryHint
    XCTAssertTrue(hint.contains("ASiC-E"))
    XCTAssertTrue(hint.contains("PAdES"))
    XCTAssertFalse(hint.contains("\u{2014}"))
}
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** `static let asicCountryHint = "České súdy kontajner ASiC-E neprijímajú. Pre podanie v Česku zvoľte PAdES (podpis priamo v PDF)."` and show it as a caption under the ASiC-E option when it is selected. When the selected identity's card kind is Czech (Task 4 labels "eObčanka (CZ)", "Token PostSignum", "Token eIdentity"), preselect PAdES for an unsigned PDF.

- [ ] **Step 4: Run app tests, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources Chevron7/Tests
git commit -m "feat(signing): steer Czech filings to PAdES"
```

---

### Task 8: Finder Quick Action and middleware PIN windows

**Files:**
- Modify: `Chevron7/Assets/Chevron7 Finder Quick Action.workflow/Contents/Resources/chevron7-quick-action.sh:23,123-126`
- Modify: `engine/scripts/native-macos/autogram-quick-action-runner.swift:55,60` (error texts; no product name, rename boundary)
- Modify: `Chevron7/Sources/Chevron7App/WebSigningPrompt.swift:190-193` (`isEIDKeyboard`)

- [ ] **Step 1: Extend the driver menu** to `{"I.CA SecureStore", "Občiansky preukaz (eID klient)", "eObčanka", "Thales SafeNet (PostSignum, eIdentity)"}` and `driver_shortname` with `"eObčanka") printf '%s\n' "cz_eid" ;;` and `"Thales SafeNet (PostSignum, eIdentity)") printf '%s\n' "safenet" ;;`. For `cz_eid` change the PIN dialog prompt to "Zadajte QPIN (kód pre kvalifikovaný podpis)".

- [ ] **Step 2: Generalise the runner's error texts** to "Podpisová karta nie je pripojená alebo jej ovládač nie je nainštalovaný." (no card or product names).

- [ ] **Step 3: Generalise `isEIDKeyboard`** to recognise the PIN window processes recorded in Task 1 (bundle identifiers or executable paths), keeping the eID `VirtualKeyboard` match.

- [ ] **Step 4: Verify** with `bash -n` on the script, `Chevron7/scripts/check-rename-boundary.sh --strict`, a rebuilt app, and one Quick Action signature with a Czech card.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Assets engine/scripts Chevron7/Sources/Chevron7App/WebSigningPrompt.swift
git commit -m "feat(quick-action): Czech cards and QPIN in the Finder Quick Action"
```

---

### Task 9: Czech qualified timestamps with credentials (optional, after the TSA fix)

Free EU qualified TSAs already work for Czech documents (eIDAS Art. 41(3)); this task only adds Czech providers for users who have a package.

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/TimestampAuthority.swift:21-27`
- Modify: the TSA credentials store and Settings UI introduced by the dependency fix
- Create: `Chevron7/Sources/Chevron7Kit/Resources/ica-tls-root-ca-rsa-05-2022.der` (from I.CA, fingerprint recorded in the commit message)
- Test: `Chevron7/Tests/Chevron7KitTests/TimestampClientTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testCzechAuthoritiesNeedCredentialsAndAreNeverDefaults() {
    let czech = TimestampAuthority.builtIn.filter { $0.name.contains("(CZ") }
    XCTAssertEqual(czech.count, 2)
    XCTAssertTrue(czech.allSatisfy(\.requiresCredentials))
    XCTAssertFalse(TimestampAuthority.qualifiedURLs.contains { url in czech.contains { $0.url == url.absoluteString } })
}
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** a `requiresCredentials: Bool` field (default `false`), entries "PostSignum (CZ, kvalifikovaná, s prihlásením)" `https://www.postsignum.cz/TSS/TSS_user/` and "I.CA (CZ, kvalifikovaná, s prihlásením)" `https://tsabase.ica.cz/cgi-bin/razitko_base2.cgi`, exclude credentialed entries from `qualifiedURLs` (ZaKo must never depend on a paid account), require stored Basic credentials before such an entry can be selected, and trust the bundled I.CA TLS root only for `tsabase.ica.cz` (pin like `EZZKEnvironment.pinnedCertificateSHA256`).

- [ ] **Step 4: Verify against the real services** with a PostSignum prepaid package and the I.CA test TSA (tsa@ica.cz); check the timestamp in the signed PDF with the engine INSPECT.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources Chevron7/Tests
git commit -m "feat(signing): Czech qualified timestamps with credentials"
```

---

### Task 10: Docs, release notes and the release gate

**Files:**
- Modify: `AGENTS.md`, `CLAUDE.md` (identical edits)
- Modify: `README.md` (supported cards)
- Modify: `PRODUCT.md` (move "other national eID cards" from undecided to shipped for Czechia only)
- Create: `docs/releases/vX.Y.Z.md` if the release deserves hand-written notes

- [ ] **Step 1: Document** the token-flag PIN rule, QPIN handling, the Czech drivers and labels, the always-on SK/CZ trusted lists, the PAdES steer and (if done) Czech TSAs in `AGENTS.md`/`CLAUDE.md`; run `cmp AGENTS.md CLAUDE.md`.

- [ ] **Step 2: Release gate on a Developer ID build**: sign a PDF with each device from Task 1 through the main window and the Quick Action; validate every output with the engine (`VALIDATE`) and with the DIA validation service; confirm no Slovak regression with the Slovak eID and an SAK card (main window, batch, ZaKo authorization in EZZK test mode).

- [ ] **Step 3: Commit and open the PR**

```bash
git add AGENTS.md CLAUDE.md README.md PRODUCT.md docs/releases
git commit -m "docs: Czech qualified signing"
```

The website may claim Czech card support only after this ships (PRODUCT.md rule: claims must stay true of the shipped build).
