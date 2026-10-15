package digital.slovensko.autogram;

import digital.slovensko.autogram.ui.machine.MachineInspectionService;
import eu.europa.esig.dss.alert.LogOnStatusAlert;
import eu.europa.esig.dss.asic.xades.ASiCWithXAdESSignatureParameters;
import eu.europa.esig.dss.asic.xades.signature.ASiCWithXAdESService;
import eu.europa.esig.dss.enumerations.ASiCContainerType;
import eu.europa.esig.dss.enumerations.DigestAlgorithm;
import eu.europa.esig.dss.enumerations.MimeTypeEnum;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.enumerations.SignaturePackaging;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.pades.PAdESSignatureParameters;
import eu.europa.esig.dss.pades.PAdESTimestampParameters;
import eu.europa.esig.dss.pades.signature.PAdESService;
import eu.europa.esig.dss.service.tsp.OnlineTSPSource;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.spi.x509.tsp.TSPSource;
import eu.europa.esig.dss.token.Pkcs12SignatureToken;
import eu.europa.esig.dss.validation.SignedDocumentValidator;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.util.List;
import java.util.Objects;

/// Step 0 spike, run by hand with AUTOGRAM_SPIKE_OUT set: signs with a real qualified TSA.
class ContentTimestampSpikeTest {
    private static final String TSA = System.getenv().getOrDefault("AUTOGRAM_SPIKE_TSA",
            "http://timestamp.sectigo.com/qualified");

    @Test
    void spike() throws Exception {
        var out = System.getenv("AUTOGRAM_SPIKE_OUT");
        Assumptions.assumeTrue(out != null);
        var dir = Path.of(out);
        Files.createDirectories(dir);
        var pdf = Files.readAllBytes(Path.of(Objects.requireNonNull(
                getClass().getResource("/digital/slovensko/autogram/sample.pdf")).toURI()));
        TSPSource tsp = new OnlineTSPSource(TSA);

        try (var token = new Pkcs12SignatureToken(Path.of(Objects.requireNonNull(
                getClass().getResource("/digital/slovensko/autogram/test.keystore")).toURI()).toString(),
                new KeyStore.PasswordProtection("".toCharArray()))) {
            var key = token.getKeys().get(0);
            var verifier = new CommonCertificateVerifier();
            verifier.setAlertOnExpiredCertificate(new LogOnStatusAlert());

            // 1. ASiC-E XAdES Baseline T with AllDataObjectsTimeStamp.
            {
                var service = new ASiCWithXAdESService(verifier);
                service.setTspSource(tsp);
                var p = new ASiCWithXAdESSignatureParameters();
                p.aSiC().setContainerType(ASiCContainerType.ASiC_E);
                p.setSignatureLevel(SignatureLevel.XAdES_BASELINE_T);
                p.setSignaturePackaging(SignaturePackaging.ENVELOPING);
                p.setDigestAlgorithm(DigestAlgorithm.SHA256);
                p.setSigningCertificate(key.getCertificate());
                p.setCertificateChain(key.getCertificateChain());
                p.setAddX509SubjectName(true);
                List<DSSDocument> docs = List.of(new InMemoryDocument(pdf, "podanie.pdf", MimeTypeEnum.PDF));
                var contentTimestamp = service.getContentTimestamp(docs, p);
                p.setContentTimestamps(List.of(contentTimestamp));
                var toSign = service.getDataToSign(docs, p);
                var value = token.sign(toSign, DigestAlgorithm.SHA256, key);
                var signed = service.signDocument(docs, p, value);
                signed.save(dir.resolve("xades-content-ts.asice").toString());
            }

            // 2. PAdES Baseline T with a CMS content-time-stamp attribute.
            {
                var service = new PAdESService(verifier);
                service.setTspSource(tsp);
                var p = new PAdESSignatureParameters();
                p.setSignatureLevel(SignatureLevel.PAdES_BASELINE_T);
                p.setDigestAlgorithm(DigestAlgorithm.SHA256);
                p.setSigningCertificate(key.getCertificate());
                p.setCertificateChain(key.getCertificateChain());
                p.setContentSize(9472 * 3);
                p.getContentTimestampParameters().setDigestAlgorithm(DigestAlgorithm.SHA256);
                var doc = new InMemoryDocument(pdf, "podanie.pdf", MimeTypeEnum.PDF);
                var contentTimestamp = service.getContentTimestamp(doc, p);
                p.setContentTimestamps(List.of(contentTimestamp));
                var toSign = service.getDataToSign(doc, p);
                var value = token.sign(toSign, DigestAlgorithm.SHA256, key);
                var signed = service.signDocument(doc, p, value);
                signed.save(dir.resolve("pades-content-ts.pdf").toString());
            }

            // 3. PAdES: a document timestamp first, then the Baseline T signature.
            {
                var service = new PAdESService(verifier);
                service.setTspSource(tsp);
                var doc = new InMemoryDocument(pdf, "podanie.pdf", MimeTypeEnum.PDF);
                var tsParams = new PAdESTimestampParameters();
                tsParams.setDigestAlgorithm(DigestAlgorithm.SHA256);
                var timestamped = service.timestamp(doc, tsParams);
                var p = new PAdESSignatureParameters();
                p.setSignatureLevel(SignatureLevel.PAdES_BASELINE_T);
                p.setDigestAlgorithm(DigestAlgorithm.SHA256);
                p.setSigningCertificate(key.getCertificate());
                p.setCertificateChain(key.getCertificateChain());
                p.setContentSize(9472 * 2);
                var toSign = service.getDataToSign(timestamped, p);
                var value = token.sign(toSign, DigestAlgorithm.SHA256, key);
                var signed = service.signDocument(timestamped, p, value);
                signed.save(dir.resolve("pades-doc-ts-then-signature.pdf").toString());
            }
        }

        for (var name : List.of("xades-content-ts.asice", "pades-content-ts.pdf", "pades-doc-ts-then-signature.pdf")) {
            var file = dir.resolve(name);
            var validator = SignedDocumentValidator.fromDocument(new eu.europa.esig.dss.model.FileDocument(file.toFile()));
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            var reports = validator.validateDocument();
            var diag = reports.getDiagnosticData();
            System.out.println("=== " + name);
            for (var ts : diag.getTimestampList()) {
                System.out.println("  timestamp " + ts.getId() + " type=" + ts.getType()
                        + " intact=" + ts.isMessageImprintDataIntact()
                        + " found=" + ts.isMessageImprintDataFound()
                        + " sigIntact=" + ts.isSignatureIntact()
                        + " time=" + ts.getProductionTime()
                        + " covers=" + ts.getTimestampedObjects().stream()
                                .map(o -> o.getCategory() + ":" + o.getToken().getId()).toList());
            }
            for (var sig : diag.getSignatures()) {
                System.out.println("  signature " + sig.getId() + " format=" + sig.getSignatureFormat()
                        + " intact=" + sig.isSignatureIntact()
                        + " content=" + sig.getTimestampListByType(eu.europa.esig.dss.enumerations.TimestampType.ALL_DATA_OBJECTS_TIMESTAMP).size()
                        + "/" + sig.getTimestampListByType(eu.europa.esig.dss.enumerations.TimestampType.CONTENT_TIMESTAMP).size()
                        + " sigTs=" + sig.getTimestampListByType(eu.europa.esig.dss.enumerations.TimestampType.SIGNATURE_TIMESTAMP).size());
            }
            var sv = SignedDocumentValidator.fromDocument(new eu.europa.esig.dss.model.FileDocument(file.toFile()));
            sv.setCertificateVerifier(new CommonCertificateVerifier());
            for (var adv : sv.getSignatures()) {
                System.out.println("  adv content=" + adv.getContentTimestamps().stream().map(t -> t.getTimeStampType()).toList()
                        + " sig=" + adv.getSignatureTimestamps().stream().map(t -> t.getTimeStampType()).toList()
                        + " doc=" + adv.getDocumentTimestamps().stream().map(t -> t.getTimeStampType()).toList()
                        + " all=" + adv.getAllTimestamps().stream().map(t -> t.getTimeStampType()).toList());
            }
            System.out.println("  detached=" + sv.getDetachedTimestamps().stream().map(t -> t.getTimeStampType()).toList());
            System.out.println("  structural " + new MachineInspectionService().inspect(file));
            var trustedOut = dir.resolve(name + ".validate.json");
            Files.writeString(trustedOut, MachineInspectionService.forTrustedValidation().inspect(file).toString());
            System.out.println("  trusted -> " + trustedOut);
        }
    }
}
