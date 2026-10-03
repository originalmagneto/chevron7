package digital.slovensko.autogram.ui.machine;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class MachineRequestValidatorTest {
    @TempDir
    Path temporaryDirectory;

    /// A signature without a timestamp is the person's choice (the QTS switch off).
    @Test
    void acceptsBaselineBForAPlainFile() throws Exception {
        var request = signRequest("PAdES_BASELINE_B", files(pdf("source.pdf"), target("signed.pdf")));

        assertDoesNotThrow(() -> MachineRequestValidator.validateSign(request));
    }

    @Test
    void rejectsAnUnknownSignatureLevel() throws Exception {
        var request = signRequest("CAdES_BASELINE_B", files(pdf("source.pdf"), target("signed.pdf")));

        assertEquals("SIGNATURE_LEVEL_REQUIRED", assertThrows(MachineProtocolException.class,
                () -> MachineRequestValidator.validateSign(request)).getMessage());
    }

    @Test
    void acceptsXadesBaselineBForEFormRequests() throws Exception {
        var plain = signRequest("PAdES_BASELINE_B", files(pdf("source.pdf"), target("signed.asice")));

        var eform = new SignRequest(plain.driver(), plain.certificateSerial(), plain.pin(),
                "XAdES_BASELINE_B", plain.timestamp(), plain.files(),
                new EFormRequest("http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
                        null, null, "http://probe.local/form/1.0", null, null, null, null, null,
                        false, false, null, null));

        assertDoesNotThrow(() -> MachineRequestValidator.validateSign(eform));
    }

    /// nove.slovensko.sk asks for XAdES Baseline B around a PDF
    /// (getSignatureWithASiCEnvelopeBase64). XAdES on a PDF always becomes an
    /// ASiC-E.
    @Test
    void acceptsXadesBaselineBForAPdfAPortalWrapsInAsic() throws Exception {
        var request = signRequest("XAdES_BASELINE_B", files(pdf("source.pdf"), target("signed.asice")));

        assertDoesNotThrow(() -> MachineRequestValidator.validateSign(request));
    }

    @Test
    void acceptsOnlyCanonicalAbsolutePdfSourceAndNewExplicitTarget() throws Exception {
        var request = signRequest("PAdES_BASELINE_T", files(pdf("source.pdf"), target("signed.pdf")));

        assertDoesNotThrow(() -> MachineRequestValidator.validateSign(request));
    }

    @Test
    void acceptsXadesBaselineTForAsicOutput() throws Exception {
        var request = signRequest("XAdES_BASELINE_T", files(pdf("source.pdf"), target("signed.asice")));

        assertDoesNotThrow(() -> MachineRequestValidator.validateSign(request));
    }

    @Test
    void rejectsMissingAndExistingTargetFiles() throws Exception {
        var missing = signRequest("PAdES_BASELINE_T", files(temporaryDirectory.resolve("missing.pdf"), target("one.pdf")));
        var existingTarget = Files.writeString(target("existing.pdf"), "%PDF-1.7\n%%EOF");
        var collision = signRequest("PAdES_BASELINE_T", files(pdf("source.pdf"), existingTarget));

        assertInvalid(missing);
        assertInvalid(collision);
    }

    @Test
    void rejectsPathTraversalNonAbsoluteAndDuplicateTargets() throws Exception {
        var source = pdf("source.pdf");
        var traversal = signRequest("PAdES_BASELINE_T", files(source, temporaryDirectory.resolve("nested/../signed.pdf")));
        var relative = signRequest("PAdES_BASELINE_T", List.of(new MachineFile("one", "source.pdf", target("one.pdf").toString())));
        var relativeTarget = signRequest("PAdES_BASELINE_T", List.of(new MachineFile("one", source.toString(), "one.pdf")));
        var samePath = signRequest("PAdES_BASELINE_T", files(source, source));
        var malformed = signRequest("PAdES_BASELINE_T", List.of(new MachineFile("one", source.toString(), "\0.pdf")));
        var duplicate = signRequest("PAdES_BASELINE_T", List.of(
                new MachineFile("one", source.toString(), target("same.pdf").toString()),
                new MachineFile("two", pdf("other.pdf").toString(), target("same.pdf").toString())));

        assertInvalid(traversal);
        assertInvalid(relative);
        assertInvalid(relativeTarget);
        assertInvalid(samePath);
        assertInvalid(malformed);
        assertInvalid(duplicate);
    }

    @Test
    void rejectsCaseInsensitiveDuplicateTargetsBeforeTokenWork() throws Exception {
        var source = pdf("source.pdf");
        var duplicate = signRequest("PAdES_BASELINE_T", List.of(
                new MachineFile("one", source.toString(), target("Signed.PDF").toString()),
                new MachineFile("two", pdf("other.pdf").toString(), target("signed.pdf").toString())));

        assertInvalid(duplicate);
    }

    @Test
    void rejectsUnicodeEquivalentDuplicateTargetsBeforeTokenWork() throws Exception {
        var source = pdf("source.pdf");
        var composed = target("podpis-é.pdf");
        var decomposed = target("podpis-e\u0301.pdf");
        var duplicate = signRequest("PAdES_BASELINE_T", List.of(
                new MachineFile("one", source.toString(), composed.toString()),
                new MachineFile("two", pdf("other.pdf").toString(), decomposed.toString())));

        assertInvalid(duplicate);
    }

    @Test
    void rejectsASymlinkedSourceBeforeAnyTokenWork() throws Exception {
        var source = pdf("source.pdf");
        var link = temporaryDirectory.resolve("source-link.pdf");
        Files.createSymbolicLink(link, source);

        assertInvalid(signRequest("PAdES_BASELINE_T", files(link, target("signed.pdf"))));
    }

    /// Attachments become separate data objects of one ASiC-E, so a PAdES signature can never carry them.
    @Test
    void attachmentsAreRefusedOutsideAsicE() throws Exception {
        var request = signRequest("PAdES_BASELINE_T", List.of(new MachineFile("doc", pdf("doc.pdf").toString(),
                target("out.pdf").toString(), null, List.of(xdcf("a.xml.xdcf").toString()))));

        assertInvalid(request);
    }

    @Test
    void attachmentsAreRefusedWithAnEForm() throws Exception {
        var request = new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(true, List.of("https://tsa.example.test")),
                List.of(new MachineFile("doc", pdf("doc.pdf").toString(), target("out.asice").toString(), null,
                        List.of(xdcf("a.xml.xdcf").toString()))),
                new EFormRequest("http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
                        null, null, "http://probe.local/form/1.0", null, null, null, null, null,
                        false, false, null, null));

        assertInvalid(request);
    }

    @Test
    void acceptsAttachmentsForAnAsicESignature() throws Exception {
        var attachment = xdcf("a.xml.xdcf");
        var request = signRequest("XAdES_BASELINE_T", List.of(new MachineFile("doc", pdf("doc.pdf").toString(),
                target("out.asice").toString(), null, List.of(attachment.toString()))));

        var validated = MachineRequestValidator.validateSign(request);

        assertEquals(List.of(attachment), validated.files().getFirst().attachments());
    }

    @Test
    void anAttachmentMayNotRepeatTheSource() throws Exception {
        var source = pdf("doc.pdf");
        var request = signRequest("XAdES_BASELINE_T", List.of(new MachineFile("doc", source.toString(),
                target("out.asice").toString(), null, List.of(source.toString()))));

        assertInvalid(request);
    }

    @Test
    void anAttachmentMustBeACanonicalExistingFile() throws Exception {
        var source = pdf("doc.pdf");
        var attachment = xdcf("a.xml.xdcf");
        var link = temporaryDirectory.resolve("link.xml.xdcf");
        Files.createSymbolicLink(link, attachment);
        var missing = signRequest("XAdES_BASELINE_T", List.of(new MachineFile("doc", source.toString(),
                target("missing.asice").toString(), null, List.of(temporaryDirectory.resolve("none.xdcf").toString()))));
        var symlinked = signRequest("XAdES_BASELINE_T", List.of(new MachineFile("doc", source.toString(),
                target("link.asice").toString(), null, List.of(link.toString()))));
        var repeated = signRequest("XAdES_BASELINE_T", List.of(new MachineFile("doc", source.toString(),
                target("twice.asice").toString(), null, List.of(attachment.toString(), attachment.toString()))));

        assertInvalid(missing);
        assertInvalid(symlinked);
        assertInvalid(repeated);
    }

    /// With attachments DSS builds a new container, so an existing ASiC would be nested inside it.
    @Test
    void attachmentsRefuseAContainerAsSourceOrAttachment() throws Exception {
        var container = Files.write(temporaryDirectory.resolve("podpisany.asice"), new byte[] { 'P', 'K', 3, 4 }).toRealPath();
        var inner = Files.write(temporaryDirectory.resolve("vnoreny.ASICS"), new byte[] { 'P', 'K', 3, 4 }).toRealPath();
        var containerSource = signRequest("XAdES_BASELINE_T", List.of(new MachineFile("doc", container.toString(),
                target("out-a.asice").toString(), null, List.of(xdcf("a.xml.xdcf").toString()))));
        var containerAttachment = signRequest("XAdES_BASELINE_T", List.of(new MachineFile("doc", pdf("doc.pdf").toString(),
                target("out-b.asice").toString(), null, List.of(container.toString()))));
        var otherContainerAttachment = signRequest("XAdES_BASELINE_T", List.of(new MachineFile("doc",
                pdf("doc2.pdf").toString(), target("out-c.asice").toString(), null, List.of(inner.toString()))));

        assertInvalid(containerSource);
        assertInvalid(containerAttachment);
        assertInvalid(otherContainerAttachment);
    }

    /// Every document becomes a ZIP entry named after its file, so the names must not collide with
    /// each other or with the container's own `mimetype` and `META-INF`.
    @Test
    void attachmentNamesMustBeDistinctEntriesOfTheContainer() throws Exception {
        var source = pdf("dokument.pdf");
        var first = Files.createDirectories(temporaryDirectory.resolve("a")).toRealPath();
        var second = Files.createDirectories(temporaryDirectory.resolve("b")).toRealPath();
        var sameName = List.of(
                Files.writeString(first.resolve("x.xml.xdcf"), "<a/>").toString(),
                Files.writeString(second.resolve("x.xml.xdcf"), "<b/>").toString());
        var sourceName = Files.writeString(first.resolve("dokument.pdf"), "<c/>").toString();
        var caseVariant = Files.writeString(second.resolve("Dokument.PDF"), "<d/>").toString();
        var mimetype = Files.writeString(first.resolve("mimetype"), "<e/>").toString();
        var metaInf = Files.writeString(second.resolve("META-INF"), "<f/>").toString();

        for (var attachments : List.of(sameName, List.of(sourceName), List.of(caseVariant), List.of(mimetype),
                List.of(metaInf))) {
            var request = signRequest("XAdES_BASELINE_T", List.of(new MachineFile("doc", source.toString(),
                    target("names.asice").toString(), null, attachments)));
            assertEquals("PROTOCOL_INVALID_REQUEST", failureCode(request), attachments.toString());
        }
    }

    @Test
    void requiresQualifiedTimestampAndSupportedTsaUrl() throws Exception {
        var source = pdf("source.pdf");
        var timestampNotRequired = request(source, target("not-required.pdf"), false, List.of("https://tsa.example.test"));
        var unsupportedTsa = request(source, target("unsupported.pdf"), true, List.of("file:///tsa"));
        var mixedTsaList = request(source, target("mixed.pdf"), true,
                List.of("https://tsa.example.test", "file:///not-a-timestamp-service"));

        assertEquals("TIMESTAMP_REQUIRED", failureCode(timestampNotRequired));
        assertEquals("TSA_REQUIRED", failureCode(unsupportedTsa));
        assertEquals("TSA_REQUIRED", failureCode(mixedTsaList));
    }

    private SignRequest request(Path source, Path target, boolean required, List<String> servers) {
        return new SignRequest("fake", "123", "1234".toCharArray(), "PAdES_BASELINE_T",
                new QualifiedTimestampRequest(required, servers), files(source, target));
    }

    private SignRequest signRequest(String signatureLevel, List<MachineFile> files) {
        return new SignRequest("fake", "123", "1234".toCharArray(), signatureLevel,
                new QualifiedTimestampRequest(true, List.of("https://tsa.example.test")), files);
    }

    private List<MachineFile> files(Path source, Path target) {
        return List.of(new MachineFile("one", source.toString(), target.toString()));
    }

    private Path pdf(String name) throws IOException {
        return Files.writeString(temporaryDirectory.resolve(name), "%PDF-1.7\nfixture\n%%EOF").toRealPath();
    }

    private Path xdcf(String name) throws IOException {
        return Files.writeString(temporaryDirectory.resolve(name), "<XMLDataContainer/>").toRealPath();
    }

    private Path target(String name) throws IOException {
        return temporaryDirectory.toRealPath().resolve(name);
    }

    private static void assertInvalid(SignRequest request) {
        assertEquals("PROTOCOL_INVALID_REQUEST", failureCode(request));
    }

    private static String failureCode(SignRequest request) {
        return assertThrows(MachineProtocolException.class, () -> MachineRequestValidator.validateSign(request)).getMessage();
    }
}
