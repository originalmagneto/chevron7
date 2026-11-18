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
}
