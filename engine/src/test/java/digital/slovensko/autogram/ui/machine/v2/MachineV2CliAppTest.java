package digital.slovensko.autogram.ui.machine.v2;

import com.google.gson.JsonParser;
import digital.slovensko.autogram.ui.machine.MachineDriverService;
import digital.slovensko.autogram.ui.machine.MachineInspectionService;
import digital.slovensko.autogram.ui.machine.MachineProtocolException;
import eu.europa.esig.dss.enumerations.Indication;
import eu.europa.esig.dss.enumerations.SubIndication;
import eu.europa.esig.dss.jaxb.object.Message;
import eu.europa.esig.dss.simplereport.SimpleReport;
import org.apache.commons.cli.DefaultParser;
import org.apache.commons.cli.Options;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.PrintWriter;
import java.io.StringReader;
import java.io.StringWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MachineV2CliAppTest {
    @TempDir
    Path temporaryDirectory;

    @Test
    void completesCapabilitiesAndInspectionOnceForEachRequestId() throws Exception {
        var source = Files.writeString(temporaryDirectory.resolve("source.pdf"), "%PDF-1.7\n%%EOF").toRealPath();
        var target = temporaryDirectory.resolve("signed.pdf");
        var input = "{\"protocolVersion\":2,\"requestId\":\"capabilities-1\",\"operation\":\"CAPABILITIES\",\"payload\":{}}\n"
                + "{\"protocolVersion\":2,\"requestId\":\"inspect-1\",\"operation\":\"INSPECT\",\"payload\":{\"files\":[{\"id\":\"file-1\",\"source\":\""
                + source + "\",\"target\":\"" + target + "\"}]}}\n"
                + "{\"protocolVersion\":2,\"requestId\":\"inspect-invalid\",\"operation\":\"INSPECT\",\"payload\":{\"unexpected\":true}}\n";
        var output = new StringWriter();
        var code = MachineV2CliApp.start(commandLine(), new StringReader(input), new PrintWriter(output),
                new PrintWriter(new StringWriter()), new MachineDriverService(), new MachineInspectionService());

        var events = Arrays.stream(output.toString().strip().split("\\n"))
                .map(JsonParser::parseString)
                .map(element -> element.getAsJsonObject())
                .toList();
        var terminalEvents = events.stream()
                .filter(event -> List.of("request.completed", "request.failed").contains(event.get("type").getAsString()))
                .toList();

        assertEquals(0, code);
        assertEquals(List.of("capabilities-1", "inspect-1", "inspect-invalid"), terminalEvents.stream()
                .map(event -> event.get("requestId").getAsString()).toList());
        assertEquals(1, terminalEvents.stream()
                .filter(event -> "capabilities-1".equals(event.get("requestId").getAsString())).count());
        assertEquals(1, terminalEvents.stream()
                .filter(event -> "inspect-1".equals(event.get("requestId").getAsString())).count());
        assertEquals("PROTOCOL_INVALID_REQUEST", terminalEvents.get(2).getAsJsonObject("payload").get("code").getAsString());
    }

    @Test
    void previewsEmbeddedAsicDocumentAndRedactsSourceForUnknownName() throws Exception {
        var source = Path.of(MachineV2CliAppTest.class
                .getResource("/digital/slovensko/autogram/sample_pdf_xades.asice").getFile());
        var expectedPdf = Files.readAllBytes(Path.of(MachineV2CliAppTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));
        var input = "{\"protocolVersion\":2,\"requestId\":\"preview-1\",\"operation\":\"PREVIEW\",\"payload\":{\"source\":\""
                + source + "\",\"document\":\"sample.pdf\"}}\n"
                + "{\"protocolVersion\":2,\"requestId\":\"preview-missing\",\"operation\":\"PREVIEW\",\"payload\":{\"source\":\""
                + source + "\",\"document\":\"missing.pdf\"}}\n";
        var output = new StringWriter();

        var code = MachineV2CliApp.start(commandLine(), new StringReader(input), new PrintWriter(output),
                new PrintWriter(new StringWriter()), new MachineDriverService(), new MachineInspectionService());

        var events = Arrays.stream(output.toString().strip().split("\\n"))
                .map(JsonParser::parseString)
                .map(element -> element.getAsJsonObject())
                .toList();
        var preview = events.stream()
                .filter(event -> "preview.completed".equals(event.get("type").getAsString()))
                .findFirst()
                .orElseThrow();

        assertEquals(0, code);
        assertEquals(List.of("request.started", "preview.completed", "request.completed", "request.started", "request.failed"),
                events.stream().map(event -> event.get("type").getAsString()).toList());
        assertEquals("sample.pdf", preview.getAsJsonObject("payload").get("name").getAsString());
        assertEquals("application/pdf", preview.getAsJsonObject("payload").get("mediaType").getAsString());
        assertArrayEquals(expectedPdf, Base64.getDecoder().decode(
                preview.getAsJsonObject("payload").get("contentBase64").getAsString()));
        assertEquals("PREVIEW_DOCUMENT_NOT_FOUND", events.get(4).getAsJsonObject("payload").get("code").getAsString());
        assertFalse(output.toString().contains(source.toString()));
    }

    @Test
    void retriesTrustedInitializationReusesItAndContinuesAfterPerFileValidationFailure() throws Exception {
        var report = mock(SimpleReport.class);
        when(report.getSignatureIdList()).thenReturn(List.of("sig-1"));
        when(report.isValid("sig-1")).thenReturn(false);
        when(report.getIndication("sig-1")).thenReturn(Indication.INDETERMINATE);
        when(report.getSubIndication("sig-1")).thenReturn(SubIndication.NO_CERTIFICATE_CHAIN_FOUND);
        when(report.getAdESValidationErrors("sig-1")).thenReturn(List.of(
                new Message("chain", "Certificate chain could not be built")));
        when(report.getSignatureTimestamps("sig-1")).thenReturn(List.of());
        var trustedInspection = MachineInspectionService.forTrustedValidation(validator -> report);
        var initializations = new AtomicInteger();
        var source = Path.of(MachineV2CliAppTest.class.getResource("/digital/slovensko/autogram/sample.pdf").getFile());
        var missingSource = temporaryDirectory.resolve("missing.pdf");
        var input = "{\"protocolVersion\":2,\"requestId\":\"validate-init-failed\",\"operation\":\"VALIDATE\",\"payload\":{\"files\":[{\"id\":\"file-failed-init\",\"source\":\""
                + source + "\",\"target\":\"/selected/target.pdf\"}]}}\n"
                + "{\"protocolVersion\":2,\"requestId\":\"validate-retry\",\"operation\":\"VALIDATE\",\"payload\":{\"files\":[{\"id\":\"file-good\",\"source\":\""
                + source + "\",\"target\":\"/selected/good.pdf\"},{\"id\":\"file-bad\",\"source\":\""
                + missingSource + "\",\"target\":\"/selected/bad.pdf\"}]}}\n"
                + "{\"protocolVersion\":2,\"requestId\":\"validate-reused\",\"operation\":\"VALIDATE\",\"payload\":{\"files\":[{\"id\":\"file-reused\",\"source\":\""
                + source + "\",\"target\":\"/selected/reused.pdf\"}]}}\n";
        var output = new StringWriter();

        var code = MachineV2CliApp.start(commandLine(), new StringReader(input), new PrintWriter(output),
                new PrintWriter(new StringWriter()), new MachineDriverService(), new MachineInspectionService(),
                trustedInspection, () -> {
                    if (initializations.getAndIncrement() == 0) {
                        throw new MachineProtocolException("TRUSTED_LIST_UNAVAILABLE");
                    }
                });

        var events = Arrays.stream(output.toString().strip().split("\\n"))
                .map(JsonParser::parseString)
                .map(element -> element.getAsJsonObject())
                .toList();
        var validation = events.get(3).getAsJsonObject("payload").getAsJsonArray("signatures")
                .get(0).getAsJsonObject();

        assertEquals(0, code);
        assertEquals(2, initializations.get());
        assertEquals(List.of("request.started", "request.failed", "request.started", "validation.completed",
                "file.failed", "request.completed", "request.started", "validation.completed", "request.completed"),
                events.stream().map(event -> event.get("type").getAsString()).toList());
        assertEquals("TRUSTED_LIST_UNAVAILABLE", events.get(1).getAsJsonObject("payload").get("code").getAsString());
        assertEquals("file-good", events.get(3).get("fileId").getAsString());
        assertEquals("file-bad", events.get(4).get("fileId").getAsString());
        assertEquals("VALIDATION_FAILED", events.get(4).getAsJsonObject("payload").get("code").getAsString());
        assertEquals("file-reused", events.get(7).get("fileId").getAsString());
        assertEquals("INDETERMINATE", validation.get("indication").getAsString());
        assertEquals("NO_CERTIFICATE_CHAIN_FOUND", validation.get("subIndication").getAsString());
        assertEquals("Certificate chain could not be built", validation.get("validationReason").getAsString());
    }

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

    private static org.apache.commons.cli.CommandLine commandLine() throws Exception {
        var options = new Options()
                .addOption(null, "machine-readable", false, "")
                .addOption(null, "protocol-version", true, "");
        return new DefaultParser().parse(options, new String[] { "--machine-readable", "--protocol-version", "2" });
    }
}
