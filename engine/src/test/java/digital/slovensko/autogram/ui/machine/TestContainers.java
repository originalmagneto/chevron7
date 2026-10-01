package digital.slovensko.autogram.ui.machine;

import eu.europa.esig.dss.asic.xades.ASiCWithXAdESSignatureParameters;
import eu.europa.esig.dss.asic.xades.signature.ASiCWithXAdESService;
import eu.europa.esig.dss.alert.LogOnStatusAlert;
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
public final class TestContainers {
    private TestContainers() {
    }

    public static Path resourcePath(String name) {
        return Path.of(Objects.requireNonNull(TestContainers.class
                .getResource("/digital/slovensko/autogram/" + name)).getFile());
    }

    public static byte[] resource(String name) throws IOException {
        return Files.readAllBytes(resourcePath(name));
    }

    /// One XAdES Baseline B signature over every given document, in insertion order.
    public static byte[] signedXadesContainer(Map<String, byte[]> documents) throws IOException {
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
            // The test keystore's certificate has expired; production signs the same way and
            // filters expired certificates on the UI level.
            var verifier = new CommonCertificateVerifier();
            verifier.setAlertOnExpiredCertificate(new LogOnStatusAlert());
            var service = new ASiCWithXAdESService(verifier);
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
