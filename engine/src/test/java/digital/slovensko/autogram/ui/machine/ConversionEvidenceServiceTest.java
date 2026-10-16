package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonObject;
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
