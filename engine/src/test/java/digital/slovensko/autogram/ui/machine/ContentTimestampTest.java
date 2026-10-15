package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import digital.slovensko.autogram.core.SigningKey;
import digital.slovensko.autogram.core.SigningParameters;
import digital.slovensko.autogram.core.errors.SigningParametersException;
import digital.slovensko.autogram.ui.machine.v2.MachineV2RequestValidator;
import eu.europa.esig.dss.enumerations.MimeTypeEnum;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.enumerations.TimestampType;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.spi.x509.tsp.KeyEntityTSPSource;
import eu.europa.esig.dss.spi.x509.tsp.TSPSource;
import eu.europa.esig.dss.token.Pkcs12SignatureToken;
import eu.europa.esig.dss.validation.SignedDocumentValidator;
import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.asn1.x509.BasicConstraints;
import org.bouncycastle.asn1.x509.ExtendedKeyUsage;
import org.bouncycastle.asn1.x509.Extension;
import org.bouncycastle.asn1.x509.KeyPurposeId;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.util.Date;
import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/// The opt-in timestamp inside the signed data (§ 23 ods. 1 písm. b) zákona č. 305/2013 Z. z.):
/// an AllDataObjectsTimeStamp in XAdES, a document timestamp before a PAdES signature. Signed
/// with the test keystore and an in-process authority, so nothing reaches the network.
///
/// The test keystore's certificate has expired, so DSS classifies a timestamped XAdES signature
/// as Baseline B (requirement (o)); the tests assert timestamp types, never the XAdES format.
class ContentTimestampTest {
    private static final String TSA = "http://tsa.example.test/qts";

    @TempDir
    Path temporaryDirectory;

    @Test
    void xadesContainerCarriesAnAllDataObjectsTimestampWithoutASignatureTimestampAtBaselineB() throws Exception {
        var signed = sign("dokument.pdf", pdf(), SignatureLevel.XAdES_BASELINE_B, true, List.of());

        assertEquals(List.of(TimestampType.ALL_DATA_OBJECTS_TIMESTAMP), timestampTypes(signed));
        var timestamps = structuralTimestamps(signed);
        assertEquals(1, timestamps.size());
        assertEquals("ALL_DATA_OBJECTS_TIMESTAMP", timestamps.getFirst().get("type").getAsString());
        assertTrue(timestamps.getFirst().get("inSignedData").getAsBoolean());
        assertTrue(timestamps.getFirst().get("cryptographicIntegrity").getAsBoolean());
        assertTrue(signatureXml(signed).contains("<xades:SignedDataObjectProperties>"));
    }

    @Test
    void xadesContainerAtBaselineTKeepsItsSignatureTimestampBesideTheContentTimestamp() throws Exception {
        var signed = sign("dokument.pdf", pdf(), SignatureLevel.XAdES_BASELINE_T, true, List.of());

        assertEquals(List.of(TimestampType.ALL_DATA_OBJECTS_TIMESTAMP, TimestampType.SIGNATURE_TIMESTAMP),
                timestampTypes(signed));
        var timestamps = structuralTimestamps(signed);
        assertTrue(timestamps.get(0).get("inSignedData").getAsBoolean());
        assertFalse(timestamps.get(1).get("inSignedData").getAsBoolean());
        assertEquals("SIGNATURE_TIMESTAMP", timestamps.get(1).get("type").getAsString());
    }

    @Test
    void theContentTimestampCoversEveryDataObjectOfTheContainer() throws Exception {
        var xdcf = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><XMLDataContainer xmlns=\"http://data.gov.sk/def/container/xmldatacontainer+xml/1.1\"/>"
                .getBytes(java.nio.charset.StandardCharsets.UTF_8);
        var signed = sign("dokument.pdf", pdf(), SignatureLevel.XAdES_BASELINE_B, true,
                List.of(new MachineSigningService.AttachmentContent("dokument.xml.xdcf", xdcf)));

        var validator = validator(signed);
        var reports = validator.validateDocument();
        var timestamp = reports.getDiagnosticData().getTimestampList().stream()
                .filter(candidate -> candidate.getType() == TimestampType.ALL_DATA_OBJECTS_TIMESTAMP)
                .findFirst().orElseThrow();
        assertTrue(timestamp.isMessageImprintDataIntact());
        assertEquals(2, timestamp.getTimestampedObjects().size());
    }

    @Test
    void pdfIsTimestampedInARevisionBeforeTheSignature() throws Exception {
        var signed = sign("dokument.pdf", pdf(), SignatureLevel.PAdES_BASELINE_B, true, List.of());

        var validator = validator(signed);
        assertEquals(List.of(TimestampType.DOCUMENT_TIMESTAMP), validator.getDetachedTimestamps().stream()
                .map(timestamp -> timestamp.getTimeStampType()).toList());
        var signatures = new MachineInspectionService().inspect(signed).getAsJsonArray("signatures");
        assertEquals(1, signatures.size());
        assertEquals("PAdES_BASELINE_B", signatures.get(0).getAsJsonObject().get("format").getAsString());
        var timestamps = structuralTimestamps(signed);
        assertEquals(1, timestamps.size());
        assertEquals("DOCUMENT_TIMESTAMP", timestamps.getFirst().get("type").getAsString());
        assertTrue(timestamps.getFirst().get("inSignedData").getAsBoolean());
        assertTrue(timestamps.getFirst().get("cryptographicIntegrity").getAsBoolean());
    }

    @Test
    void pdfAtBaselineTListsTheDocumentTimestampFirstAndItsSignatureTimestampAfter() throws Exception {
        var signed = sign("dokument.pdf", pdf(), SignatureLevel.PAdES_BASELINE_T, true, List.of());

        var timestamps = structuralTimestamps(signed);
        assertEquals(List.of("DOCUMENT_TIMESTAMP", "SIGNATURE_TIMESTAMP"),
                timestamps.stream().map(timestamp -> timestamp.get("type").getAsString()).toList());
        assertEquals(List.of(true, false),
                timestamps.stream().map(timestamp -> timestamp.get("inSignedData").getAsBoolean()).toList());
        assertEquals("PAdES_BASELINE_T", new MachineInspectionService().inspect(signed).getAsJsonArray("signatures")
                .get(0).getAsJsonObject().get("format").getAsString());
    }

    /// A document timestamp added after a signature covers that signature: it is no timestamp of
    /// the signature's data.
    @Test
    void aDocumentTimestampAfterTheSignatureIsNotInItsSignedData() throws Exception {
        var signed = sign("dokument.pdf", pdf(), SignatureLevel.PAdES_BASELINE_B, false, List.of());
        var service = new eu.europa.esig.dss.pades.signature.PAdESService(new CommonCertificateVerifier());
        service.setTspSource(authority());
        var timestamped = service.timestamp(new InMemoryDocument(signed, "dokument.pdf", MimeTypeEnum.PDF),
                new eu.europa.esig.dss.pades.PAdESTimestampParameters());

        var timestamps = structuralTimestamps(timestamped.openStream().readAllBytes());
        assertTrue(timestamps.stream().noneMatch(timestamp -> timestamp.get("inSignedData").getAsBoolean()));
    }

    @Test
    void trustedValidationNamesTheTypeOfEveryTimestamp() throws Exception {
        var pades = sign("dokument.pdf", pdf(), SignatureLevel.PAdES_BASELINE_T, true, List.of());
        var xades = sign("dokument.pdf", pdf(), SignatureLevel.XAdES_BASELINE_T, true, List.of());
        var service = MachineInspectionService.withValidatorReportReader(validator -> {
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            return validator.validateDocument().getSimpleReport();
        });

        for (var signed : List.of(pades, xades)) {
            var path = Files.write(temporaryDirectory.resolve(signed == pades ? "p.pdf" : "x.asice"), signed);
            var timestamps = service.inspect(path).getAsJsonArray("signatures").get(0).getAsJsonObject()
                    .getAsJsonArray("timestamps").asList().stream().map(value -> value.getAsJsonObject()).toList();
            assertEquals(2, timestamps.size(), timestamps.toString());
            assertTrue(timestamps.get(0).get("inSignedData").getAsBoolean(), timestamps.toString());
            assertFalse(timestamps.get(1).get("inSignedData").getAsBoolean(), timestamps.toString());
            assertEquals("SIGNATURE_TIMESTAMP", timestamps.get(1).get("type").getAsString());
            assertNotNull(timestamps.get(0).get("productionTime").getAsString());
        }
    }

    @Test
    void withoutTheFlagNoTimestampIsAddedToTheSignedData() throws Exception {
        var signed = sign("dokument.pdf", pdf(), SignatureLevel.PAdES_BASELINE_T, false, List.of());

        var timestamps = structuralTimestamps(signed);
        assertEquals(1, timestamps.size());
        assertFalse(timestamps.getFirst().get("inSignedData").getAsBoolean());
        assertTrue(validator(signed).getDetachedTimestamps().isEmpty());
    }

    @Test
    void outputCheckRequiresTheRequestedContentTimestamp() throws Exception {
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService());
        var with = sign("dokument.pdf", pdf(), SignatureLevel.PAdES_BASELINE_T, true, List.of());
        var without = sign("dokument.pdf", pdf(), SignatureLevel.PAdES_BASELINE_T, false, List.of());

        assertNull(validator.contentTimestampFailure(with, Set.of()));
        assertEquals("OUTPUT_VALIDATION_FAILED", validator.contentTimestampFailure(without, Set.of()));
        assertNull(validator.validationFailure(with, Set.of(), false, "PAdES_BASELINE_T"));
    }

    /// Baseline T needs a signature timestamp; a content timestamp alone never passes for one.
    @Test
    void aContentTimestampAloneIsNoSignatureTimestamp() throws Exception {
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService());
        var signed = sign("dokument.pdf", pdf(), SignatureLevel.PAdES_BASELINE_B, true, List.of());

        assertNull(validator.validationFailure(signed, Set.of(), false, "PAdES_BASELINE_B"));
        assertNull(validator.contentTimestampFailure(signed, Set.of()));
        assertEquals("OUTPUT_VALIDATION_FAILED", validator.validationFailure(signed, Set.of(), false));
    }

    @Test
    void anExistingContainerOrARecordGetsNoContentTimestamp() throws Exception {
        var container = new InMemoryDocument(TestContainers.signedXadesContainer(java.util.Map.of("a.pdf", pdf())),
                "kontajner.asice", MimeTypeEnum.ASICE);
        var existing = SigningParameters.buildForExistingASiC(container, SignatureLevel.XAdES_BASELINE_T, false, false,
                authority());
        assertThrows(SigningParametersException.class, () -> existing.setContentTimestampSource(authority()));

        var record = new InMemoryDocument("<XMLDataContainer/>".getBytes(), "zaznam.xml.xdcf",
                digital.slovensko.autogram.core.AutogramMimeType.XML_DATACONTAINER);
        var recordParameters = SigningParameters.buildForPlainRecordXdc(record, SignatureLevel.XAdES_BASELINE_B, null);
        assertThrows(SigningParametersException.class, () -> recordParameters.setContentTimestampSource(authority()));
    }

    @Test
    void aBaselineBRequestAfterABaselineTOneSignsWithoutASignatureTimestamp() throws Exception {
        var settings = new MachineSettings(true);
        settings.answerTimestampsWith(authority());
        settings.setSignatureLevel(SignatureLevel.PAdES_BASELINE_T);
        settings.setTsaServer(TSA, new eu.europa.esig.dss.service.http.commons.TimestampDataLoader());
        // The next request is Baseline B without a content timestamp, as the session factory leaves it.
        settings.setTsaServer(null, new eu.europa.esig.dss.service.http.commons.TimestampDataLoader());
        settings.setSignatureLevel(SignatureLevel.PAdES_BASELINE_B);

        var signed = signWith(settings, "dokument.pdf", pdf(), List.of());

        assertEquals("PAdES_BASELINE_B", new MachineInspectionService().inspect(signed).getAsJsonArray("signatures")
                .get(0).getAsJsonObject().get("format").getAsString());
    }

    // Protocol

    @Test
    void protocolV1ReadsTheContentFlag() {
        var sign = MachineCliApp.requiredSignRequest(signPayload("""
                {"required": false, "servers": ["http://tsa.belgium.be/connect"], "content": true}""",
                "PAdES_BASELINE_B"));

        assertTrue(sign.timestamp().content());
        assertFalse(sign.timestamp().required());
    }

    @Test
    void protocolV1RefusesANonBooleanContentFlag() {
        var payload = signPayload("""
                {"required": false, "servers": [], "content": "yes"}""", "PAdES_BASELINE_B");

        assertEquals("PROTOCOL_INVALID_REQUEST", assertThrows(MachineProtocolException.class,
                () -> MachineCliApp.requiredSignRequest(payload)).getMessage());
    }

    @Test
    void aContentTimestampNeedsAQualifiedAuthority() {
        var files = List.of(new MachineFile("1", "/tmp/a.pdf", "/tmp/b.pdf"));
        var request = new SignRequest("driver", "serial", "1234".toCharArray(), "PAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of(), null, true), files);

        assertEquals("TSA_REQUIRED", assertThrows(MachineProtocolException.class,
                () -> MachineRequestValidator.validateSign(request)).getMessage());
    }

    @Test
    void protocolV2AcceptsAuthoritiesForBaselineBOnlyWithAContentTimestamp() {
        var withContent = MachineV2RequestValidator.validateSign(signPayload("""
                {"required": false, "servers": ["http://tsa.belgium.be/connect"], "content": true}""",
                "PAdES_BASELINE_B"));
        assertTrue(withContent.timestamp().content());

        assertEquals("PROTOCOL_INVALID_REQUEST", assertThrows(MachineProtocolException.class,
                () -> MachineV2RequestValidator.validateSign(signPayload("""
                        {"required": false, "servers": ["http://tsa.belgium.be/connect"]}""", "PAdES_BASELINE_B")))
                .getMessage());
        assertEquals("PROTOCOL_INVALID_REQUEST", assertThrows(MachineProtocolException.class,
                () -> MachineV2RequestValidator.validateSign(signPayload("""
                        {"required": false, "servers": [], "content": true}""", "PAdES_BASELINE_B")))
                .getMessage());
        assertFalse(MachineV2RequestValidator.validateSign(signPayload("""
                {"required": true, "servers": ["http://tsa.belgium.be/connect"]}""", "PAdES_BASELINE_T"))
                .timestamp().content());
    }

    // Helpers

    private byte[] sign(String name, byte[] source, SignatureLevel level, boolean contentTimestamp,
            List<MachineSigningService.AttachmentContent> attachments) throws Exception {
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(level);
        settings.answerTimestampsWith(authority());
        if (level.name().endsWith("_T") || contentTimestamp) {
            settings.setTsaServer(TSA, new eu.europa.esig.dss.service.http.commons.TimestampDataLoader());
        }
        settings.setContentTimestamp(contentTimestamp);
        return signWith(settings, name, source, attachments);
    }

    private static byte[] signWith(MachineSettings settings, String name, byte[] source,
            List<MachineSigningService.AttachmentContent> attachments) throws Exception {
        var retained = new MemoryFile();
        var responder = new MachineFileResponder(retained, () -> { });
        var job = MachineSigningService.DefaultSigningSession.signingJob(source, "/tmp/" + name, responder, settings,
                null, attachments);
        try (var token = token()) {
            job.signWithKeyAndRespond(new SigningKey(token, token.getKeys().get(0)));
        }
        return retained.readAll();
    }

    private static Pkcs12SignatureToken token() throws Exception {
        return new Pkcs12SignatureToken(TestContainers.resourcePath("test.keystore").toString(),
                new KeyStore.PasswordProtection("".toCharArray()));
    }

    private static byte[] pdf() throws Exception {
        return TestContainers.resource("sample.pdf");
    }

    private static SignedDocumentValidator validator(byte[] content) {
        var validator = SignedDocumentValidator.fromDocument(new InMemoryDocument(content));
        validator.setCertificateVerifier(new CommonCertificateVerifier());
        return validator;
    }

    private static List<TimestampType> timestampTypes(byte[] signed) {
        return validator(signed).getSignatures().getFirst().getAllTimestamps().stream()
                .map(timestamp -> timestamp.getTimeStampType()).toList();
    }

    private static List<JsonObject> structuralTimestamps(byte[] signed) {
        return new MachineInspectionService().inspect(signed).getAsJsonArray("signatures").get(0).getAsJsonObject()
                .getAsJsonArray("timestamps").asList().stream().map(value -> value.getAsJsonObject()).toList();
    }

    private static String signatureXml(byte[] container) throws Exception {
        try (var zip = new java.util.zip.ZipInputStream(new java.io.ByteArrayInputStream(container))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                if (entry.getName().startsWith("META-INF/signatures")) {
                    return new String(zip.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
                }
            }
        }
        throw new AssertionError("No signature in the container");
    }

    private static JsonObject signPayload(String timestamp, String level) {
        return JsonParser.parseString("""
                {"driver": "d", "certificateSerial": "s", "pin": "1234", "signatureLevel": "%s",
                 "timestamp": %s,
                 "files": [{"id": "1", "source": "/tmp/a.pdf", "target": "/tmp/b.pdf"}]}""".formatted(level, timestamp))
                .getAsJsonObject();
    }

    private static TSPSource authority;

    /// A timestamp unit of its own: BouncyCastle signs a token only with a certificate whose
    /// critical extended key usage is timeStamping, which the test keystore's is not.
    static synchronized TSPSource authority() throws Exception {
        if (authority == null) {
            var generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            var keys = generator.generateKeyPair();
            var name = new X500Name("CN=Test TSA,C=SK");
            var now = System.currentTimeMillis();
            var builder = new JcaX509v3CertificateBuilder(name, BigInteger.valueOf(now), new Date(now - 86_400_000L),
                    new Date(now + 86_400_000L * 365), name, keys.getPublic());
            builder.addExtension(Extension.extendedKeyUsage, true, new ExtendedKeyUsage(KeyPurposeId.id_kp_timeStamping));
            builder.addExtension(Extension.basicConstraints, true, new BasicConstraints(false));
            var certificate = new JcaX509CertificateConverter().getCertificate(
                    builder.build(new JcaContentSignerBuilder("SHA256withRSA").build(keys.getPrivate())));
            var source = new KeyEntityTSPSource(keys.getPrivate(), certificate, List.of(certificate));
            source.setTsaPolicy("1.2.3.4");
            authority = source;
        }
        return authority;
    }

    private static final class MemoryFile implements MachineSigningFileSystem.RetainedFile {
        private byte[] content = new byte[0];

        @Override
        public byte[] readAll() {
            return content.clone();
        }

        @Override
        public void replaceContent(byte[] content) {
            this.content = content.clone();
        }

        @Override
        public void close() {
        }
    }
}
