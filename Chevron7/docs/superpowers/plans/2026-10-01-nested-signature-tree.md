# Signature Tree Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show every signature of a document in a tree (container signatures and the signatures inside embedded PDF or ASiC data objects), first structurally and then validated against the EU trusted lists, with a worst-of summary and an "Overiť znova" button.

**Architecture:** The engine's `MachineInspectionService` walks an ASiC container's data objects one level deep and returns the tree inside the existing INSPECT / VALIDATE payload (additive fields). Swift decodes it into `SignatureTree`, the provider exposes `inspectSignatureTree` and `validateSignatureTree`, `SigningSessionStore` keeps a `SignatureTreeState` (tree plus phase) for the source and the signed output, and a new `SignatureTreeView` renders it in the prepare inspector and in "Overenie podpisov v súbore".

**Tech Stack:** Java 25 / DSS (engine, JUnit 5, Mockito), Swift 6 / SwiftUI / XCTest (app), machine protocol v1 (INSPECT) and v2 (VALIDATE).

**Spec:** `Chevron7/docs/superpowers/specs/2026-10-01-nested-signature-tree-design.md` (revision 2)

## Global Constraints

- Never use em dashes in any text (code comments, UI strings, docs, commit messages).
- English for code comments and identifiers; Slovak for user-facing strings.
- Keep `AGENTS.md` and `CLAUDE.md` at the repository root identical.
- Rename boundary: `Chevron7/scripts/check-rename-boundary.sh` must pass; nothing in `engine/` may mention Chevron7.
- Engine tests: `cd engine && JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" ./mvnw -q test -Dtest=<Class>` (no `-o`; `-q` prints nothing on success, read `target/surefire-reports/TEST-*.xml` for counts).
- Swift tests: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter <TestClass>`.
- Engine rebuild: `AUTOGRAM_JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" Chevron7/scripts/build-engine.sh` (a trailing "Killed: 9" in the smoke step is expected).
- The machine protocol shape is additive: existing fields keep name and meaning.
- Nested size limit: 100 MB (`100L * 1024 * 1024`); depth: data objects of the top document only.
- Payload values: `nested.kind` is `"PDF"` or `"ASIC"`; `nestedSkipped` is `"DEPTH_LIMIT"` or `"TOO_LARGE"`; `nestedError` is `"NESTED_INSPECTION_FAILED"`.
- Tests never touch the real `~/Library/Application Support/Chevron7` (App tests use `makeSettingsStore()`).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A container whose data object is a PDF *named* `.txt` or `.bin`: the bytes decide, so its PAdES signatures still show (Task 2 test `kindFollowsBytesNotName`).
2. Two data objects with the same signature id (two PDFs signed by the same tool can repeat DSS ids): each stays under its own data object, nothing merges across levels (Task 4 test `testSameSignatureIdOnTwoLevelsStaysSeparate`).
3. The user switches to another document while validation of the previous one is still running: the late result must not appear on the new document (Task 6 test `testStaleValidationIsDropped`).
4. Trusted lists unavailable (offline): states stay as the structural result says and are never upgraded to valid (Task 6 test `testValidationUnavailableKeepsStructuralTree`; Task 4 test `testStructuralTimestampIsNotQualified`).
5. Structural inspection fails on a broken file: the prepare view must say "Podpisy sa nepodarilo skontrolovať", never "Dokument zatiaľ neobsahuje elektronický podpis" (Task 6 test `testFailedInspectionIsNotEmpty`, Task 7 test `testFailedPhaseText`).

---

## File Structure

Engine (`engine/`):
- Modify `src/main/java/digital/slovensko/autogram/ui/machine/MachineInspectionService.java`: shared tree walk `inspectTree`, structural coverage, nested data objects, size limit.
- Create `src/test/java/digital/slovensko/autogram/ui/machine/TestContainers.java`: builds signed ASiC-E containers in tests with the test keystore.
- Create `src/test/java/digital/slovensko/autogram/ui/machine/MachineInspectionTreeTest.java`: tree tests (kept apart from the long `MachineInspectionServiceTest`).
- Modify `src/test/java/digital/slovensko/autogram/ui/machine/MachineCliAppTest.java` and `src/test/java/digital/slovensko/autogram/ui/machine/v2/MachineV2CliAppTest.java`: one protocol test each.

Swift Kit (`Chevron7/Sources/Chevron7Kit/`):
- Create `Signing/SignatureTree.swift`: `SignatureTree`, `SignedDataObject`, `SignatureTreeResult`, `SignatureTreeSummary`.
- Modify `Signing/SigningProvider.swift`: `DocumentSignatureInfo` fields, protocol requirements and defaults.
- Create `EngineBridge/CLI/SignatureTreeDecoder.swift`: payload to `SignatureTree`.
- Modify `EngineBridge/Models/InspectionModels.swift`: `InspectedPDF.tree`.
- Modify `EngineBridge/CLI/AutogramCLIEngine.swift`: decode the tree for INSPECT and VALIDATE; `hasQualifiedTimestamp` only from `qualifiedTimestampValid`.
- Modify `Signing/JavaEngine/EngineBridgeSigningProvider.swift`: `inspectSignatureTree`, `validateSignatureTree`.

Swift App (`Chevron7/Sources/Chevron7App/`):
- Create `SignatureTreeState.swift`: state and phase.
- Modify `SigningSessionStore.swift`: states, run tokens, background validation, revalidation.
- Create `Views/SignatureTreeView.swift`: the tree view and `SignatureTreePresentation` texts.
- Modify `Views/SigningFlowViews.swift`: use the tree view in prepare and done; `SignatureInfoRow` coverage and timestamp label.

Tests (`Chevron7/Tests/`):
- Create `Chevron7KitTests/SignatureTreeTests.swift` (model, summary, decoder).
- Create `Chevron7KitTests/SignatureTreeProviderTests.swift` (provider with a fake engine).
- Create `Chevron7AppTests/SignatureTreeStoreTests.swift` (store phases).
- Create `Chevron7AppTests/SignatureTreePresentationTests.swift` (texts).
- Modify `Chevron7KitTests/LiveEngineInspectionTests.swift` (live tree).

Docs: root `CLAUDE.md` and `AGENTS.md` (one sentence in the "Signing an already signed document" bullet).

---

### Task 1: Engine test support and the structural tree for a container around a signed PDF

**Files:**
- Create: `engine/src/test/java/digital/slovensko/autogram/ui/machine/TestContainers.java`
- Create: `engine/src/test/java/digital/slovensko/autogram/ui/machine/MachineInspectionTreeTest.java`
- Modify: `engine/src/main/java/digital/slovensko/autogram/ui/machine/MachineInspectionService.java` (`inspect(Path)`, `inspectStructurally`, new `inspectTree`, `addNestedContent`, `nestedKind`)

**Interfaces:**
- Produces: `TestContainers.resource(String name) -> byte[]`, `TestContainers.signedXadesContainer(Map<String, byte[]> documents) -> byte[]` (ASiC-E, XAdES Baseline B, test keystore); `MachineInspectionService.inspect(Path)` returns the tree in structural mode; private `JsonObject inspectTree(DSSDocument document, int depth)`.

- [ ] **Step 1: Write the test support class**

```java
package digital.slovensko.autogram.ui.machine;

import eu.europa.esig.dss.asic.xades.ASiCWithXAdESSignatureParameters;
import eu.europa.esig.dss.asic.xades.signature.ASiCWithXAdESService;
import eu.europa.esig.dss.enumerations.ASiCContainerType;
import eu.europa.esig.dss.enumerations.DigestAlgorithm;
import eu.europa.esig.dss.enumerations.MimeTypeEnum;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.enumerations.SignaturePackaging;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.token.Pkcs12SignatureToken;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Map;
import java.util.Objects;

/// Signed ASiC-E containers built in tests with the test keystore, so a tree test never
/// depends on a fixture whose provenance is unknown.
final class TestContainers {
    private TestContainers() {
    }

    static Path resourcePath(String name) {
        return Path.of(Objects.requireNonNull(TestContainers.class
                .getResource("/digital/slovensko/autogram/" + name)).getFile());
    }

    static byte[] resource(String name) throws IOException {
        return Files.readAllBytes(resourcePath(name));
    }

    /// One XAdES Baseline B signature over every given document, in insertion order.
    static byte[] signedXadesContainer(Map<String, byte[]> documents) throws IOException {
        try (var token = new Pkcs12SignatureToken(resourcePath("test.keystore").toString(),
                new KeyStore.PasswordProtection("".toCharArray()))) {
            var key = token.getKeys().get(0);
            var parameters = new ASiCWithXAdESSignatureParameters();
            parameters.aSiC().setContainerType(ASiCContainerType.ASiC_E);
            parameters.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
            parameters.setSignaturePackaging(SignaturePackaging.ENVELOPING);
            parameters.setDigestAlgorithm(DigestAlgorithm.SHA256);
            parameters.setSigningCertificate(key.getCertificate());
            parameters.setCertificateChain(key.getCertificateChain());
            var service = new ASiCWithXAdESService(new CommonCertificateVerifier());
            var content = new ArrayList<DSSDocument>();
            for (var entry : documents.entrySet()) {
                content.add(new InMemoryDocument(entry.getValue(), entry.getKey(), mimeType(entry.getKey())));
            }
            var dataToSign = service.getDataToSign(content, parameters);
            var signatureValue = token.sign(dataToSign, parameters.getDigestAlgorithm(), key);
            var signed = service.signDocument(content, parameters, signatureValue);
            try (var stream = signed.openStream()) {
                return stream.readAllBytes();
            }
        }
    }

    private static MimeTypeEnum mimeType(String name) {
        var lower = name.toLowerCase(java.util.Locale.ROOT);
        if (lower.endsWith(".pdf")) {
            return MimeTypeEnum.PDF;
        }
        if (lower.endsWith(".asice")) {
            return MimeTypeEnum.ASICE;
        }
        return MimeTypeEnum.BINARY;
    }
}
```

If `ENVELOPING` is rejected by this DSS version for ASiC-E, use `SignaturePackaging.DETACHED`; production code uses `ENVELOPING` (`SigningParameters.buildForASiCWithXAdES`).

- [ ] **Step 2: Write the failing test**

```java
package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonObject;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class MachineInspectionTreeTest {
    @TempDir
    Path temporaryDirectory;

    private Path write(String name, byte[] content) throws Exception {
        return Files.write(temporaryDirectory.resolve(name), content);
    }

    private static JsonObject document(JsonObject payload, String name) {
        return payload.getAsJsonArray("documents").asList().stream().map(value -> value.getAsJsonObject())
                .filter(entry -> name.equals(entry.get("name").getAsString())).findFirst().orElseThrow();
    }

    /// The case that started the tree: a container whose XAdES signature covers a PDF that
    /// carries its own PAdES signature.
    @Test
    void structuralInspectionShowsThePdfSignatureUnderItsDataObject() throws Exception {
        var signedPdf = TestContainers.resource("sample_signed.pdf");
        var documents = new LinkedHashMap<String, byte[]>();
        documents.put("report.pdf", signedPdf);
        var container = write("report.asice", TestContainers.signedXadesContainer(documents));

        var payload = new MachineInspectionService().inspect(container);

        var containerSignature = payload.getAsJsonArray("signatures").get(0).getAsJsonObject();
        assertEquals(List.of("report.pdf"), containerSignature.getAsJsonArray("documents").asList().stream()
                .map(value -> value.getAsString()).toList());
        var nested = document(payload, "report.pdf").getAsJsonObject("nested");
        assertEquals("PDF", nested.get("kind").getAsString());
        assertEquals(1, nested.getAsJsonArray("signatures").size());
        assertTrue(nested.getAsJsonArray("signatures").get(0).getAsJsonObject()
                .get("format").getAsString().startsWith("PAdES_"));
        assertFalse(nested.has("documents"));
    }

    /// A plain PDF keeps today's payload: no documents, no tree.
    @Test
    void plainPdfPayloadIsUnchanged() throws Exception {
        var payload = new MachineInspectionService().inspect(TestContainers.resourcePath("sample_signed.pdf"));

        assertFalse(payload.has("documents"));
        assertTrue(payload.getAsJsonArray("signatures").size() > 0);
    }
}
```

The format assertion checks only the PAdES family because the fixture's level is not part of this contract; what matters is that the PAdES signature appears under the data object.

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd engine && JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" ./mvnw -q test -Dtest=MachineInspectionTreeTest`
Expected: `structuralInspectionShowsThePdfSignatureUnderItsDataObject` FAILS (`documents` entries have no `nested`, structural signatures have no `documents`); `plainPdfPayloadIsUnchanged` passes.

- [ ] **Step 4: Implement the shared tree walk (structural part)**

In `MachineInspectionService.java` add the constant and field, route `inspect(Path)` through `inspectTree`, and extend `inspectStructurally`:

```java
    static final long DEFAULT_NESTED_SIZE_LIMIT = 100L * 1024 * 1024;
    private long nestedSizeLimit = DEFAULT_NESTED_SIZE_LIMIT;

    /// Test hook: a smaller limit for the TOO_LARGE case without a 100 MB fixture.
    MachineInspectionService withNestedSizeLimit(long bytes) {
        nestedSizeLimit = bytes;
        return this;
    }
```

Replace the body of `inspect(Path path)`:

```java
    public JsonObject inspect(Path path) {
        if (genericPathInspection) {
            return inspectTree(new FileDocument(path.toFile()), 0);
        }
        return mapReport(reportReader.read(path));
    }
```

Add the tree walk (trusted branch is completed in Task 2; for now it keeps today's trusted mapping):

```java
    /// One level of the signature tree: this document's own signatures and, for an ASiC
    /// container, its data objects. Data objects of the top document (depth 0) that are a
    /// PDF or an ASiC are inspected the same way; deeper ones are only marked.
    private JsonObject inspectTree(DSSDocument document, int depth) {
        var validator = documentValidator(document);
        JsonObject payload;
        if (validatorReportReader == null) {
            payload = inspectStructurally(document, validator);
        } else {
            var trusted = mapAsicInspection(readTrustedInspection(document, validator));
            payload = mergeStructuralIntegrityIfAvailable(trusted, document);
        }
        if (isAsic(validator) && payload.has("documents")) {
            addNestedContent(payload.getAsJsonArray("documents"), extractedDocuments(document, validator), depth);
        }
        return payload;
    }

    private void addNestedContent(com.google.gson.JsonArray entries, List<DSSDocument> extracted, int depth) {
        var byName = new LinkedHashMap<String, DSSDocument>();
        for (var candidate : extracted) {
            if (candidate.getName() != null) {
                byName.putIfAbsent(candidate.getName(), candidate);
            }
        }
        for (var element : entries) {
            var entry = element.getAsJsonObject();
            var source = byName.get(entry.get("name").getAsString());
            if (source == null) {
                continue;
            }
            try {
                var bytes = readOriginalBytes(source);
                var pdf = isPdf(bytes);
                if (!pdf && !isZip(bytes)) {
                    continue;
                }
                if (bytes.length > nestedSizeLimit) {
                    entry.addProperty("nestedSkipped", "TOO_LARGE");
                    continue;
                }
                var kind = pdf ? "PDF" : (isAsicContent(bytes, source.getName()) ? "ASIC" : null);
                if (kind == null) {
                    continue;
                }
                if (depth >= 1) {
                    entry.addProperty("nestedSkipped", "DEPTH_LIMIT");
                    continue;
                }
                var nested = inspectTree(new InMemoryDocument(bytes, source.getName()), depth + 1);
                nested.addProperty("kind", kind);
                entry.add("nested", nested);
            } catch (RuntimeException exception) {
                entry.addProperty("nestedError", "NESTED_INSPECTION_FAILED");
            }
        }
    }

    private static boolean isPdf(byte[] bytes) {
        return bytes.length >= 5 && bytes[0] == '%' && bytes[1] == 'P' && bytes[2] == 'D' && bytes[3] == 'F'
                && bytes[4] == '-';
    }

    private static boolean isZip(byte[] bytes) {
        return bytes.length >= 4 && bytes[0] == 'P' && bytes[1] == 'K' && bytes[2] == 3 && bytes[3] == 4;
    }

    private static boolean isAsicContent(byte[] bytes, String name) {
        try {
            var validator = DSSUtils.createDocumentValidator(new InMemoryDocument(bytes, name));
            return validator != null && isAsic(validator);
        } catch (RuntimeException exception) {
            return false;
        }
    }
```

Change `readTrustedInspection(Path)` to take the document and validator (Task 2 relies on this signature):

```java
    private AsicInspection readTrustedInspection(DSSDocument document, SignedDocumentValidator validator) {
        var report = validatorReportReader.read(validator);
        if (!isAsic(validator)) {
            return new AsicInspection(report, null, Map.of());
        }
        var documents = asicDocuments(document, validator);
        var coverage = new LinkedHashMap<String, List<String>>();
        for (var signatureId : report.getSignatureIdList()) {
            coverage.put(signatureId, documentNames(validator.getOriginalDocuments(signatureId)));
        }
        return new AsicInspection(report, documents, coverage);
    }
```

Replace `inspectStructurally(DSSDocument)` with a two-argument version plus a one-argument overload (used by `mergeStructuralIntegrityIfAvailable` and `inspect(byte[])`), adding coverage for ASiC:

```java
    private JsonObject inspectStructurally(DSSDocument document) {
        return inspectStructurally(document, documentValidator(document));
    }

    private JsonObject inspectStructurally(DSSDocument document, SignedDocumentValidator validator) {
        var asic = isAsic(validator);
        var payload = new JsonObject();
        var signaturePayloads = new com.google.gson.JsonArray();
        for (var signature : validator.getSignatures()) {
            var mapped = mapStructuralSignature(readStructuralSignature(signature));
            if (asic) {
                var covered = documentNames(validator.getOriginalDocuments(signature.getId()));
                if (!covered.isEmpty()) {
                    var names = new com.google.gson.JsonArray();
                    covered.forEach(names::add);
                    mapped.add("documents", names);
                }
            }
            signaturePayloads.add(mapped);
        }
        payload.add("signatures", signaturePayloads);
        if (asic) {
            var documents = new com.google.gson.JsonArray();
            for (var name : asicDocuments(document, validator)) {
                var item = new JsonObject();
                item.addProperty("name", name);
                documents.add(item);
            }
            payload.add("documents", documents);
        }
        return payload;
    }
```

Remove the now unused `readTrustedInspection(Path)`; `mapAsicInspection(readTrustedInspection(path))` callers are gone because `inspect(Path)` uses `inspectTree`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd engine && JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" ./mvnw -q test -Dtest='MachineInspectionTreeTest,MachineInspectionServiceTest'`
Expected: PASS (both classes; `MachineInspectionServiceTest` proves the old payloads did not change).

- [ ] **Step 6: Commit**

```bash
git add engine/src/main/java/digital/slovensko/autogram/ui/machine/MachineInspectionService.java engine/src/test/java/digital/slovensko/autogram/ui/machine/TestContainers.java engine/src/test/java/digital/slovensko/autogram/ui/machine/MachineInspectionTreeTest.java
git commit -m "feat(engine): strom podpisov pre PDF v kontajneri (strukturalne)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: Trusted tree, nested ASiC, limits and failures

**Files:**
- Modify: `engine/src/test/java/digital/slovensko/autogram/ui/machine/MachineInspectionTreeTest.java`
- Modify: `engine/src/main/java/digital/slovensko/autogram/ui/machine/MachineInspectionService.java` (only if a test below fails)

**Interfaces:**
- Consumes: `TestContainers`, `inspectTree`, `withNestedSizeLimit(long)` from Task 1.
- Produces: the complete engine payload contract of spec section 1.

- [ ] **Step 1: Write the tests**

Add to `MachineInspectionTreeTest` (imports: `eu.europa.esig.dss.spi.validation.CommonCertificateVerifier`, `java.util.concurrent.atomic.AtomicInteger`, `static org.junit.jupiter.api.Assertions.assertNotNull`):

```java
    private static MachineInspectionService trustedWithoutLists() {
        return MachineInspectionService.withValidatorReportReader(validator -> {
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            return validator.validateDocument().getSimpleReport();
        });
    }

    @Test
    void trustedInspectionValidatesTheNestedPdfWithTheSameReader() throws Exception {
        var documents = new LinkedHashMap<String, byte[]>();
        documents.put("report.pdf", TestContainers.resource("sample_signed.pdf"));
        var container = write("report.asice", TestContainers.signedXadesContainer(documents));
        var reads = new AtomicInteger();
        var service = MachineInspectionService.withValidatorReportReader(validator -> {
            reads.incrementAndGet();
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            return validator.validateDocument().getSimpleReport();
        });

        var payload = service.inspect(container);

        assertEquals(2, reads.get());
        var nestedSignature = document(payload, "report.pdf").getAsJsonObject("nested")
                .getAsJsonArray("signatures").get(0).getAsJsonObject();
        assertTrue(nestedSignature.has("indication"));
        assertTrue(nestedSignature.has("cryptographicIntegrity"));
        assertEquals(List.of("report.pdf"), payload.getAsJsonArray("signatures").get(0).getAsJsonObject()
                .getAsJsonArray("documents").asList().stream().map(value -> value.getAsString()).toList());
    }

    @Test
    void nestedAsicIsInspectedOneLevelAndDeeperDocumentsAreMarked() throws Exception {
        var innerDocuments = new LinkedHashMap<String, byte[]>();
        innerDocuments.put("a.pdf", TestContainers.resource("sample_signed.pdf"));
        var outerDocuments = new LinkedHashMap<String, byte[]>();
        outerDocuments.put("kontajner.asice", TestContainers.signedXadesContainer(innerDocuments));
        var container = write("outer.asice", TestContainers.signedXadesContainer(outerDocuments));

        var payload = new MachineInspectionService().inspect(container);

        var nested = document(payload, "kontajner.asice").getAsJsonObject("nested");
        assertEquals("ASIC", nested.get("kind").getAsString());
        assertEquals(1, nested.getAsJsonArray("signatures").size());
        assertEquals("DEPTH_LIMIT", document(nested, "a.pdf").get("nestedSkipped").getAsString());
        assertFalse(document(nested, "a.pdf").has("nested"));
    }

    @Test
    void tooLargeDataObjectIsMarkedAndNotInspected() throws Exception {
        var documents = new LinkedHashMap<String, byte[]>();
        documents.put("report.pdf", TestContainers.resource("sample_signed.pdf"));
        var container = write("report.asice", TestContainers.signedXadesContainer(documents));

        var payload = new MachineInspectionService().withNestedSizeLimit(16).inspect(container);

        assertEquals("TOO_LARGE", document(payload, "report.pdf").get("nestedSkipped").getAsString());
        assertFalse(document(payload, "report.pdf").has("nested"));
    }

    @Test
    void failingNestedValidationKeepsTheContainerResult() throws Exception {
        var documents = new LinkedHashMap<String, byte[]>();
        documents.put("report.pdf", TestContainers.resource("sample_signed.pdf"));
        var container = write("report.asice", TestContainers.signedXadesContainer(documents));
        var reads = new AtomicInteger();
        var service = MachineInspectionService.withValidatorReportReader(validator -> {
            if (reads.getAndIncrement() > 0) {
                throw new IllegalStateException("nested validation failed");
            }
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            return validator.validateDocument().getSimpleReport();
        });

        var payload = service.inspect(container);

        assertEquals(1, payload.getAsJsonArray("signatures").size());
        assertEquals("NESTED_INSPECTION_FAILED", document(payload, "report.pdf").get("nestedError").getAsString());
    }

    @Test
    void kindFollowsBytesNotName() throws Exception {
        var documents = new LinkedHashMap<String, byte[]>();
        documents.put("priloha.bin", TestContainers.resource("sample_signed.pdf"));
        documents.put("fake.pdf", "not a pdf".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        var container = write("mixed.asice", TestContainers.signedXadesContainer(documents));

        var payload = new MachineInspectionService().inspect(container);

        assertEquals("PDF", document(payload, "priloha.bin").getAsJsonObject("nested").get("kind").getAsString());
        var fake = document(payload, "fake.pdf");
        assertFalse(fake.has("nested"));
        assertFalse(fake.has("nestedSkipped"));
        assertFalse(fake.has("nestedError"));
    }

    @Test
    void unsignedPdfInsideAContainerHasAnEmptyNestedSignatureList() throws Exception {
        var documents = new LinkedHashMap<String, byte[]>();
        documents.put("sample.pdf", TestContainers.resource("sample.pdf"));
        var container = write("plain.asice", TestContainers.signedXadesContainer(documents));

        var nested = document(new MachineInspectionService().inspect(container), "sample.pdf")
                .getAsJsonObject("nested");

        assertNotNull(nested);
        assertEquals("PDF", nested.get("kind").getAsString());
        assertEquals(0, nested.getAsJsonArray("signatures").size());
    }

    @Test
    void byteInspectionStaysFlatForSigningOutputValidation() throws Exception {
        var documents = new LinkedHashMap<String, byte[]>();
        documents.put("report.pdf", TestContainers.resource("sample_signed.pdf"));
        var content = TestContainers.signedXadesContainer(documents);

        var payload = trustedWithoutLists().inspect(content);

        assertFalse(payload.has("documents"));
    }
```

- [ ] **Step 2: Run the tests**

Run: `cd engine && JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" ./mvnw -q test -Dtest=MachineInspectionTreeTest`
Expected: PASS if Task 1 was implemented as written. If any test fails, fix `MachineInspectionService` (not the test) and rerun. Typical causes: the trusted branch did not route through `inspectTree` (check `inspect(Path)`), or `isAsicContent` needs a name ending in `.asice` (the extracted entry keeps its name, so it does).

- [ ] **Step 3: Run the whole machine package**

Run: `cd engine && JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" ./mvnw -q test -Dtest='digital.slovensko.autogram.ui.machine.**'`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add engine/src
git commit -m "feat(engine): plne overenie vnorenych dokumentov, limity a chyby v strome

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: Protocol tests for INSPECT and VALIDATE, full engine suite, rebuild

**Files:**
- Modify: `engine/src/test/java/digital/slovensko/autogram/ui/machine/MachineCliAppTest.java`
- Modify: `engine/src/test/java/digital/slovensko/autogram/ui/machine/v2/MachineV2CliAppTest.java`

**Interfaces:**
- Consumes: `TestContainers` (package `digital.slovensko.autogram.ui.machine`; from the `v2` package make it reachable by declaring the class and its two methods `public`, or copy the container bytes through a small public helper. Use `public` on `TestContainers`, `resource`, `resourcePath` and `signedXadesContainer`).

- [ ] **Step 1: Write the v1 INSPECT test** (in `MachineCliAppTest`, which already has `temporaryDirectory`, `commandLine(String)` and imports for `JsonParser`, `StringReader`, `PrintWriter`, `StringWriter`)

```java
    /// v1 INSPECT carries the signature tree of a container around a signed PDF.
    @Test
    void inspectReturnsTheNestedPdfSignatures() throws Exception {
        var documents = new java.util.LinkedHashMap<String, byte[]>();
        documents.put("report.pdf", TestContainers.resource("sample_signed.pdf"));
        var source = Files.write(temporaryDirectory.resolve("report.asice"),
                TestContainers.signedXadesContainer(documents)).toRealPath();
        var stdout = new StringWriter();
        var input = "{\"protocolVersion\":1,\"requestId\":\"r\",\"operation\":\"INSPECT\",\"payload\":{"
                + "\"files\":[{\"id\":\"one\",\"source\":\"" + source + "\",\"target\":\""
                + temporaryDirectory.resolve("unused.asice") + "\"}]}}";

        var code = MachineCliApp.start(commandLine("INSPECT"), new StringReader(input), new PrintWriter(stdout),
                new PrintWriter(new StringWriter()));

        assertEquals(0, code, stdout.toString());
        var inspection = java.util.Arrays.stream(stdout.toString().strip().split("\\n"))
                .map(line -> JsonParser.parseString(line).getAsJsonObject())
                .filter(event -> "inspection.completed".equals(event.get("type").getAsString()))
                .findFirst().orElseThrow().getAsJsonObject("payload");
        var nested = inspection.getAsJsonArray("documents").get(0).getAsJsonObject().getAsJsonObject("nested");
        assertEquals("PDF", nested.get("kind").getAsString());
        assertEquals(1, nested.getAsJsonArray("signatures").size());
    }
```

- [ ] **Step 2: Write the v2 VALIDATE test** (in `MachineV2CliAppTest`; it has `temporaryDirectory` and `commandLine()`; trust initialisation is a no-op lambda and the trusted reader validates without lists)

```java
    @Test
    void validateReturnsTheNestedPdfSignatures() throws Exception {
        var documents = new java.util.LinkedHashMap<String, byte[]>();
        documents.put("report.pdf", digital.slovensko.autogram.ui.machine.TestContainers.resource("sample_signed.pdf"));
        var source = Files.write(temporaryDirectory.resolve("report.asice"),
                digital.slovensko.autogram.ui.machine.TestContainers.signedXadesContainer(documents));
        var trusted = MachineInspectionService.forTrustedValidation(validator -> {
            validator.setCertificateVerifier(new eu.europa.esig.dss.spi.validation.CommonCertificateVerifier());
            return validator.validateDocument().getSimpleReport();
        });
        var input = "{\"protocolVersion\":2,\"requestId\":\"validate-tree\",\"operation\":\"VALIDATE\",\"payload\":{\"files\":[{\"id\":\"tree\",\"source\":\""
                + source + "\",\"target\":\"/selected/tree.asice\"}]}}\n";
        var output = new StringWriter();

        var code = MachineV2CliApp.start(commandLine(), new StringReader(input), new PrintWriter(output),
                new PrintWriter(new StringWriter()), new MachineDriverService(), new MachineInspectionService(),
                trusted, () -> { });

        assertEquals(0, code, output.toString());
        var validation = Arrays.stream(output.toString().strip().split("\\n"))
                .map(JsonParser::parseString).map(element -> element.getAsJsonObject())
                .filter(event -> "validation.completed".equals(event.get("type").getAsString()))
                .findFirst().orElseThrow().getAsJsonObject("payload");
        var nested = validation.getAsJsonArray("documents").get(0).getAsJsonObject().getAsJsonObject("nested");
        assertEquals("PDF", nested.get("kind").getAsString());
        assertEquals(1, nested.getAsJsonArray("signatures").size());
    }
```

- [ ] **Step 3: Run both tests**

Run: `cd engine && JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" ./mvnw -q test -Dtest='MachineCliAppTest,MachineV2CliAppTest'`
Expected: PASS (the engine work is done in Tasks 1-2; these pin the protocol).

- [ ] **Step 4: Run the full engine suite and rebuild the engine**

Run: `cd engine && JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" ./mvnw test 2>&1 | grep -E "Tests run: [0-9]+, Failures|BUILD"`
Expected: `BUILD SUCCESS`, 0 failures.
Run: `AUTOGRAM_JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" Chevron7/scripts/build-engine.sh`
Expected: ends with `✔ Engine: …/Chevron7/.build/engine/Contents`.
Run: `Chevron7/scripts/check-rename-boundary.sh`
Expected: `✔ Boundary holds`.

- [ ] **Step 5: Commit**

```bash
git add engine/src/test
git commit -m "test(engine): strom podpisov v odpovedi INSPECT a VALIDATE

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: Swift model, summary and decoder

**Files:**
- Create: `Chevron7/Sources/Chevron7Kit/Signing/SignatureTree.swift`
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/SigningProvider.swift:298-325` (`DocumentSignatureInfo`)
- Create: `Chevron7/Sources/Chevron7Kit/EngineBridge/CLI/SignatureTreeDecoder.swift`
- Test: `Chevron7/Tests/Chevron7KitTests/SignatureTreeTests.swift`

**Interfaces:**
- Produces:
  - `public struct SignatureTree { signatures: [DocumentSignatureInfo]; documents: [SignedDataObject] }`
  - `public struct SignedDataObject: Identifiable { name: String; content: Content }` with `Content` = `.plain`, `.signed(Kind, SignatureTree)`, `.skipped(SkipReason)`, `.failed`; `Kind` = `.pdf`, `.asic`; `SkipReason` = `.depthLimit`, `.tooLarge`
  - `public enum SignatureTreeResult { case tree(SignatureTree); case failed(String) }`
  - `public struct SignatureTreeSummary { valid, invalid, indeterminate: Int; worstLocation: String?; total: Int; overall: DocumentSignatureInfo.State; init(tree:) }`
  - `DocumentSignatureInfo` new fields `coveredDocuments: [String]`, `certificateQualification: String?`, `hasTimestamp: Bool`
  - `enum SignatureTreeDecoder { static func tree(from payload: [String: JSONValue]) -> SignatureTree }`

- [ ] **Step 1: Write the failing tests**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

final class SignatureTreeTests: XCTestCase {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }

    func testDecodesContainerSignaturesAndNestedPdf() throws {
        let tree = SignatureTreeDecoder.tree(from: try payload("""
        {"signatures":[{"id":"S-1","format":"XAdES_BASELINE_T","signerDisplayName":"Marián Čuprík",
          "valid":true,"indication":"TOTAL_PASSED","qualifiedTimestampValid":true,
          "signerCertificateQualification":"QESIG","timestamps":[{"id":"T-1","valid":true}],
          "documents":["report.pdf"]}],
         "documents":[
          {"name":"report.pdf","nested":{"kind":"PDF","signatures":[{"id":"S-1","format":"PAdES_BASELINE_T",
            "signerDisplayName":"Iný Podpisovateľ","valid":false,"indication":"TOTAL_FAILED","timestamps":[]}]}},
          {"name":"dolozka.xml.xdcf"},
          {"name":"deep.asice","nestedSkipped":"DEPTH_LIMIT"},
          {"name":"big.pdf","nestedSkipped":"TOO_LARGE"},
          {"name":"bad.pdf","nestedError":"NESTED_INSPECTION_FAILED"}]}
        """))

        XCTAssertEqual(tree.signatures.count, 1)
        let container = tree.signatures[0]
        XCTAssertEqual(container.state, .valid)
        XCTAssertEqual(container.coveredDocuments, ["report.pdf"])
        XCTAssertEqual(container.certificateQualification, "QESIG")
        XCTAssertTrue(container.hasQualifiedTimestamp)
        XCTAssertEqual(tree.documents.map(\.name), ["report.pdf", "dolozka.xml.xdcf", "deep.asice", "big.pdf", "bad.pdf"])
        guard case .signed(.pdf, let nested) = tree.documents[0].content else {
            return XCTFail("report.pdf should be a signed PDF")
        }
        XCTAssertEqual(nested.signatures.map(\.state), [.invalid])
        XCTAssertEqual(tree.documents[1].content, .plain)
        XCTAssertEqual(tree.documents[2].content, .skipped(.depthLimit))
        XCTAssertEqual(tree.documents[3].content, .skipped(.tooLarge))
        XCTAssertEqual(tree.documents[4].content, .failed)
    }

    func testStructuralTimestampIsNotQualified() throws {
        let tree = SignatureTreeDecoder.tree(from: try payload("""
        {"signatures":[{"id":"S-1","valid":true,"indication":"INDETERMINATE","qualifiedTimestampValid":false,
          "timestamps":[{"id":"T-1","cryptographicIntegrity":true}]}]}
        """))

        XCTAssertEqual(tree.signatures[0].state, .indeterminate)
        XCTAssertFalse(tree.signatures[0].hasQualifiedTimestamp)
        XCTAssertTrue(tree.signatures[0].hasTimestamp)
    }

    func testSameSignatureIdOnTwoLevelsStaysSeparate() throws {
        let tree = SignatureTreeDecoder.tree(from: try payload("""
        {"signatures":[{"id":"S-1","valid":true,"indication":"TOTAL_PASSED","timestamps":[]}],
         "documents":[{"name":"a.pdf","nested":{"kind":"PDF","signatures":[
           {"id":"S-1","valid":false,"indication":"TOTAL_FAILED","timestamps":[]}]}}]}
        """))

        XCTAssertEqual(tree.signatures.map(\.state), [.valid])
        guard case .signed(_, let nested) = tree.documents[0].content else { return XCTFail() }
        XCTAssertEqual(nested.signatures.map(\.state), [.invalid])
        XCTAssertEqual(SignatureTreeSummary(tree: tree).invalid, 1)
        XCTAssertEqual(SignatureTreeSummary(tree: tree).valid, 1)
    }

    func testSummaryTakesTheWorstResultAndItsLocation() {
        let valid = DocumentSignatureInfo(id: "1", signerDisplayName: "A", state: .valid)
        let invalid = DocumentSignatureInfo(id: "2", signerDisplayName: "B", state: .invalid)
        let tree = SignatureTree(signatures: [valid], documents: [
            SignedDataObject(name: "report.pdf", content: .signed(.pdf, SignatureTree(signatures: [invalid]))),
            SignedDataObject(name: "bad.pdf", content: .failed),
            SignedDataObject(name: "deep.asice", content: .skipped(.depthLimit)),
            SignedDataObject(name: "dolozka.xml.xdcf", content: .plain)
        ])

        let summary = SignatureTreeSummary(tree: tree)

        XCTAssertEqual(summary.valid, 1)
        XCTAssertEqual(summary.invalid, 1)
        XCTAssertEqual(summary.indeterminate, 2)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.overall, .invalid)
        XCTAssertEqual(summary.worstLocation, "report.pdf")
    }

    func testSummaryOfAnEmptyTreeIsUnknown() {
        XCTAssertEqual(SignatureTreeSummary(tree: SignatureTree()).overall, .unknown)
        XCTAssertEqual(SignatureTreeSummary(tree: SignatureTree()).total, 0)
    }
}
```

`total` counts signatures only (valid + invalid + indeterminate signatures), while failed or skipped data objects raise `indeterminate` and the overall state but are not signatures. To keep that precise, `SignatureTreeSummary` keeps a separate `unverifiedDocuments` count; see Step 3. In the test above `indeterminate == 2` counts the two unverified data objects, and `total == 2` counts the two signatures.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SignatureTreeTests`
Expected: FAIL to compile (`SignatureTreeDecoder`, `SignatureTree` not defined).

- [ ] **Step 3: Implement the model**

In `SigningProvider.swift`, extend `DocumentSignatureInfo`:

```swift
public struct DocumentSignatureInfo: Sendable, Identifiable, Equatable {
    public var id: String
    public var signerDisplayName: String
    public var format: String?
    public var signingTime: Date?
    /// True only when full validation confirmed a qualified timestamp.
    public var hasQualifiedTimestamp: Bool
    /// A timestamp is present and cryptographically intact (structural knowledge only).
    public var hasTimestamp: Bool
    public var state: State
    public var detail: String?
    /// Names of the container's data objects this signature covers.
    public var coveredDocuments: [String]
    /// DSS SignatureQualification name from full validation, e.g. "QESIG".
    public var certificateQualification: String?

    public enum State: String, Sendable, Equatable {
        case valid
        case invalid
        case indeterminate
        case unknown
    }

    public init(id: String, signerDisplayName: String, format: String? = nil,
                signingTime: Date? = nil, hasQualifiedTimestamp: Bool = false,
                hasTimestamp: Bool = false, state: State = .unknown, detail: String? = nil,
                coveredDocuments: [String] = [], certificateQualification: String? = nil) {
        self.id = id
        self.signerDisplayName = signerDisplayName
        self.format = format
        self.signingTime = signingTime
        self.hasQualifiedTimestamp = hasQualifiedTimestamp
        self.hasTimestamp = hasTimestamp || hasQualifiedTimestamp
        self.state = state
        self.detail = detail
        self.coveredDocuments = coveredDocuments
        self.certificateQualification = certificateQualification
    }
}
```

Create `Signing/SignatureTree.swift`:

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// One level of a document's signatures: its own signatures and, for an ASiC container,
/// its data objects, some of which carry signatures of their own.
public struct SignatureTree: Sendable, Equatable {
    public var signatures: [DocumentSignatureInfo]
    public var documents: [SignedDataObject]

    public init(signatures: [DocumentSignatureInfo] = [], documents: [SignedDataObject] = []) {
        self.signatures = signatures
        self.documents = documents
    }

    public var isContainer: Bool { !documents.isEmpty }
}

public struct SignedDataObject: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case pdf = "PDF"
        case asic = "ASIC"
    }

    public enum SkipReason: String, Sendable, Equatable {
        case depthLimit = "DEPTH_LIMIT"
        case tooLarge = "TOO_LARGE"
    }

    public enum Content: Sendable, Equatable {
        /// No signatures of its own (XML, XDCF, text, images).
        case plain
        case signed(Kind, SignatureTree)
        case skipped(SkipReason)
        case failed
    }

    public var name: String
    public var content: Content
    public var id: String { name }

    public init(name: String, content: Content) {
        self.name = name
        self.content = content
    }
}

public enum SignatureTreeResult: Sendable, Equatable {
    case tree(SignatureTree)
    case failed(String)
}

/// Worst-of summary over the whole tree. Indeterminate and unknown count together and
/// never as valid; a data object that could not be verified counts as indeterminate.
public struct SignatureTreeSummary: Sendable, Equatable {
    public private(set) var valid = 0
    public private(set) var invalid = 0
    public private(set) var indeterminateSignatures = 0
    public private(set) var unverifiedDocuments = 0
    /// Name of the top-level data object holding the worst result; nil for the top level.
    public private(set) var worstLocation: String?

    public var indeterminate: Int { indeterminateSignatures + unverifiedDocuments }
    public var total: Int { valid + invalid + indeterminateSignatures }

    public var overall: DocumentSignatureInfo.State {
        if invalid > 0 { return .invalid }
        if indeterminate > 0 { return .indeterminate }
        return valid > 0 ? .valid : .unknown
    }

    public init(tree: SignatureTree) {
        var firstInvalid: String??
        var firstIndeterminate: String??
        add(tree, location: nil, firstInvalid: &firstInvalid, firstIndeterminate: &firstIndeterminate)
        worstLocation = (firstInvalid ?? firstIndeterminate) ?? nil
    }

    private mutating func add(_ tree: SignatureTree, location: String?,
                              firstInvalid: inout String??, firstIndeterminate: inout String??) {
        for signature in tree.signatures {
            switch signature.state {
            case .valid:
                valid += 1
            case .invalid:
                invalid += 1
                if firstInvalid == nil { firstInvalid = .some(location) }
            case .indeterminate, .unknown:
                indeterminateSignatures += 1
                if firstIndeterminate == nil { firstIndeterminate = .some(location) }
            }
        }
        for document in tree.documents {
            let childLocation = location ?? document.name
            switch document.content {
            case .plain:
                break
            case .signed(_, let nested):
                add(nested, location: childLocation, firstInvalid: &firstInvalid,
                    firstIndeterminate: &firstIndeterminate)
            case .skipped, .failed:
                unverifiedDocuments += 1
                if firstIndeterminate == nil { firstIndeterminate = .some(childLocation) }
            }
        }
    }
}
```

The test in Step 1 uses `summary.indeterminate == 2` (two unverified data objects, no indeterminate signature) and `summary.total == 2`.

Create `EngineBridge/CLI/SignatureTreeDecoder.swift`:

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Decodes the engine's inspection or validation payload (machine protocol v1 INSPECT,
/// v2 VALIDATE) into a `SignatureTree`. Both share one shape; only the states differ.
enum SignatureTreeDecoder {
    static func tree(from payload: [String: JSONValue]) -> SignatureTree {
        SignatureTree(
            signatures: array(payload["signatures"]).compactMap(signature(from:)),
            documents: array(payload["documents"]).compactMap(dataObject(from:)))
    }

    static func signature(from value: JSONValue) -> DocumentSignatureInfo? {
        guard case .object(let object) = value, let id = string(object["id"]) else { return nil }
        let indication = string(object["indication"])
        let state: DocumentSignatureInfo.State
        if indication?.uppercased().contains("INDETERMINATE") == true {
            state = .indeterminate
        } else if bool(object["valid"]) == true {
            state = .valid
        } else {
            state = .invalid
        }
        let timestamps = array(object["timestamps"])
        let intactTimestamp = timestamps.contains { timestamp in
            guard case .object(let fields) = timestamp else { return false }
            return bool(fields["cryptographicIntegrity"]) == true || bool(fields["valid"]) == true
        }
        return DocumentSignatureInfo(
            id: id,
            signerDisplayName: string(object["signerDisplayName"]) ?? "Neznámy podpisovateľ",
            format: string(object["format"]),
            signingTime: string(object["signingTime"]).flatMap { ISO8601DateFormatter().date(from: $0) },
            hasQualifiedTimestamp: bool(object["qualifiedTimestampValid"]) == true,
            hasTimestamp: intactTimestamp,
            state: state,
            detail: string(object["validationReason"]) ?? string(object["subIndication"]),
            coveredDocuments: array(object["documents"]).compactMap(string),
            certificateQualification: string(object["signerCertificateQualification"]))
    }

    private static func dataObject(from value: JSONValue) -> SignedDataObject? {
        guard case .object(let object) = value, let name = string(object["name"]) else { return nil }
        if case .object(let nested)? = object["nested"] {
            let kind = SignedDataObject.Kind(rawValue: string(nested["kind"]) ?? "") ?? .pdf
            return SignedDataObject(name: name, content: .signed(kind, tree(from: nested)))
        }
        if let reason = string(object["nestedSkipped"]).flatMap(SignedDataObject.SkipReason.init(rawValue:)) {
            return SignedDataObject(name: name, content: .skipped(reason))
        }
        if string(object["nestedError"]) != nil {
            return SignedDataObject(name: name, content: .failed)
        }
        return SignedDataObject(name: name, content: .plain)
    }

    private static func array(_ value: JSONValue?) -> [JSONValue] {
        guard case .array(let values)? = value else { return [] }
        return values
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }
}
```

An unknown `nestedSkipped` value falls through to `nestedError` and then `.plain`; to keep a future reason visible, decode an unknown skip value as `.failed` instead: change the `nestedSkipped` branch to

```swift
        if let skipped = string(object["nestedSkipped"]) {
            if let reason = SignedDataObject.SkipReason(rawValue: skipped) {
                return SignedDataObject(name: name, content: .skipped(reason))
            }
            return SignedDataObject(name: name, content: .failed)
        }
```

- [ ] **Step 4: Run the tests**

Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SignatureTreeTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7Kit/Signing/SignatureTree.swift Chevron7/Sources/Chevron7Kit/Signing/SigningProvider.swift Chevron7/Sources/Chevron7Kit/EngineBridge/CLI/SignatureTreeDecoder.swift Chevron7/Tests/Chevron7KitTests/SignatureTreeTests.swift
git commit -m "feat(signing): model stromu podpisov, suhrn a dekoder

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: Engine bridge and provider

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/EngineBridge/Models/InspectionModels.swift:27-39` (`InspectedPDF.tree`)
- Modify: `Chevron7/Sources/Chevron7Kit/EngineBridge/CLI/AutogramCLIEngine.swift:114-136, 170-192, 647-676`
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/SigningProvider.swift` (protocol `QualifiedSigningProviding` and its extension)
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/JavaEngine/EngineBridgeSigningProvider.swift` (after `inspectSignatures`, around `:179`)
- Test: `Chevron7/Tests/Chevron7KitTests/SignatureTreeProviderTests.swift`

**Interfaces:**
- Consumes: `SignatureTree`, `SignatureTreeResult`, `SignatureTreeDecoder` (Task 4).
- Produces: `QualifiedSigningProviding.inspectSignatureTree(in: URL) async -> SignatureTreeResult`, `QualifiedSigningProviding.validateSignatureTree(in: URL) async -> SignatureTreeResult`; `InspectedPDF.tree: SignatureTree`.

- [ ] **Step 1: Write the failing tests**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

final class SignatureTreeProviderTests: XCTestCase {
    private func sourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-\(UUID().uuidString).asice")
        try Data("PK\u{3}\u{4}".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let tree = SignatureTree(
        signatures: [DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .valid)],
        documents: [SignedDataObject(name: "report.pdf", content: .plain)])

    func testInspectAndValidateReturnTheEngineTree() async throws {
        let engine = TreeEngine(inspectTree: tree, validateTree: tree)
        let provider = EngineBridgeSigningProvider(engine: engine)
        let url = try sourceFile()

        let inspected = await provider.inspectSignatureTree(in: url)
        let validated = await provider.validateSignatureTree(in: url)

        XCTAssertEqual(inspected, .tree(tree))
        XCTAssertEqual(validated, .tree(tree))
    }

    func testValidationFailureIsReportedNotEmpty() async throws {
        let engine = TreeEngine(inspectTree: tree, validateError: SigningFailure.engine("TRUSTED_LIST_UNAVAILABLE"))
        let provider = EngineBridgeSigningProvider(engine: engine)

        let validated = await provider.validateSignatureTree(in: try sourceFile())

        guard case .failed(let reason) = validated else { return XCTFail("expected failure") }
        XCTAssertEqual(reason, "Dôveryhodné zoznamy nie sú dostupné. Výsledok je len štrukturálny.")
    }

    func testMissingFileFails() async {
        let provider = EngineBridgeSigningProvider(engine: TreeEngine(inspectTree: tree))
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf")

        let result = await provider.inspectSignatureTree(in: missing)

        guard case .failed = result else { return XCTFail("expected failure") }
    }

    func testDefaultProviderHasNoFullValidation() async throws {
        let result = await DemoSigningProvider().validateSignatureTree(in: try sourceFile())

        XCTAssertEqual(result, .failed("Plné overenie vyžaduje podpisový engine."))
    }
}

private final class TreeEngine: SigningEngine, @unchecked Sendable {
    let inspectTree: SignatureTree
    let validateTree: SignatureTree?
    let validateError: Error?

    init(inspectTree: SignatureTree, validateTree: SignatureTree? = nil, validateError: Error? = nil) {
        self.inspectTree = inspectTree
        self.validateTree = validateTree
        self.validateError = validateError
    }

    func capabilities() async throws -> EngineCapabilities { throw SigningFailure.engine("unused") }
    func drivers() async throws -> [SigningDriver] { [] }
    func certificates(driverID: String, pin: Secret?) async throws -> [SigningCertificate] { [] }
    func certificateDiscovery(driverID: String, pin: Secret?) async throws -> CertificateDiscovery {
        throw SigningFailure.engine("unused")
    }
    func inspect(files: [PDFItemDescriptor]) async throws -> [PDFInspection] {
        [PDFInspection(files: files.map { InspectedPDF(id: $0.id, isSignable: true, tree: inspectTree) })]
    }
    func validate(files: [PDFItemDescriptor]) async throws -> [PDFInspection] {
        if let validateError { throw validateError }
        return [PDFInspection(files: files.map { InspectedPDF(id: $0.id, isSignable: true, tree: validateTree!) })]
    }
    func sign(request: EngineSigningRequest) -> AsyncThrowingStream<SigningEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: SigningFailure.engine("unused")) }
    }
    func cancel() async {}
}
```

If `DemoSigningProvider()` needs arguments, construct it the way `Chevron7/Tests/Chevron7AppTests` does (`grep -rn "DemoSigningProvider(" Chevron7/Tests`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SignatureTreeProviderTests`
Expected: FAIL to compile (`inspectSignatureTree`, `InspectedPDF(tree:)` missing).

- [ ] **Step 3: Implement**

`InspectionModels.swift`, `InspectedPDF`:

```swift
struct InspectedPDF: Sendable, Equatable, Identifiable {
    let id: String
    let isSignable: Bool
    let signatures: [ExistingPDFSignature]
    let documents: [String]
    /// The whole signature tree, including signatures inside embedded documents.
    let tree: SignatureTree

    init(id: String, isSignable: Bool, signatures: [ExistingPDFSignature] = [], documents: [String] = [],
         tree: SignatureTree = SignatureTree()) {
        self.id = id
        self.isSignable = isSignable
        self.signatures = signatures
        self.documents = documents
        self.tree = tree
    }
}
```

`AutogramCLIEngine.swift`: in both `inspect(files:)` and `validate(files:)`, pass the tree:

```swift
            return InspectedPDF(
                id: file.id,
                isSignable: true,
                signatures: signatures(in: event.payload["signatures"]),
                documents: documents(in: event.payload["documents"]),
                tree: SignatureTreeDecoder.tree(from: event.payload)
            )
```

and in `signatures(in:)` make `hasQualifiedTimestamp` come only from the engine's verdict:

```swift
                hasQualifiedTimestamp: bool(in: signature["qualifiedTimestampValid"]) == true,
```

`SigningProvider.swift`, add to the protocol `QualifiedSigningProviding` (requirements, so calls through `any QualifiedSigningProviding` dispatch dynamically):

```swift
    /// Structural signature tree of the file: fast, no trusted lists.
    func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult
    /// The same tree validated against the EU trusted lists (informative validation).
    func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult
```

and to its extension:

```swift
    public func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        let result = await inspectInputSignatures(in: fileURL)
        if result.state == .unavailable {
            return .failed(result.detail)
        }
        return .tree(SignatureTree(signatures: result.signatures))
    }

    public func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        .failed("Plné overenie vyžaduje podpisový engine.")
    }
```

`EngineBridgeSigningProvider.swift`, after `inspectSignatures(in:)`:

```swift
    public func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        await signatureTree(in: fileURL) { [engine] files in try await engine.inspect(files: files) }
    }

    public func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        await signatureTree(in: fileURL) { [engine] files in try await engine.validate(files: files) }
    }

    private func signatureTree(
        in fileURL: URL,
        run: @Sendable ([PDFItemDescriptor]) async throws -> [PDFInspection]
    ) async -> SignatureTreeResult {
        let canonical = EnginePaths.canonical(fileURL)
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            return .failed("Dokument nie je dostupný.")
        }
        do {
            let inspections = try await run([PDFItemDescriptor(id: "tree", sourceURL: canonical)])
            guard let inspected = inspections.flatMap(\.files).first(where: { $0.id == "tree" }),
                  inspected.isSignable else {
                return .failed("Engine nevrátil výsledok kontroly podpisov.")
            }
            return .tree(inspected.tree)
        } catch {
            logger.info("Signature tree failed: \(error.localizedDescription, privacy: .public)")
            return .failed(Self.treeFailureReason(error))
        }
    }

    static func treeFailureReason(_ error: Error) -> String {
        let text = "\(error) \(error.localizedDescription)"
        if text.contains("TRUSTED_LIST_UNAVAILABLE") {
            return "Dôveryhodné zoznamy nie sú dostupné. Výsledok je len štrukturálny."
        }
        if text.contains("VALIDATION_FAILED") {
            return "Overenie podpisov zlyhalo. Výsledok je len štrukturálny."
        }
        return error.localizedDescription
    }
```

- [ ] **Step 4: Run the tests**

Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter 'SignatureTreeProviderTests|SignatureTreeTests|InputSignatureVerificationTests|EngineBridge'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7Kit Chevron7/Tests/Chevron7KitTests/SignatureTreeProviderTests.swift
git commit -m "feat(signing): strom podpisov z enginu cez INSPECT a VALIDATE

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: Store state, background validation and revalidation

**Files:**
- Create: `Chevron7/Sources/Chevron7App/SignatureTreeState.swift`
- Modify: `Chevron7/Sources/Chevron7App/SigningSessionStore.swift` (lines 51-62 state, 303, 327, 356-364, 724, 1756-1758)
- Test: `Chevron7/Tests/Chevron7AppTests/SignatureTreeStoreTests.swift`

**Interfaces:**
- Consumes: `SignatureTree`, `SignatureTreeResult`, provider methods (Task 5).
- Produces:
  - `struct SignatureTreeState: Equatable { var tree: SignatureTree; var phase: Phase }`, `enum Phase { case idle, inspecting, structural, validated, validationUnavailable(String), failed(String) }`, `var isValidating: Bool`
  - `SigningSessionStore.existingSignatureState`, `.resultSignatureState` (`SignatureTreeState`), computed `existingSignatures` / `resultSignatures` (top-level `[DocumentSignatureInfo]`), computed `isInspectingSignatures`
  - `SigningSessionStore.existingValidationTask`, `.resultValidationTask` (`Task<Void, Never>?`, for tests)
  - `func revalidateExistingSignatures() async`, `func revalidateResultSignatures() async`

- [ ] **Step 1: Write the failing tests**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit
import Chevron7TestSupport

@MainActor
final class SignatureTreeStoreTests: XCTestCase {
    private func makeStore(_ provider: TreeProvider) -> SigningSessionStore {
        let settings = makeSettingsStore()
        let recent = RecentDocumentStore(settingsStore: settings, defaults: MemoryUserDefaults())
        return SigningSessionStore(signingProvider: provider, settingsStore: settings, recentDocumentStore: recent)
    }

    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString).pdf")
        try Data("%PDF-1.7\n%%EOF".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static let structural = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .indeterminate)])
    private static let validated = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .valid)])

    func testStructuralThenValidated() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let store = makeStore(provider)
        store.sourceURL = try file()

        await store.inspectExistingSignatures()
        XCTAssertEqual(store.existingSignatureState.phase, .structural)
        XCTAssertEqual(store.existingSignatureState.tree, Self.structural)

        await provider.releaseValidation()
        await store.existingValidationTask?.value
        XCTAssertEqual(store.existingSignatureState.phase, .validated)
        XCTAssertEqual(store.existingSignatures.map(\.state), [.valid])
    }

    func testValidationUnavailableKeepsStructuralTree() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .failed("offline"))
        let store = makeStore(provider)
        store.sourceURL = try file()

        await store.inspectExistingSignatures()
        await provider.releaseValidation()
        await store.existingValidationTask?.value

        XCTAssertEqual(store.existingSignatureState.phase, .validationUnavailable("offline"))
        XCTAssertEqual(store.existingSignatureState.tree, Self.structural)
    }

    func testFailedInspectionIsNotEmpty() async throws {
        let provider = TreeProvider(inspect: .failed("broken"), validate: .tree(Self.validated))
        let store = makeStore(provider)
        store.sourceURL = try file()

        await store.inspectExistingSignatures()

        XCTAssertEqual(store.existingSignatureState.phase, .failed("broken"))
        XCTAssertNil(store.existingValidationTask)
    }

    func testStaleValidationIsDropped() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let store = makeStore(provider)
        store.sourceURL = try file()
        await store.inspectExistingSignatures()
        let stale = store.existingValidationTask

        provider.inspectResult = .tree(SignatureTree())
        store.sourceURL = try file()
        await store.inspectExistingSignatures()
        await provider.releaseValidation()
        await stale?.value
        await store.existingValidationTask?.value

        XCTAssertEqual(provider.validateCalls, 2)
        XCTAssertEqual(store.existingSignatureState.tree, Self.validated)
        XCTAssertEqual(store.existingSignatureState.phase, .validated)
    }

    func testRevalidateRunsValidationAgain() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .failed("offline"))
        let store = makeStore(provider)
        store.sourceURL = try file()
        await store.inspectExistingSignatures()
        await provider.releaseValidation()
        await store.existingValidationTask?.value

        provider.validateResult = .tree(Self.validated)
        let revalidation = Task { await store.revalidateExistingSignatures() }
        await provider.releaseValidation()
        await revalidation.value

        XCTAssertEqual(provider.validateCalls, 2)
        XCTAssertEqual(store.existingSignatureState.phase, .validated)
    }
}

/// Validation waits until the test releases it, so phases can be observed in order.
private final class TreeProvider: QualifiedSigningProviding, @unchecked Sendable {
    var inspectResult: SignatureTreeResult
    var validateResult: SignatureTreeResult
    private(set) var validateCalls = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var credits = 0

    init(inspect: SignatureTreeResult, validate: SignatureTreeResult) {
        inspectResult = inspect
        validateResult = validate
    }

    /// Lets up to two validations finish (waiting ones first, later ones on arrival).
    /// A continuation list instead of an AsyncStream: two validations may wait at once.
    func releaseValidation() async {
        credits += 2
        while credits > 0, !waiting.isEmpty {
            credits -= 1
            waiting.removeFirst().resume()
        }
        for _ in 0..<5 { await Task.yield() }
    }

    func availableIdentities() async -> [SigningIdentityInfo] { [] }
    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.identityUnavailable
    }
    func inspectInputSignatures(in fileURLs: [URL]) async -> [URL: InputSignatureInspectionResult] { [:] }
    func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult { inspectResult }
    func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        validateCalls += 1
        if credits > 0 {
            credits -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        return validateResult
    }
}
```

Adjust `TreeProvider` to the exact requirements of `QualifiedSigningProviding` (copy the stub shape from `Chevron7/Tests/Chevron7AppTests/ZakoMobileAvailabilityTests.swift:80`, `StubSigningProvider`), and the error thrown by `sign` to any error type available in the app target.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SignatureTreeStoreTests`
Expected: FAIL to compile (`existingSignatureState` missing).

- [ ] **Step 3: Implement**

Create `SignatureTreeState.swift`:

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit

/// What the signing screens know about a file's signatures right now.
struct SignatureTreeState: Equatable {
    enum Phase: Equatable {
        case idle
        /// Structural inspection is running; nothing to show yet.
        case inspecting
        /// The structural tree is shown; full validation is running.
        case structural
        /// The tree was validated against the EU trusted lists.
        case validated
        /// Full validation failed; the structural tree stays.
        case validationUnavailable(String)
        /// Even structural inspection failed. Never shown as "no signature".
        case failed(String)
    }

    var tree = SignatureTree()
    var phase: Phase = .idle

    var isValidating: Bool { phase == .structural }
}
```

In `SigningSessionStore.swift` replace the stored properties (around lines 51 and 62):

```swift
    var existingSignatureState = SignatureTreeState()
    var resultSignatureState = SignatureTreeState()
    /// Top-level signatures, for callers that predate the tree.
    var existingSignatures: [DocumentSignatureInfo] { existingSignatureState.tree.signatures }
    var resultSignatures: [DocumentSignatureInfo] { resultSignatureState.tree.signatures }
    var isInspectingSignatures: Bool { existingSignatureState.phase == .inspecting }
    private(set) var existingValidationTask: Task<Void, Never>?
    private(set) var resultValidationTask: Task<Void, Never>?
    private var existingTreeRun = UUID()
    private var resultTreeRun = UUID()
```

Remove the old `var isInspectingSignatures = false`, `var existingSignatures: [DocumentSignatureInfo] = []` and `var resultSignatures: [DocumentSignatureInfo] = []`.

Replace `inspectExistingSignatures()` and add the shared runner and revalidation:

```swift
    func inspectExistingSignatures() async {
        guard let sourceURL else {
            existingTreeRun = UUID()
            existingSignatureState = SignatureTreeState()
            return
        }
        await runSignatureTree(for: sourceURL, result: false)
    }

    func revalidateExistingSignatures() async {
        guard let sourceURL, existingSignatureState.phase != .inspecting else { return }
        await revalidate(url: sourceURL, result: false)
    }

    func revalidateResultSignatures() async {
        guard let signedOutputURL, resultSignatureState.phase != .inspecting else { return }
        await revalidate(url: signedOutputURL, result: true)
    }

    /// Structural tree first (awaited), then full validation in the background, so signing
    /// and document switches never wait for the trusted lists. A run token drops results
    /// that arrive after the user moved to another document.
    private func runSignatureTree(for url: URL, result: Bool) async {
        let run = UUID()
        setTreeRun(run, result: result)
        setTreeState(SignatureTreeState(tree: SignatureTree(), phase: .inspecting), result: result)
        let inspected = await signingProvider.inspectSignatureTree(in: url)
        guard treeRun(result: result) == run else { return }
        switch inspected {
        case .failed(let reason):
            setTreeState(SignatureTreeState(tree: SignatureTree(), phase: .failed(reason)), result: result)
            setValidationTask(nil, result: result)
        case .tree(let tree):
            setTreeState(SignatureTreeState(tree: tree, phase: .structural), result: result)
            let task = Task { [weak self] in await self?.validate(url: url, run: run, result: result) }
            setValidationTask(task, result: result)
        }
    }

    private func revalidate(url: URL, result: Bool) async {
        let run = UUID()
        setTreeRun(run, result: result)
        var state = treeState(result: result)
        state.phase = .structural
        setTreeState(state, result: result)
        let task = Task { [weak self] in await self?.validate(url: url, run: run, result: result) }
        setValidationTask(task, result: result)
        await task.value
    }

    private func validate(url: URL, run: UUID, result: Bool) async {
        let validated = await signingProvider.validateSignatureTree(in: url)
        guard treeRun(result: result) == run else { return }
        switch validated {
        case .tree(let tree):
            setTreeState(SignatureTreeState(tree: tree, phase: .validated), result: result)
        case .failed(let reason):
            var state = treeState(result: result)
            state.phase = .validationUnavailable(reason)
            setTreeState(state, result: result)
        }
    }

    private func treeRun(result: Bool) -> UUID { result ? resultTreeRun : existingTreeRun }
    private func setTreeRun(_ run: UUID, result: Bool) {
        if result { resultTreeRun = run } else { existingTreeRun = run }
    }
    private func treeState(result: Bool) -> SignatureTreeState {
        result ? resultSignatureState : existingSignatureState
    }
    private func setTreeState(_ state: SignatureTreeState, result: Bool) {
        if result { resultSignatureState = state } else { existingSignatureState = state }
    }
    private func setValidationTask(_ task: Task<Void, Never>?, result: Bool) {
        if result { resultValidationTask = task } else { existingValidationTask = task }
    }

    private func resetSignatureTrees() {
        existingTreeRun = UUID()
        resultTreeRun = UUID()
        existingSignatureState = SignatureTreeState()
        resultSignatureState = SignatureTreeState()
        existingValidationTask = nil
        resultValidationTask = nil
    }
```

Update the other assignments:
- `selectQueueItem` (line ~303) `resultSignatures = []` becomes `resultTreeRun = UUID(); resultSignatureState = SignatureTreeState()`.
- line ~327 `resultSignatures = await signingProvider.inspectSignatures(in: signed)` becomes `await runSignatureTree(for: signed, result: true)`.
- line ~724 `resultSignatures = await signingProvider.inspectSignatures(in: signedURL)` becomes `await runSignatureTree(for: signedURL, result: true)`.
- the reset around lines 1756-1758 (`existingSignatures = []` and `resultSignatures = []`) becomes one call `resetSignatureTrees()`.

Run `grep -n "existingSignatures =\|resultSignatures =\|isInspectingSignatures =" Chevron7/Sources/Chevron7App/SigningSessionStore.swift` afterwards; it must print nothing.

- [ ] **Step 4: Run the tests**

Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter 'SignatureTreeStoreTests|SigningBatchTests|RecentDocumentStoreTests|SmartcardBadgeTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/SignatureTreeState.swift Chevron7/Sources/Chevron7App/SigningSessionStore.swift Chevron7/Tests/Chevron7AppTests/SignatureTreeStoreTests.swift
git commit -m "feat(signing): stav stromu podpisov, overenie na pozadi a Overit znova

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 7: Tree view, texts and integration

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/SignatureTreeView.swift`
- Modify: `Chevron7/Sources/Chevron7App/Views/SigningFlowViews.swift` (`existingSignaturesSection` 513-531, `signatureSectionTitle` 533-535, `SignatureInfoRow` 845-910, "Overenie podpisov v súbore" 1042-1053)
- Test: `Chevron7/Tests/Chevron7AppTests/SignatureTreePresentationTests.swift`

**Interfaces:**
- Consumes: `SignatureTreeState`, `SignatureTreeSummary`, store methods from Task 6.
- Produces: `enum SignatureTreePresentation { static func summaryText(_:) -> String; static func phaseText(_:) -> String?; static func signatureCount(_:) -> String; static let officialValidationURL: URL }`, `struct SignatureTreeView: View`.

- [ ] **Step 1: Write the failing tests**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App
import Chevron7Kit

final class SignatureTreePresentationTests: XCTestCase {
    private func signature(_ state: DocumentSignatureInfo.State) -> DocumentSignatureInfo {
        DocumentSignatureInfo(id: UUID().uuidString, signerDisplayName: "A", state: state)
    }

    func testSignatureCountUsesSlovakPlurals() {
        XCTAssertEqual(SignatureTreePresentation.signatureCount(1), "1 podpis")
        XCTAssertEqual(SignatureTreePresentation.signatureCount(3), "3 podpisy")
        XCTAssertEqual(SignatureTreePresentation.signatureCount(5), "5 podpisov")
    }

    func testSummaryNamesTheWorstLocation() {
        let tree = SignatureTree(signatures: [signature(.valid)], documents: [
            SignedDataObject(name: "report.pdf", content: .signed(.pdf, SignatureTree(signatures: [signature(.invalid)])))
        ])

        XCTAssertEqual(SignatureTreePresentation.summaryText(SignatureTreeSummary(tree: tree)),
                       "2 podpisy: platné 1, neplatné 1 (v report.pdf)")
    }

    func testSummaryMentionsUnverifiedDocuments() {
        let tree = SignatureTree(signatures: [signature(.valid)], documents: [
            SignedDataObject(name: "deep.asice", content: .skipped(.depthLimit))
        ])

        XCTAssertEqual(SignatureTreePresentation.summaryText(SignatureTreeSummary(tree: tree)),
                       "1 podpis: platné 1, neoverené súbory 1 (v deep.asice)")
    }

    func testPhaseTexts() {
        XCTAssertEqual(SignatureTreePresentation.phaseText(.structural),
                       "Overuje sa voči dôveryhodným zoznamom…")
        XCTAssertEqual(SignatureTreePresentation.phaseText(.validated),
                       "Informatívne overenie voči dôveryhodným zoznamom EÚ")
        XCTAssertEqual(SignatureTreePresentation.phaseText(.validationUnavailable("offline")), "offline")
        XCTAssertNil(SignatureTreePresentation.phaseText(.idle))
    }

    func testFailedPhaseText() {
        XCTAssertEqual(SignatureTreePresentation.phaseText(.failed("x")), "Podpisy sa nepodarilo skontrolovať")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter SignatureTreePresentationTests`
Expected: FAIL to compile (`SignatureTreePresentation` missing).

- [ ] **Step 3: Implement the view and texts**

Create `Views/SignatureTreeView.swift`:

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

enum SignatureTreePresentation {
    static let officialValidationURL = URL(string: "https://www.slovensko.sk/sk/e-sluzby/sluzba-overenia-zep")!

    static func signatureCount(_ count: Int) -> String {
        switch count {
        case 1: "1 podpis"
        case 2...4: "\(count) podpisy"
        default: "\(count) podpisov"
        }
    }

    static func summaryText(_ summary: SignatureTreeSummary) -> String {
        var parts: [String] = []
        if summary.valid > 0 { parts.append("platné \(summary.valid)") }
        if summary.invalid > 0 { parts.append("neplatné \(summary.invalid)") }
        if summary.indeterminateSignatures > 0 { parts.append("neurčité \(summary.indeterminateSignatures)") }
        if summary.unverifiedDocuments > 0 { parts.append("neoverené súbory \(summary.unverifiedDocuments)") }
        var text = signatureCount(summary.total) + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", "))
        if summary.overall != .valid, let location = summary.worstLocation {
            text += " (v \(location))"
        }
        return text
    }

    static func phaseText(_ phase: SignatureTreeState.Phase) -> String? {
        switch phase {
        case .idle: nil
        case .inspecting: "Kontrolujem podpisy…"
        case .structural: "Overuje sa voči dôveryhodným zoznamom…"
        case .validated: "Informatívne overenie voči dôveryhodným zoznamom EÚ"
        case .validationUnavailable(let reason): reason
        case .failed: "Podpisy sa nepodarilo skontrolovať"
        }
    }

    static func tint(_ state: DocumentSignatureInfo.State) -> Color {
        switch state {
        case .valid: .green
        case .invalid: .red
        case .indeterminate, .unknown: .orange
        }
    }

    static func icon(_ state: DocumentSignatureInfo.State) -> String {
        switch state {
        case .valid: "checkmark.seal.fill"
        case .invalid: "xmark.seal.fill"
        case .indeterminate, .unknown: "questionmark.seal.fill"
        }
    }
}

/// Signatures of a file grouped by where they sit: the container's own signatures, then
/// each data object that carries signatures of its own.
struct SignatureTreeView: View {
    let state: SignatureTreeState
    let emptyText: String
    let onRevalidate: () -> Void
    @Environment(\.openURL) private var openURL

    private var summary: SignatureTreeSummary { SignatureTreeSummary(tree: state.tree) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.phase {
            case .idle:
                EmptyView()
            case .inspecting:
                ProgressView("Kontrolujem podpisy…").font(.caption)
            case .failed(let reason):
                Label("Podpisy sa nepodarilo skontrolovať", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(reason).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .structural, .validated, .validationUnavailable:
                if summary.total == 0 && summary.unverifiedDocuments == 0 {
                    Text(emptyText).font(.caption).foregroundStyle(.secondary)
                } else {
                    header
                    treeContent
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.total > 1 || state.tree.isContainer {
                Label(SignatureTreePresentation.summaryText(summary),
                      systemImage: SignatureTreePresentation.icon(summary.overall))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SignatureTreePresentation.tint(summary.overall))
            }
            HStack(spacing: 6) {
                if state.isValidating {
                    ProgressView().controlSize(.mini)
                }
                if let text = SignatureTreePresentation.phaseText(state.phase) {
                    Text(text).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Overiť znova", action: onRevalidate)
                    .font(.caption2)
                    .buttonStyle(.link)
                    .disabled(state.isValidating)
            }
        }
    }

    @ViewBuilder
    private var treeContent: some View {
        if state.tree.isContainer {
            if !state.tree.signatures.isEmpty {
                Text("Podpisy kontajnera").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(state.tree.signatures) { SignatureInfoRow(info: $0) }
            }
            ForEach(signedDocuments) { document in
                DataObjectGroup(document: document)
            }
            if !otherDocumentNames.isEmpty {
                Text("Ďalšie súbory v kontajneri: " + otherDocumentNames.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ForEach(state.tree.signatures) { SignatureInfoRow(info: $0) }
        }
        Button("Overiť aj na slovensko.sk") { openURL(SignatureTreePresentation.officialValidationURL) }
            .font(.caption2)
            .buttonStyle(.link)
            .help("Otvorí informatívne overenie podpisov na slovensko.sk. Súbor tam nahráte sami.")
    }

    /// Data objects shown as their own group: signed ones, and ones that could not be verified.
    private var signedDocuments: [SignedDataObject] {
        state.tree.documents.filter { document in
            switch document.content {
            case .signed(_, let tree): !tree.signatures.isEmpty || tree.isContainer
            case .skipped, .failed: true
            case .plain: false
            }
        }
    }

    private var otherDocumentNames: [String] {
        let shown = Set(signedDocuments.map(\.name))
        return state.tree.documents.map(\.name).filter { !shown.contains($0) }
    }
}

private struct DataObjectGroup: View {
    let document: SignedDataObject
    @State private var isExpanded: Bool

    init(document: SignedDataObject) {
        self.document = document
        let needsAttention: Bool
        switch document.content {
        case .signed(_, let tree): needsAttention = SignatureTreeSummary(tree: tree).overall != .valid
        case .skipped, .failed: needsAttention = true
        case .plain: needsAttention = false
        }
        _isExpanded = State(initialValue: needsAttention)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                switch document.content {
                case .signed(_, let tree):
                    ForEach(tree.signatures) { SignatureInfoRow(info: $0) }
                    if tree.isContainer {
                        let names = tree.documents.map(\.name).joined(separator: ", ")
                        Text("Obsahuje: " + names).font(.caption2).foregroundStyle(.secondary)
                        if tree.documents.contains(where: { if case .skipped(.depthLimit) = $0.content { true } else { false } }) {
                            Text("Podpisy v ďalšom vnorení sa neoverovali.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                case .skipped(.depthLimit):
                    Text("Podpisy v tomto súbore sa neoverovali (ďalšie vnorenie).")
                        .font(.caption2).foregroundStyle(.orange)
                case .skipped(.tooLarge):
                    Text("Podpisy v tomto súbore sa neoverovali (súbor je príliš veľký).")
                        .font(.caption2).foregroundStyle(.orange)
                case .failed:
                    Text("Podpisy v tomto súbore sa nepodarilo overiť.")
                        .font(.caption2).foregroundStyle(.orange)
                case .plain:
                    EmptyView()
                }
            }
            .padding(.leading, 4)
        } label: {
            Label(label, systemImage: "doc.text")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }

    private var label: String {
        if case .signed(_, let tree) = document.content {
            return document.name + " · " + SignatureTreePresentation.signatureCount(tree.signatures.count)
        }
        return document.name
    }
}
```

In `SigningFlowViews.swift`:

Replace the body of `existingSignaturesSection`:

```swift
    private var existingSignaturesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignatureTreeView(
                state: store.existingSignatureState,
                emptyText: "Dokument zatiaľ neobsahuje elektronický podpis. Podpísanie pridá prvý KEP podpis.",
                onRevalidate: { Task { await store.revalidateExistingSignatures() } })
            if !store.existingSignatures.isEmpty {
                Text("Pridá sa ďalší podpis k existujúcim podpisom v dokumente.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var signatureSectionTitle: String {
        let total = SignatureTreeSummary(tree: store.existingSignatureState.tree).total
        return "Podpisy v dokumente" + (total == 0 ? "" : " · \(total)")
    }
```

Replace the content of `GroupBox("Overenie podpisov v súbore")`:

```swift
            GroupBox("Overenie podpisov v súbore") {
                SignatureTreeView(
                    state: store.resultSignatureState,
                    emptyText: "Podpísaný súbor je pripravený.",
                    onRevalidate: { Task { await store.revalidateResultSignatures() } })
                    .padding(4)
            }
```

In `SignatureInfoRow.body`, replace the QTS line and add coverage below the time:

```swift
                    if info.hasQualifiedTimestamp {
                        Text("QTS").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    } else if info.hasTimestamp {
                        Text("Časová pečiatka").font(.caption2).foregroundStyle(.secondary)
                    }
```

```swift
                if !info.coveredDocuments.isEmpty {
                    Text("Pokrýva: " + info.coveredDocuments.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
```

and make `icon` / `tint` call `SignatureTreePresentation.icon(info.state)` / `.tint(info.state)` instead of the duplicated switches.

- [ ] **Step 4: Run the tests and build the app**

Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter 'SignatureTreePresentationTests|SignatureTreeStoreTests'`
Expected: PASS.
Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift build`
Expected: build succeeds with no new warnings in the touched files.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views Chevron7/Tests/Chevron7AppTests/SignatureTreePresentationTests.swift
git commit -m "feat(signing): zobrazenie stromu podpisov s suhrnom a Overit znova

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 8: Live test, docs, full suites, PR

**Files:**
- Modify: `Chevron7/Tests/Chevron7KitTests/LiveEngineInspectionTests.swift`
- Modify: `CLAUDE.md`, `AGENTS.md` (repository root)

- [ ] **Step 1: Add the live test**

```swift
    func testLiveEngineReturnsTheTreeOfAContainer() async throws {
        guard ProcessInfo.processInfo.environment["CHEVRON7_ENGINE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Vyžaduje CHEVRON7_ENGINE_LIVE_TEST=1.")
        }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "engine/src/test/resources/digital/slovensko/autogram/sample_pdf_xades.asice")
        let result = await EngineBridgeSigningProvider().inspectSignatureTree(in: fixture)

        guard case .tree(let tree) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(tree.signatures.count, 1)
        XCTAssertEqual(tree.documents.map(\.name), ["sample.pdf"])
        guard case .signed(.pdf, let nested) = tree.documents[0].content else {
            return XCTFail("sample.pdf should be inspected as a PDF")
        }
        XCTAssertTrue(nested.signatures.isEmpty)
    }
```

Check the four `deletingLastPathComponent()` calls land on the repository root (`Chevron7/Tests/Chevron7KitTests/<file>` up to the root); adjust the count if not.

- [ ] **Step 2: Run the live test against the rebuilt engine**

Run: `cd Chevron7 && CHEVRON7_ENGINE_LIVE_TEST=1 CHEVRON7_CLI_HELPER="$PWD/.build/engine/Contents/Helpers/AutogramCLI-arm64" DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter LiveEngineInspectionTests`
Expected: PASS (2 tests).

- [ ] **Step 3: Document**

In both `CLAUDE.md` and `AGENTS.md`, append to the "Signing an already signed document" bullet (after the sentence ending "`MachineInspectionService.signaturesCoverDocument`)."):

```
 The signing screens show the signature tree (`SignatureTreeView`, `SignatureTreeState`): the engine's INSPECT and VALIDATE payloads list each container data object with `nested` signatures (PDF or ASiC, one level deep, by bytes not name; deeper or over 100 MB marked `nestedSkipped`, a failure `nestedError`), the store shows the structural tree at once and replaces it with the trusted-list result in the background, "Overiť znova" repeats that, the summary takes the worst result across levels, and "QTS" appears only when full validation confirmed a qualified timestamp. The validation is informative; "Overiť aj na slovensko.sk" only opens the state's informative service in the browser.
```

Then run `cmp CLAUDE.md AGENTS.md` (no output expected) and `grep -c $'\u2014' CLAUDE.md` (expected `0`).

- [ ] **Step 4: Run every suite**

Run: `cd engine && JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca" ./mvnw test 2>&1 | grep -E "Tests run: [0-9]+, Failures|BUILD"`
Expected: `BUILD SUCCESS`.
Run: `cd Chevron7 && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test 2>&1 | tail -5`
Expected: all tests pass (live tests skipped without the variable).
Run: `Chevron7/scripts/check-rename-boundary.sh`
Expected: `✔ Boundary holds`.

- [ ] **Step 5: Commit, push, PR**

```bash
git add Chevron7/Tests/Chevron7KitTests/LiveEngineInspectionTests.swift CLAUDE.md AGENTS.md
git commit -m "docs: strom podpisov v CLAUDE.md a AGENTS.md, live test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin claude/nested-signature-tree
gh pr create --base main --title "feat(signing): strom podpisov s plnym overenim aj vo vnorenych PDF" --body "<summary of the spec, the test evidence, and 🤖 Generated with [Claude Code](https://claude.com/claude-code)>"
```

The PR body is written at that point from the actual results (tests counts, manual check on `report_podpisane_podpisane.asice` online and offline), with no em dashes.
