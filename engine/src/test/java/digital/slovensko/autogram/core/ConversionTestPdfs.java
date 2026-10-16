package digital.slovensko.autogram.core;

import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.pades.PAdESSignatureParameters;
import eu.europa.esig.dss.pades.SignatureFieldParameters;
import eu.europa.esig.dss.pades.SignatureImageParameters;
import eu.europa.esig.dss.pades.SignatureImageTextParameters;
import eu.europa.esig.dss.pades.signature.PAdESService;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.token.Pkcs12SignatureToken;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.font.PDType1Font;
import org.apache.pdfbox.pdmodel.font.Standard14Fonts;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotationText;

import java.io.ByteArrayOutputStream;
import java.security.KeyStore;
import java.util.Objects;

/// PDFs for the E→E conversion tests: signed with the engine's test key, optionally with a
/// visible stamp, and changed after signing.
public final class ConversionTestPdfs {
    private ConversionTestPdfs() {
    }

    public static byte[] samplePdf() throws Exception {
        try (var stream = Objects.requireNonNull(ConversionTestPdfs.class
                .getResourceAsStream("/digital/slovensko/autogram/sample.pdf"))) {
            return stream.readAllBytes();
        }
    }

    public static byte[] sign(byte[] pdf, boolean visible) throws Exception {
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(ConversionTestPdfs.class.getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        var key = token.getKeys().get(0);
        var parameters = new PAdESSignatureParameters();
        parameters.setSignatureLevel(SignatureLevel.PAdES_BASELINE_B);
        parameters.setSigningCertificate(key.getCertificate());
        parameters.setCertificateChain(key.getCertificateChain());
        if (visible) {
            var image = new SignatureImageParameters();
            var text = new SignatureImageTextParameters();
            text.setText("Podpísal: Test");
            image.setTextParameters(text);
            var field = new SignatureFieldParameters();
            field.setOriginX(50);
            field.setOriginY(50);
            field.setWidth(200);
            field.setHeight(60);
            image.setFieldParameters(field);
            parameters.setImageParameters(image);
        }
        var verifier = new CommonCertificateVerifier();
        // The engine's test key expired in 2024, as in SigningJob's own verifier setup.
        verifier.setAlertOnExpiredCertificate(new eu.europa.esig.dss.alert.LogOnStatusAlert());
        var service = new PAdESService(verifier);
        DSSDocument document = new InMemoryDocument(pdf, "document.pdf");
        var toSign = service.getDataToSign(document, parameters);
        var value = token.sign(toSign, parameters.getDigestAlgorithm(), key);
        try (var signed = service.signDocument(document, parameters, value).openStream()) {
            return signed.readAllBytes();
        } catch (java.io.IOException exception) {
            throw new java.io.UncheckedIOException(exception);
        }
    }

    /// Adds a sticky note to page 1 as an incremental update, after any signature.
    public static byte[] annotateIncrementally(byte[] pdf) throws Exception {
        try (PDDocument document = Loader.loadPDF(pdf)) {
            var page = document.getPage(0);
            var note = new PDAnnotationText();
            note.setRectangle(new PDRectangle(10, 10, 20, 20));
            note.setContents("Neskoršia poznámka");
            page.getAnnotations().add(note);
            page.getCOSObject().setNeedToBeUpdated(true);
            var output = new ByteArrayOutputStream();
            document.saveIncremental(output);
            return output.toByteArray();
        }
    }

    public static byte[] withText(String text) throws Exception {
        try (var document = new PDDocument()) {
            var page = new PDPage(PDRectangle.A4);
            document.addPage(page);
            try (var content = new PDPageContentStream(document, page)) {
                content.beginText();
                content.setFont(new PDType1Font(Standard14Fonts.FontName.HELVETICA), 12);
                content.newLineAtOffset(72, 720);
                content.showText(text);
                content.endText();
            }
            var output = new ByteArrayOutputStream();
            document.save(output);
            return output.toByteArray();
        }
    }
}
