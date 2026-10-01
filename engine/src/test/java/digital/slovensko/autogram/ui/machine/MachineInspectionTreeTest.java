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
}
