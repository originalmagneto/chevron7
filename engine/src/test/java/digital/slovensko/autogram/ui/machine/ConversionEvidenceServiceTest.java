package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonObject;
import digital.slovensko.autogram.core.ConversionTestContainers;
import digital.slovensko.autogram.core.ConversionTestContainers.Entry;
import digital.slovensko.autogram.core.ConversionTestPdfs;
import digital.slovensko.autogram.util.DSSUtils;
import eu.europa.esig.dss.model.FileDocument;
import eu.europa.esig.dss.model.timedependent.TimeDependentValues;
import eu.europa.esig.dss.model.tsl.TLInfo;
import eu.europa.esig.dss.model.tsl.TrustProperties;
import eu.europa.esig.dss.model.tsl.TrustServiceProvider;
import eu.europa.esig.dss.model.tsl.TrustServiceStatusAndInformationExtensions;
import eu.europa.esig.dss.spi.tsl.TrustedListsCertificateSource;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.validation.SignedDocumentValidator;
import eu.europa.esig.dss.validation.reports.Reports;
import org.bouncycastle.asn1.DERSequence;
import org.bouncycastle.asn1.x500.X500NameBuilder;
import org.bouncycastle.asn1.x500.style.BCStyle;
import org.bouncycastle.asn1.x509.CertificatePolicies;
import org.bouncycastle.asn1.x509.DisplayText;
import org.bouncycastle.asn1.x509.Extension;
import org.bouncycastle.asn1.x509.PolicyInformation;
import org.bouncycastle.asn1.x509.PolicyQualifierInfo;
import org.bouncycastle.asn1.x509.UserNotice;
import org.bouncycastle.asn1.ASN1ObjectIdentifier;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.junit.jupiter.api.Test;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPairGenerator;
import java.util.Base64;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.function.Function;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ConversionEvidenceServiceTest {
    private static final String QES_VALIDATION = "http://uri.etsi.org/TrstSvc/Svctype/QESValidation/Q";

    private static Path resource(String name) {
        return Path.of(Objects.requireNonNull(ConversionEvidenceServiceTest.class
                .getResource("/digital/slovensko/autogram/" + name)).getFile());
    }

    private static Function<SignedDocumentValidator, Reports> plainValidation() {
        return validator -> {
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            return validator.validateDocument();
        };
    }

    private static JsonObject evidenceOf(String name, List<String> unavailable) {
        return new ConversionEvidenceService(plainValidation(), () -> unavailable).evidence(resource(name)).getAsJsonObject("evidence");
    }

    private static String decoded(String base64) {
        return new String(Base64.getDecoder().decode(base64), StandardCharsets.UTF_8);
    }

    @Test
    void evidenceForSignedPdfCarriesSignatureValueAndRevision() throws Exception {
        var evidence = evidenceOf("sample_signed.pdf", List.of());
        var signatures = evidence.getAsJsonArray("signatures");
        assertEquals(1, signatures.size());
        var signature = signatures.get(0).getAsJsonObject();
        assertTrue(Base64.getDecoder().decode(signature.get("signatureValueBase64").getAsString()).length > 100);
        assertEquals(Files.size(resource("sample_signed.pdf")), signature.get("signedRevisionLength").getAsLong());
        assertTrue(decoded(evidence.get("etsiReportBase64").getAsString()).contains("ValidationReport"));
        assertEquals("6.4", evidence.get("dssVersion").getAsString());
        assertNotNull(evidence.get("validationTime"));
        assertFalse(evidence.getAsJsonObject("pdf").get("pdfaCompliant").getAsBoolean());
        assertEquals(0, evidence.getAsJsonObject("pdf").getAsJsonArray("changesAfterLastSignature").size());
    }

    @Test
    void slimSignatureReportHasOneSignatureAndNoValidationObjectValues() {
        var signature = evidenceOf("sample_signed.pdf", List.of()).getAsJsonArray("signatures").get(0).getAsJsonObject();
        var slim = decoded(signature.get("etsiSignatureReportBase64").getAsString());
        assertEquals(1, slim.split("SignatureValidationReport>", -1).length / 2);
        assertFalse(slim.contains("ValidationObjectRepresentation"), slim);
        assertTrue(slim.contains(signature.get("id").getAsString()), slim);
    }

    @Test
    void pdfChangedAfterLastSignatureIsReported() throws Exception {
        var signed = digital.slovensko.autogram.core.ConversionTestPdfs.sign(
                digital.slovensko.autogram.core.ConversionTestPdfs.samplePdf(), false);
        var annotated = digital.slovensko.autogram.core.ConversionTestPdfs.annotateIncrementally(signed);
        var directory = Files.createTempDirectory("evidence");
        var clean = Files.write(directory.resolve("clean.pdf"), signed);
        var changed = Files.write(directory.resolve("changed.pdf"), annotated);
        var service = new ConversionEvidenceService(plainValidation(), List::of);

        var cleanChanges = service.evidence(clean).getAsJsonObject("evidence").getAsJsonObject("pdf")
                .getAsJsonArray("changesAfterLastSignature");
        var changedChanges = service.evidence(changed).getAsJsonObject("evidence").getAsJsonObject("pdf")
                .getAsJsonArray("changesAfterLastSignature");

        assertEquals(0, cleanChanges.size(), cleanChanges.toString());
        assertTrue(changedChanges.toString().contains("ANNOTATION"), changedChanges.toString());
    }

    @Test
    void evidenceForXadesContainerHasNoRevision() {
        var evidence = evidenceOf("sample_docx_xades.asice", List.of());
        var signature = evidence.getAsJsonArray("signatures").get(0).getAsJsonObject();
        assertFalse(signature.has("signedRevisionLength"));
        var pdf = evidence.getAsJsonObject("pdf");
        assertEquals(1, pdf.get("asicDataObjectCount").getAsInt());
        assertFalse(pdf.has("asicDataObjectName"));
    }

    @Test
    void asicFactsNameTheOnlyPdfDataObject() {
        var pdf = evidenceOf("sample_pdf_cades.asice", List.of()).getAsJsonObject("pdf");
        assertEquals(1, pdf.get("asicDataObjectCount").getAsInt());
        assertTrue(pdf.get("asicDataObjectName").getAsString().toLowerCase(Locale.ROOT).endsWith(".pdf"));
        assertFalse(pdf.get("asicDataObjectSigned").getAsBoolean());
    }

    private static JsonObject evidenceOfContainer(byte[] container) throws Exception {
        var path = Files.write(Files.createTempDirectory("evidence").resolve("container.asice"), container);
        return new ConversionEvidenceService(plainValidation(), List::of).evidence(path).getAsJsonObject("evidence");
    }

    private static JsonObject pdfEvidenceOfContainer(byte[] container) throws Exception {
        return evidenceOfContainer(container).getAsJsonObject("pdf");
    }

    private static String sha256Base64(byte[] bytes) throws Exception {
        return Base64.getEncoder().encodeToString(java.security.MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    private static JsonObject dataObject(JsonObject pdf, String name) {
        for (var element : pdf.getAsJsonArray("dataObjects")) {
            if (element.getAsJsonObject().get("name").getAsString().equals(name)) return element.getAsJsonObject();
        }
        throw new AssertionError("No data object " + name + " in " + pdf);
    }

    @Test
    void multiFileContainerListsEveryDataObjectInOrder() throws Exception {
        var entries = List.of(
                new Entry("zmluva.pdf", ConversionTestPdfs.samplePdf()),
                new Entry("priloha.png", ConversionTestContainers.png(120, 80, false)),
                new Entry("foto.jpg", ConversionTestContainers.jpeg(64, 48, false)));

        var evidence = evidenceOfContainer(ConversionTestContainers.xadesAsice(entries));
        var pdf = evidence.getAsJsonObject("pdf");

        assertEquals(3, pdf.get("asicDataObjectCount").getAsInt());
        var objects = pdf.getAsJsonArray("dataObjects");
        assertEquals(3, objects.size(), objects.toString());
        var kinds = List.of("pdf", "png", "jpeg");
        String signatureId = null;
        for (var index = 0; index < 3; index++) {
            var object = objects.get(index).getAsJsonObject();
            var entry = entries.get(index);
            assertEquals(entry.name(), object.get("name").getAsString());
            assertEquals(kinds.get(index), object.get("kind").getAsString());
            assertEquals(entry.bytes().length, object.get("size").getAsLong());
            assertEquals(sha256Base64(entry.bytes()), object.get("sha256Base64").getAsString());
            var coveredBy = object.getAsJsonArray("coveredBy");
            assertEquals(1, coveredBy.size(), object.toString());
            if (signatureId == null) signatureId = coveredBy.get(0).getAsString();
            assertEquals(signatureId, coveredBy.get(0).getAsString());
            assertFalse(object.has("problem"), object.toString());
        }
        assertEquals(evidence.getAsJsonArray("signatures").get(0).getAsJsonObject().get("id").getAsString(), signatureId);
        assertEquals(1, objects.get(0).getAsJsonObject().get("pages").getAsInt());
        assertTrue(objects.get(0).getAsJsonObject().has("pdfaCompliant"));
        assertEquals(120, objects.get(1).getAsJsonObject().get("widthPx").getAsInt());
        assertEquals(80, objects.get(1).getAsJsonObject().get("heightPx").getAsInt());
        assertEquals(64, objects.get(2).getAsJsonObject().get("widthPx").getAsInt());
        assertEquals(48, objects.get(2).getAsJsonObject().get("heightPx").getAsInt());
    }

    @Test
    void signatureCoveringOneFileIsListedOnlyThere() throws Exception {
        var container = ConversionTestContainers.xadesAsice(List.of(
                new Entry("a.pdf", ConversionTestPdfs.withText("A")),
                new Entry("b.pdf", ConversionTestPdfs.withText("B"))));
        var twice = ConversionTestContainers.addSignatureCovering(container, List.of("b.pdf"));

        var pdf = pdfEvidenceOfContainer(twice);

        var a = dataObject(pdf, "a.pdf").getAsJsonArray("coveredBy");
        var b = dataObject(pdf, "b.pdf").getAsJsonArray("coveredBy");
        assertEquals(1, a.size(), a.toString());
        assertEquals(2, b.size(), b.toString());
        assertTrue(b.contains(a.get(0)), b.toString());
    }

    @Test
    void docxEntryIsOther() {
        var pdf = evidenceOf("sample_docx_xades.asice", List.of()).getAsJsonObject("pdf");
        var objects = pdf.getAsJsonArray("dataObjects");
        assertEquals(1, objects.size());
        assertEquals("other", objects.get(0).getAsJsonObject().get("kind").getAsString());
        assertEquals(1, objects.get(0).getAsJsonObject().getAsJsonArray("coveredBy").size(), objects.toString());
    }

    @Test
    void cadesContainerDataObjectIsCovered() {
        var objects = evidenceOf("sample_pdf_cades.asice", List.of()).getAsJsonObject("pdf").getAsJsonArray("dataObjects");
        assertEquals(1, objects.size());
        assertEquals("pdf", objects.get(0).getAsJsonObject().get("kind").getAsString());
        assertEquals(1, objects.get(0).getAsJsonObject().getAsJsonArray("coveredBy").size(), objects.toString());
    }

    @Test
    void namesWithDiacriticsSpacesAndFoldersAreCovered() throws Exception {
        var pdf = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("Zmluva o dielo č. 1.pdf", ConversionTestPdfs.samplePdf()),
                new Entry("prilohy/foto 1.jpg", ConversionTestContainers.jpeg(16, 16, false)))));

        assertEquals(1, dataObject(pdf, "Zmluva o dielo č. 1.pdf").getAsJsonArray("coveredBy").size(), pdf.toString());
        assertEquals(1, dataObject(pdf, "prilohy/foto 1.jpg").getAsJsonArray("coveredBy").size(), pdf.toString());
    }

    @Test
    void imageBuildersMakeWhatTheyPromise() throws Exception {
        var png = ConversionTestContainers.png(4, 3, true);
        assertEquals(16, png[24], "IHDR bit depth");
        var jpeg = ConversionTestContainers.jpeg(8, 8, true);
        var components = -1;
        for (var index = 2; index + 9 < jpeg.length; ) {
            if ((jpeg[index] & 0xFF) != 0xFF) break;
            var marker = jpeg[index + 1] & 0xFF;
            var length = ((jpeg[index + 2] & 0xFF) << 8) | (jpeg[index + 3] & 0xFF);
            if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
                components = jpeg[index + 9] & 0xFF;
                break;
            }
            index += 2 + length;
        }
        assertEquals(4, components);
    }

    private static JsonObject pdfEvidenceOf(ConversionEvidenceService service, byte[] container) throws Exception {
        var path = Files.write(Files.createTempDirectory("evidence").resolve("container.asice"), container);
        return service.evidence(path).getAsJsonObject("evidence").getAsJsonObject("pdf");
    }

    /// Replaces every occurrence of `from` in the zip's raw bytes (entry names in the local
    /// headers and the central directory) with `to`, which has the same length.
    private static byte[] renamedInZip(byte[] zip, String from, String to) {
        var source = from.getBytes(StandardCharsets.UTF_8);
        var target = to.getBytes(StandardCharsets.UTF_8);
        assertEquals(source.length, target.length);
        var copy = zip.clone();
        var replaced = 0;
        for (var index = 0; index + source.length <= copy.length; index++) {
            if (java.util.Arrays.equals(copy, index, index + source.length, source, 0, source.length)) {
                System.arraycopy(target, 0, copy, index, target.length);
                replaced++;
            }
        }
        assertEquals(2, replaced, "local header and central directory");
        return copy;
    }

    @Test
    void duplicateEntryNameIsFlagged() throws Exception {
        var bytes = ConversionTestPdfs.withText("A");
        var container = renamedInZip(ConversionTestContainers.xadesAsice(List.of(
                new Entry("dvojka-A.pdf", bytes), new Entry("dvojka-B.pdf", bytes))), "dvojka-B.pdf", "dvojka-A.pdf");

        var pdf = pdfEvidenceOfContainer(container);

        assertEquals("dvojka-A.pdf", pdf.get("duplicateDataObjectName").getAsString(), pdf.toString());
        assertEquals(2, pdf.getAsJsonArray("dataObjects").size());
    }

    @Test
    void onlyPdfIsFoundByItsBytesNotItsName() throws Exception {
        var pdf = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva", ConversionTestPdfs.samplePdf()))));

        assertEquals("zmluva", pdf.get("asicDataObjectName").getAsString(), pdf.toString());
        assertFalse(pdf.get("asicDataObjectSigned").getAsBoolean());
        assertTrue(pdf.has("pdfaCompliant"), pdf.toString());
        assertTrue(pdf.has("declaredPdfaPart") || pdf.has("hasEmbeddedFiles"), pdf.toString());
    }

    @Test
    void imageNamedPdfIsNotTheOnlyPdf() throws Exception {
        var pdf = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("obrazok.pdf", ConversionTestContainers.png(10, 10, false)))));

        assertFalse(pdf.has("asicDataObjectName"), pdf.toString());
        assertFalse(pdf.has("pdfaCompliant"), pdf.toString());
    }

    @Test
    void sizeLimitAppliesOnlyToContainersWithSeveralFiles() throws Exception {
        var service = new ConversionEvidenceService(plainValidation(), List::of, 10,
                ConversionEvidenceService::hasSignatures);
        var only = pdfEvidenceOf(service, ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", ConversionTestPdfs.samplePdf()))));
        var object = dataObject(only, "zmluva.pdf");
        assertEquals("pdf", object.get("kind").getAsString(), object.toString());
        assertFalse(object.has("problem"), object.toString());
        assertEquals("zmluva.pdf", only.get("asicDataObjectName").getAsString());

        var several = pdfEvidenceOf(service, ConversionTestContainers.xadesAsice(List.of(
                new Entry("a.pdf", ConversionTestPdfs.withText("A")),
                new Entry("b.png", ConversionTestContainers.png(10, 10, false)))));
        for (var name : List.of("a.pdf", "b.png")) {
            assertEquals("TOO_LARGE", dataObject(several, name).get("problem").getAsString(), several.toString());
        }
    }

    @Test
    void signatureProbeFailureIsNeverUnsigned() throws Exception {
        java.util.function.Predicate<byte[]> failing = bytes -> {
            throw new IllegalStateException("DSS cannot read it");
        };
        var service = new ConversionEvidenceService(plainValidation(), List::of,
                ConversionEvidenceService.DATA_OBJECT_LIMIT, failing);

        var several = pdfEvidenceOf(service, ConversionTestContainers.xadesAsice(List.of(
                new Entry("a.pdf", ConversionTestPdfs.withText("A")),
                new Entry("b.png", ConversionTestContainers.png(10, 10, false)))));
        var object = dataObject(several, "a.pdf");
        assertEquals("pdf", object.get("kind").getAsString());
        assertEquals("NESTED_UNREADABLE", object.get("problem").getAsString(), object.toString());

        var only = pdfEvidenceOf(service, ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", ConversionTestPdfs.withText("A")))));
        assertTrue(only.get("asicDataObjectSigned").getAsBoolean(), only.toString());
        assertEquals("NESTED_UNREADABLE", dataObject(only, "zmluva.pdf").get("problem").getAsString());
    }

    /// The app pairs the tree with the evidence by name and by signature id; both must agree.
    @Test
    void treeAndDataObjectsAgreeOnNamesAndNestedSignatureIds() throws Exception {
        var signed = ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false);
        var container = ConversionTestContainers.xadesAsice(List.of(
                new Entry("slozka/zmluva.pdf", signed),
                new Entry("prilohy/foto.png", ConversionTestContainers.png(10, 10, false))));
        var path = Files.write(Files.createTempDirectory("evidence").resolve("container.asice"), container);

        var output = new ConversionEvidenceService(plainValidation(), List::of).evidence(path);

        var objects = output.getAsJsonObject("evidence").getAsJsonObject("pdf").getAsJsonArray("dataObjects");
        var objectNames = new java.util.ArrayList<String>();
        objects.forEach(element -> objectNames.add(element.getAsJsonObject().get("name").getAsString()));
        var treeNames = new java.util.ArrayList<String>();
        JsonObject signedEntry = null;
        for (var element : output.getAsJsonArray("documents")) {
            var name = element.getAsJsonObject().get("name").getAsString();
            treeNames.add(name);
            if (name.equals("slozka/zmluva.pdf")) signedEntry = element.getAsJsonObject();
        }
        assertEquals(objectNames, treeNames, output.getAsJsonArray("documents").toString());
        assertNotNull(signedEntry);

        var treeIds = new java.util.ArrayList<String>();
        signedEntry.getAsJsonObject("nested").getAsJsonArray("signatures")
                .forEach(element -> treeIds.add(element.getAsJsonObject().get("id").getAsString()));
        var evidenceIds = new java.util.ArrayList<String>();
        dataObject(output.getAsJsonObject("evidence").getAsJsonObject("pdf"), "slozka/zmluva.pdf")
                .getAsJsonObject("evidence").getAsJsonArray("signatures")
                .forEach(element -> evidenceIds.add(element.getAsJsonObject().get("id").getAsString()));
        assertEquals(1, evidenceIds.size());
        assertEquals(evidenceIds, treeIds);
    }

    @Test
    void kindIsReadFromBytes() throws Exception {
        var pdf = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("obrazok.pdf", ConversionTestContainers.png(10, 10, true)))));

        var object = dataObject(pdf, "obrazok.pdf");
        assertEquals("png", object.get("kind").getAsString());
        assertEquals(10, object.get("widthPx").getAsInt());
    }

    @Test
    void embeddedFileNamesAreListed() throws Exception {
        var pdf = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("s-prilohou.pdf", ConversionTestContainers.pdfWithEmbeddedFile("x.txt",
                        "obsah".getBytes(StandardCharsets.UTF_8))),
                new Entry("foto.jpg", ConversionTestContainers.jpeg(20, 10, true)))));

        var object = dataObject(pdf, "s-prilohou.pdf");
        assertEquals("[\"x.txt\"]", object.getAsJsonArray("embeddedFileNames").toString());
        assertTrue(object.get("hasEmbeddedFiles").getAsBoolean());
        assertEquals("jpeg", dataObject(pdf, "foto.jpg").get("kind").getAsString());
    }

    @Test
    void signedPdfDataObjectCarriesNestedEvidence() throws Exception {
        var signed = ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false);
        var pdf = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", signed),
                new Entry("b.pdf", ConversionTestPdfs.withText("B")))));

        var objects = pdf.getAsJsonArray("dataObjects");
        var nested = objects.get(0).getAsJsonObject().getAsJsonObject("evidence");
        assertNotNull(nested, objects.get(0).toString());
        var signatures = nested.getAsJsonArray("signatures");
        assertEquals(1, signatures.size(), signatures.toString());
        var signature = signatures.get(0).getAsJsonObject();
        assertTrue(Base64.getDecoder().decode(signature.get("signatureValueBase64").getAsString()).length > 100);
        assertTrue(decoded(signature.get("etsiSignatureReportBase64").getAsString()).contains("SignatureValidationReport"));
        assertEquals(signed.length, signature.get("signedRevisionLength").getAsLong());
        assertEquals("6.4", nested.get("dssVersion").getAsString());
        assertNotNull(nested.get("validationTime"));
        assertTrue(decoded(nested.get("etsiReportBase64").getAsString()).contains("ValidationReport"));
        assertEquals(0, nested.getAsJsonObject("pdf").getAsJsonArray("changesAfterLastSignature").size());
        assertTrue(nested.getAsJsonObject("pdf").has("pdfaCompliant"));
        assertFalse(nested.has("tree"), nested.toString());
        assertFalse(objects.get(0).getAsJsonObject().has("problem"), objects.get(0).toString());
        assertFalse(objects.get(1).getAsJsonObject().has("evidence"), objects.get(1).toString());
    }

    @Test
    void nestedChangesAfterSignatureAreReported() throws Exception {
        var changed = ConversionTestPdfs.annotateIncrementally(ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false));
        var pdf = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", changed),
                new Entry("b.pdf", ConversionTestPdfs.withText("B")))));

        var changes = dataObject(pdf, "zmluva.pdf").getAsJsonObject("evidence").getAsJsonObject("pdf")
                .getAsJsonArray("changesAfterLastSignature");
        assertTrue(changes.toString().contains("ANNOTATION"), changes.toString());
    }

    @Test
    void nestedTrustedListStateUsesTheSameCountries() throws Exception {
        var signed = ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false);
        var probe = DSSUtils.createDocumentValidator(new eu.europa.esig.dss.model.InMemoryDocument(signed));
        probe.setCertificateVerifier(new CommonCertificateVerifier());
        var issuer = probe.getSignatures().getFirst().getSigningCertificateToken().getIssuer().getPrincipal().getName();
        var subject = probe.getSignatures().getFirst().getSigningCertificateToken().getSubject().getPrincipal().getName();
        var hasCountry = issuer.matches("(^|.*,)C=.*") || subject.matches("(^|.*,)C=.*");
        var container = ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", signed),
                new Entry("b.pdf", ConversionTestPdfs.withText("B"))));
        var path = Files.write(Files.createTempDirectory("evidence").resolve("container.asice"), container);

        var asked = new java.util.concurrent.atomic.AtomicInteger();
        var missing = nestedSignature(new ConversionEvidenceService(plainValidation(), () -> {
            asked.incrementAndGet();
            return List.of(Locale.getISOCountries());
        }).evidence(path).getAsJsonObject("evidence"));
        var loaded = nestedSignature(new ConversionEvidenceService(plainValidation(), List::of)
                .evidence(path).getAsJsonObject("evidence"));

        // The container and the nested PDF both read the injected trusted list state.
        assertEquals(2, asked.get());
        assertFalse(loaded.get("trustedListUnavailable").getAsBoolean());
        // The engine's test key names no country, so the anchor cannot be matched (as in
        // trustedListUnavailableOnlyWhenTheAnchorCountryDidNotLoad).
        assertEquals(hasCountry, missing.get("trustedListUnavailable").getAsBoolean(), issuer + " / " + subject);
    }

    private static JsonObject nestedSignature(JsonObject evidence) {
        return dataObject(evidence.getAsJsonObject("pdf"), "zmluva.pdf").getAsJsonObject("evidence")
                .getAsJsonArray("signatures").get(0).getAsJsonObject();
    }

    @Test
    void nestedValidationFailureMarksOnlyThatDataObject() throws Exception {
        var container = ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false)),
                new Entry("b.pdf", ConversionTestPdfs.withText("B"))));
        var path = Files.write(Files.createTempDirectory("evidence").resolve("container.asice"), container);
        Function<SignedDocumentValidator, Reports> failingForPdf = validator -> {
            if (validator instanceof eu.europa.esig.dss.pades.validation.PDFDocumentValidator) {
                throw new IllegalStateException("nested validation failed");
            }
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            return validator.validateDocument();
        };

        var evidence = new ConversionEvidenceService(failingForPdf, List::of).evidence(path).getAsJsonObject("evidence");

        var object = dataObject(evidence.getAsJsonObject("pdf"), "zmluva.pdf");
        assertEquals("pdf", object.get("kind").getAsString());
        assertEquals("NESTED_UNREADABLE", object.get("problem").getAsString());
        assertFalse(object.has("evidence"), object.toString());
        assertEquals(1, evidence.getAsJsonArray("signatures").size());
        assertEquals("pdf", dataObject(evidence.getAsJsonObject("pdf"), "b.pdf").get("kind").getAsString());
    }

    @Test
    void malformedPdfDataObjectIsUnreadable() throws Exception {
        var garbage = "%PDF-1.7\n\u0000\u0001 not a pdf at all <<< /Root 9 0 R >>> trailer".getBytes(StandardCharsets.ISO_8859_1);
        var evidence = evidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("zly.pdf", garbage),
                new Entry("foto.jpg", ConversionTestContainers.jpeg(20, 10, false)))));

        var object = dataObject(evidence.getAsJsonObject("pdf"), "zly.pdf");
        assertEquals("other", object.get("kind").getAsString());
        assertEquals("UNREADABLE", object.get("problem").getAsString());
        assertEquals("jpeg", dataObject(evidence.getAsJsonObject("pdf"), "foto.jpg").get("kind").getAsString());
        assertEquals(1, evidence.getAsJsonArray("signatures").size());
    }

    @Test
    void malformedOnlyPdfDataObjectStillGivesEvidence() throws Exception {
        var garbage = "%PDF-1.7\n\u0000\u0001 not a pdf at all <<< /Root 9 0 R >>> trailer".getBytes(StandardCharsets.ISO_8859_1);
        var evidence = evidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(new Entry("x.pdf", garbage))));

        var object = dataObject(evidence.getAsJsonObject("pdf"), "x.pdf");
        assertEquals("other", object.get("kind").getAsString());
        assertEquals("UNREADABLE", object.get("problem").getAsString());
        assertEquals(1, evidence.getAsJsonArray("signatures").size());
    }

    @Test
    void trustedListUnavailableOnlyWhenTheAnchorCountryDidNotLoad() {
        var probe = DSSUtils.createDocumentValidator(new FileDocument(resource("sample_signed.pdf").toFile()));
        probe.setCertificateVerifier(new CommonCertificateVerifier());
        var issuer = probe.getSignatures().getFirst().getSigningCertificateToken().getIssuer().getPrincipal().getName();
        var subject = probe.getSignatures().getFirst().getSigningCertificateToken().getSubject().getPrincipal().getName();
        var hasCountry = issuer.matches("(^|.*,)C=.*") || subject.matches("(^|.*,)C=.*");

        var missing = evidenceOf("sample_signed.pdf", List.of(Locale.getISOCountries()))
                .getAsJsonArray("signatures").get(0).getAsJsonObject();
        var loaded = evidenceOf("sample_signed.pdf", List.of()).getAsJsonArray("signatures").get(0).getAsJsonObject();

        assertFalse(loaded.get("trustedListUnavailable").getAsBoolean());
        assertEquals(hasCountry, missing.get("trustedListUnavailable").getAsBoolean(), issuer + " / " + subject);
    }

    @Test
    void mandantAndPoliciesAreExtracted() throws Exception {
        var keys = KeyPairGenerator.getInstance("RSA");
        keys.initialize(2048);
        var pair = keys.generateKeyPair();
        var subject = new X500NameBuilder(BCStyle.INSTANCE)
                .addRDN(BCStyle.CN, "Ján Advokát")
                .addRDN(BCStyle.O, "MANDANT Advokátska kancelária s.r.o.")
                .addRDN(BCStyle.SERIALNUMBER, "PNOSK-1234567890")
                .build();
        var notice = new UserNotice(null, new DisplayText(DisplayText.CONTENT_TYPE_UTF8STRING, "OPRÁVNENIE 1042"));
        var policies = new CertificatePolicies(new PolicyInformation[] {
                new PolicyInformation(new ASN1ObjectIdentifier("1.3.158.36061701.1.1.1042"),
                        new DERSequence(new PolicyQualifierInfo(
                                org.bouncycastle.asn1.x509.PolicyQualifierId.id_qt_unotice, notice))),
                new PolicyInformation(new ASN1ObjectIdentifier("0.4.0.194112.1.2"),
                        new DERSequence(new PolicyQualifierInfo("https://example.test/cps")))
        });
        var builder = new JcaX509v3CertificateBuilder(subject, BigInteger.ONE, new Date(), new Date(System.currentTimeMillis() + 86_400_000L),
                subject, pair.getPublic());
        builder.addExtension(Extension.certificatePolicies, false, policies);
        var certificate = builder.build(new JcaContentSignerBuilder("SHA256withRSA").build(pair.getPrivate())).getEncoded();

        var facts = ConversionEvidenceService.X509Facts.of(certificate);

        assertEquals(List.of("MANDANT Advokátska kancelária s.r.o."), facts.mandants());
        assertEquals("1.3.158.36061701.1.1.1042", facts.policies().get(0).oid());
        assertEquals("OPRÁVNENIE 1042", facts.policies().get(0).explicitText());
        assertEquals(null, facts.policies().get(1).explicitText());
        assertEquals("1042 OPRÁVNENIE 1042", facts.mandate());
    }

    /// The seal of a qualified validation service's report is made with the certificate the
    /// trusted list names as that service's identity; the evidence must report its type.
    @Test
    void validationServiceSealCertificateCarriesItsServiceType() throws Exception {
        var document = new FileDocument(resource("sample_signed.pdf").toFile());
        var probe = DSSUtils.createDocumentValidator(document);
        probe.setCertificateVerifier(new CommonCertificateVerifier());
        var signingCertificate = probe.getSignatures().getFirst().getSigningCertificateToken();
        assertNotNull(signingCertificate);

        var service = new TrustServiceStatusAndInformationExtensions.TrustServiceStatusAndInformationExtensionsBuilder()
                .setNames(Map.of("EN", List.of("Test qualified validation service")))
                .setType(QES_VALIDATION)
                .setStatus("http://uri.etsi.org/TrstSvc/TrustedList/Svcstatus/granted")
                .setStartDate(new Date(0))
                .build();
        var provider = new TrustServiceProvider();
        provider.setNames(Map.of("EN", List.of("Test provider")));
        provider.setTerritory("SK");
        var list = new TLInfo(null, null, null, "https://example.test/tl.xml");
        var properties = new TrustProperties(list, provider, new TimeDependentValues<>(List.of(service)));
        var trusted = new TrustedListsCertificateSource();
        trusted.setSummary(new eu.europa.esig.dss.model.tsl.TLValidationJobSummary(List.of(), List.of(list)));
        trusted.setTrustPropertiesByCertificates(Map.of(signingCertificate, List.of(properties)));

        Function<SignedDocumentValidator, Reports> validation = validator -> {
            var verifier = new CommonCertificateVerifier();
            verifier.setTrustedCertSources(trusted);
            validator.setCertificateVerifier(verifier);
            return validator.validateDocument();
        };
        var evidence = new ConversionEvidenceService(validation, List::of).evidence(resource("sample_signed.pdf"))
                .getAsJsonObject("evidence");
        var types = evidence.getAsJsonArray("signatures").get(0).getAsJsonObject().getAsJsonArray("trustServiceTypes");
        assertTrue(types.toString().contains(QES_VALIDATION), types.toString());
    }

    @Test
    void signatureFilenameNamesTheContainerSignatureFile() throws Exception {
        var evidence = evidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", ConversionTestPdfs.samplePdf()))));
        var signature = evidence.getAsJsonArray("signatures").get(0).getAsJsonObject();
        var name = signature.get("signatureFilename").getAsString();
        assertTrue(name.startsWith("META-INF/signatures") && name.endsWith(".xml"), name);
        assertEquals(0, evidence.getAsJsonArray("documentTimestamps").size());

        var pades = evidenceOf("sample_signed.pdf", List.of()).getAsJsonArray("signatures").get(0).getAsJsonObject();
        assertFalse(pades.has("signatureFilename"), pades.toString());
    }

    @Test
    void pdfDocumentTimestampIsListedWithItsRevision() throws Exception {
        var signed = ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false);
        var timestamped = ConversionTestPdfs.documentTimestamp(signed, ContentTimestampTest.authority());
        var path = Files.write(Files.createTempDirectory("evidence").resolve("timestamped.pdf"), timestamped);

        var evidence = new ConversionEvidenceService(plainValidation(), List::of).evidence(path)
                .getAsJsonObject("evidence");

        var signature = evidence.getAsJsonArray("signatures").get(0).getAsJsonObject();
        assertEquals(signed.length, signature.get("signedRevisionLength").getAsLong());
        var timestamps = evidence.getAsJsonArray("documentTimestamps");
        assertEquals(1, timestamps.size(), timestamps.toString());
        var timestamp = timestamps.get(0).getAsJsonObject();
        assertEquals(timestamped.length, timestamp.get("coveredRevisionLength").getAsLong());
        assertEquals("Test TSA", timestamp.get("producerCommonName").getAsString());
        assertNotNull(timestamp.get("id"));
        assertNotNull(timestamp.get("productionTime"));
        assertNotNull(timestamp.get("indication"));
        assertNotNull(timestamp.get("qualification"));

        var nested = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", timestamped), new Entry("b.pdf", ConversionTestPdfs.withText("B")))));
        var inner = dataObject(nested, "zmluva.pdf").getAsJsonObject("evidence");
        assertNotNull(inner, nested.toString());
        var innerTimestamps = inner.getAsJsonArray("documentTimestamps");
        assertEquals(1, innerTimestamps.size(), innerTimestamps.toString());
        assertEquals(timestamped.length, innerTimestamps.get(0).getAsJsonObject().get("coveredRevisionLength").getAsLong());
    }

    /// The app's own PAdES content timestamp: a document timestamp revision before the only
    /// PAdES signature. It is listed with the revision it covers and is none of the signature's
    /// own timestamps (DSS lists only those produced after the signature).
    @Test
    void documentTimestampBeforeTheSignatureIsListedAndIsNotTheSignaturesOwn() throws Exception {
        var timestampedFirst = ConversionTestPdfs.documentTimestamp(ConversionTestPdfs.samplePdf(),
                ContentTimestampTest.authority());
        var signed = ConversionTestPdfs.sign(timestampedFirst, false);
        var path = Files.write(Files.createTempDirectory("evidence").resolve("signed.pdf"), signed);

        var evidence = new ConversionEvidenceService(plainValidation(), List::of).evidence(path)
                .getAsJsonObject("evidence");

        var timestamps = evidence.getAsJsonArray("documentTimestamps");
        assertEquals(1, timestamps.size(), timestamps.toString());
        assertEquals(timestampedFirst.length, timestamps.get(0).getAsJsonObject().get("coveredRevisionLength").getAsLong());
        var signature = evidence.getAsJsonArray("signatures").get(0).getAsJsonObject();
        assertEquals(signed.length, signature.get("signedRevisionLength").getAsLong());
        assertEquals(0, signature.getAsJsonArray("timestamps").size(), signature.toString());
    }

    /// A PDF data object with document timestamps and no PAdES signature keeps its timestamps:
    /// it gets nested evidence without signatures. The container's only PDF stays unsigned.
    @Test
    void pdfDataObjectWithOnlyDocumentTimestampsCarriesNestedEvidence() throws Exception {
        var timestamped = ConversionTestPdfs.documentTimestamp(ConversionTestPdfs.samplePdf(),
                ContentTimestampTest.authority());

        var several = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", timestamped), new Entry("b.pdf", ConversionTestPdfs.withText("B")))));
        var nested = dataObject(several, "zmluva.pdf").getAsJsonObject("evidence");
        assertNotNull(nested, several.toString());
        assertEquals(0, nested.getAsJsonArray("signatures").size());
        var timestamps = nested.getAsJsonArray("documentTimestamps");
        assertEquals(1, timestamps.size(), timestamps.toString());
        assertEquals(timestamped.length, timestamps.get(0).getAsJsonObject().get("coveredRevisionLength").getAsLong());
        assertFalse(dataObject(several, "zmluva.pdf").has("problem"));
        assertFalse(dataObject(several, "b.pdf").has("evidence"));

        var only = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(new Entry("zmluva.pdf", timestamped))));
        assertFalse(only.get("asicDataObjectSigned").getAsBoolean(), only.toString());
        var onlyNested = dataObject(only, "zmluva.pdf").getAsJsonObject("evidence");
        assertNotNull(onlyNested, only.toString());
        assertEquals(0, onlyNested.getAsJsonArray("signatures").size());
        assertEquals(1, onlyNested.getAsJsonArray("documentTimestamps").size());
    }

    /// XAdES content timestamps are listed with the signature that carries them and the data
    /// objects they cover, as DSS's timestamp scopes name them: the same names as the entries
    /// and as the signature scopes (`coveredBy`).
    @Test
    void xadesContentTimestampsNameTheirSignatureAndTheDataObjectsTheyCover() throws Exception {
        var a = ConversionTestPdfs.withText("A");
        var b = ConversionTestPdfs.withText("B");
        var base = ConversionTestContainers.xadesAsice(List.of(new Entry("a.pdf", a), new Entry("dir/b c.pdf", b)));
        var container = ConversionTestContainers.addSignatureCovering(base, List.of("dir/b c.pdf"),
                ContentTimestampTest.authority());

        var evidence = evidenceOfContainer(container);
        var content = evidence.getAsJsonArray("contentTimestamps");
        assertEquals(1, content.size(), content.toString());
        var timestamp = content.get(0).getAsJsonObject();
        assertEquals("ALL_DATA_OBJECTS_TIMESTAMP", timestamp.get("type").getAsString());
        assertEquals("[\"dir/b c.pdf\"]", timestamp.getAsJsonArray("coveredDataObjects").toString());
        assertEquals("Test TSA", timestamp.get("producerCommonName").getAsString());
        assertNotNull(timestamp.get("productionTime"));
        assertNotNull(timestamp.get("indication"));
        var carrier = timestamp.get("signatureId").getAsString();
        var coveredBy = dataObject(evidence.getAsJsonObject("pdf"), "dir/b c.pdf").getAsJsonArray("coveredBy");
        assertEquals(2, coveredBy.size(), coveredBy.toString());
        assertTrue(coveredBy.contains(new com.google.gson.JsonPrimitive(carrier)));
        var aCoveredBy = dataObject(evidence.getAsJsonObject("pdf"), "a.pdf").getAsJsonArray("coveredBy");
        assertFalse(aCoveredBy.contains(new com.google.gson.JsonPrimitive(carrier)), aCoveredBy.toString());
        var carrierFacts = evidence.getAsJsonArray("signatures").asList().stream().map(value -> value.getAsJsonObject())
                .filter(signature -> signature.get("id").getAsString().equals(carrier)).findFirst().orElseThrow();
        assertEquals(0, carrierFacts.getAsJsonArray("timestamps").size(), carrierFacts.toString());

        var individual = evidenceOfContainer(ConversionTestContainers.xadesAsiceWithIndividualTimestamp(
                List.of(new Entry("a.pdf", a), new Entry("dir/b c.pdf", b)), ContentTimestampTest.authority(), "dir/b c.pdf"))
                .getAsJsonArray("contentTimestamps");
        assertEquals(1, individual.size(), individual.toString());
        assertEquals("INDIVIDUAL_DATA_OBJECTS_TIMESTAMP", individual.get(0).getAsJsonObject().get("type").getAsString());
        assertEquals("[\"dir/b c.pdf\"]", individual.get(0).getAsJsonObject().getAsJsonArray("coveredDataObjects").toString());

        var everything = evidenceOfContainer(ConversionTestContainers.xadesAsiceWithContentTimestamp(
                List.of(new Entry("a.pdf", a), new Entry("dir/b c.pdf", b)), ContentTimestampTest.authority()))
                .getAsJsonArray("contentTimestamps");
        assertEquals("[\"a.pdf\",\"dir/b c.pdf\"]",
                everything.get(0).getAsJsonObject().getAsJsonArray("coveredDataObjects").toString());

        assertEquals(0, evidenceOfContainer(base).getAsJsonArray("contentTimestamps").size());
    }
    /// A content timestamp carried as the CAdES signed attribute `id-aa-ets-contentTimestamp`
    /// inside a PAdES signature (DSS `CONTENT_TIMESTAMP`) is listed with its carrier, never left
    /// out: DSS does not count it among the timestamps produced after the signature, and it is
    /// no document timestamp revision. Nested in a container's PDF it is listed the same way.
    @Test
    void padesContentTimestampSignedAttributeIsListed() throws Exception {
        var signed = ConversionTestPdfs.signWithContentTimestamp(ConversionTestPdfs.samplePdf(),
                ContentTimestampTest.authority());
        var path = Files.write(Files.createTempDirectory("evidence").resolve("signed.pdf"), signed);

        var evidence = new ConversionEvidenceService(plainValidation(), List::of).evidence(path)
                .getAsJsonObject("evidence");

        var content = evidence.getAsJsonArray("contentTimestamps");
        assertEquals(1, content.size(), content.toString());
        var timestamp = content.get(0).getAsJsonObject();
        assertEquals("CONTENT_TIMESTAMP", timestamp.get("type").getAsString());
        var signature = evidence.getAsJsonArray("signatures").get(0).getAsJsonObject();
        assertEquals(signature.get("id").getAsString(), timestamp.get("signatureId").getAsString());
        assertEquals("Test TSA", timestamp.get("producerCommonName").getAsString());
        assertNotNull(timestamp.get("productionTime"));
        assertNotNull(timestamp.get("indication"));
        assertNotNull(timestamp.get("coveredDataObjects"));
        assertEquals(0, signature.getAsJsonArray("timestamps").size(), signature.toString());
        assertEquals(0, evidence.getAsJsonArray("documentTimestamps").size());

        var container = pdfEvidenceOfContainer(ConversionTestContainers.xadesAsice(List.of(
                new Entry("zmluva.pdf", signed), new Entry("b.pdf", ConversionTestPdfs.withText("B")))));
        var nested = dataObject(container, "zmluva.pdf").getAsJsonObject("evidence");
        assertNotNull(nested, container.toString());
        var nestedContent = nested.getAsJsonArray("contentTimestamps");
        assertEquals(1, nestedContent.size(), nestedContent.toString());
        assertEquals("CONTENT_TIMESTAMP", nestedContent.get(0).getAsJsonObject().get("type").getAsString());
    }

    /// The CAdES signed attribute `id-aa-ets-contentTimestamp` of an ASiC-E CAdES signature is
    /// listed with the data objects DSS's timestamp scopes name, as for XAdES.
    @Test
    void cadesContainerContentTimestampNamesTheDataObjectsItCovers() throws Exception {
        var a = ConversionTestPdfs.withText("A");
        var b = ConversionTestPdfs.withText("B");
        var evidence = evidenceOfContainer(ConversionTestContainers.cadesAsiceWithContentTimestamp(
                List.of(new Entry("a.pdf", a), new Entry("dir/b c.pdf", b)), ContentTimestampTest.authority()));
        var content = evidence.getAsJsonArray("contentTimestamps");
        assertEquals(1, content.size(), content.toString());
        var timestamp = content.get(0).getAsJsonObject();
        assertEquals("CONTENT_TIMESTAMP", timestamp.get("type").getAsString());
        // The CMS signs the ASiC manifest, which names the files: DSS scopes it as all three.
        assertEquals("[\"META-INF/ASiCManifest001.xml\",\"a.pdf\",\"dir/b c.pdf\"]",
                timestamp.getAsJsonArray("coveredDataObjects").toString());
        var carrier = timestamp.get("signatureId").getAsString();
        var signature = evidence.getAsJsonArray("signatures").get(0).getAsJsonObject();
        assertEquals(carrier, signature.get("id").getAsString());
        assertEquals("META-INF/signature001.p7s", signature.get("signatureFilename").getAsString());
        assertEquals(0, signature.getAsJsonArray("timestamps").size(), signature.toString());
        assertEquals("Test TSA", timestamp.get("producerCommonName").getAsString());
        for (var name : List.of("a.pdf", "dir/b c.pdf")) {
            var coveredBy = dataObject(evidence.getAsJsonObject("pdf"), name).getAsJsonArray("coveredBy");
            assertTrue(coveredBy.contains(new com.google.gson.JsonPrimitive(carrier)), coveredBy.toString());
        }
    }
}
