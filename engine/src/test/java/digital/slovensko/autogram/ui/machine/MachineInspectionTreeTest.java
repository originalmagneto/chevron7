package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonObject;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
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

    /// Byte inspection keeps today's flat payload: the per-signature coverage belongs to the
    /// tree path only.
    @Test
    void byteInspectionOfAContainerHasNoPerSignatureDocuments() throws Exception {
        var documents = new LinkedHashMap<String, byte[]>();
        documents.put("report.pdf", TestContainers.resource("sample_signed.pdf"));

        var payload = new MachineInspectionService().inspect(TestContainers.signedXadesContainer(documents));

        var signatures = payload.getAsJsonArray("signatures");
        assertTrue(signatures.size() > 0);
        for (var signature : signatures) {
            assertFalse(signature.getAsJsonObject().has("documents"));
        }
        assertFalse(document(payload, "report.pdf").has("nested"));
    }

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
        // DSS merges a lone container into a new signature instead of nesting it, so the
        // outer container needs a second data object to really carry the inner one.
        outerDocuments.put("poznamka.txt", "note".getBytes(java.nio.charset.StandardCharsets.UTF_8));
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
}
