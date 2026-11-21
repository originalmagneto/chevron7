package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonArray;
import digital.slovensko.autogram.core.ConversionTestPdfs;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSArray;
import org.apache.pdfbox.cos.COSBase;
import org.apache.pdfbox.cos.COSDictionary;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.cos.COSStream;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDDocumentNameDictionary;
import org.apache.pdfbox.pdmodel.PDEmbeddedFilesNameTreeNode;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.common.filespecification.PDComplexFileSpecification;
import org.apache.pdfbox.pdmodel.common.filespecification.PDEmbeddedFile;
import org.apache.pdfbox.pdmodel.font.PDType1Font;
import org.apache.pdfbox.pdmodel.font.Standard14Fonts;
import org.apache.pdfbox.pdmodel.interactive.action.PDActionJavaScript;
import org.apache.pdfbox.text.PDFTextStripper;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/// Changes appended to a PDF after its last PAdES signature, each as an incremental update that
/// leaves the signed bytes alone. A guaranteed conversion (E→E) may only go on when
/// `changesAfterLastSignature` names such a change, so every attack here must be reported, and
/// the extension data a validator legitimately appends (a document timestamp, certificates in the
/// `/DSS` store) must not be.
///
/// The cases follow the classes of change other PDF signature validators test for (a page's
/// content rewritten under its own object number, an object reached through `/DSS` that is really
/// page content, a page relabelled as a signature dictionary). Twelve pages, because a validator
/// that compares rendered pages usually stops after the first ten.
///
/// DSS 6.5.1 alone reports all of them but three: the page relabelled as a signature, the changed
/// document information and the added XMP metadata. `PdfPostSignatureChanges` reports those.
class PostSignatureChangeAttackTest {
    private static final int PAGES = 12;
    private static final int LAST = PAGES - 1;
    private static final COSName DSS = COSName.getPDFName("DSS");
    private static byte[] signed;

    @BeforeAll
    static void signTwelvePages() throws Exception {
        try (var document = new PDDocument()) {
            for (var number = 1; number <= PAGES; number++) {
                var page = new PDPage(PDRectangle.A4);
                document.addPage(page);
                try (var content = new PDPageContentStream(document, page)) {
                    content.beginText();
                    content.setFont(new PDType1Font(Standard14Fonts.FontName.HELVETICA), 12);
                    content.newLineAtOffset(72, 720);
                    content.showText("Kupna cena 1000 EUR, strana " + number);
                    content.endText();
                }
            }
            var output = new ByteArrayOutputStream();
            document.save(output);
            signed = ConversionTestPdfs.sign(output.toByteArray(), false);
        }
    }

    private interface Change {
        void apply(PDDocument document) throws Exception;
    }

    /// `signed` plus one incremental update holding what `change` did.
    private static byte[] appended(Change change) throws Exception {
        return appended(signed, change);
    }

    private static byte[] appended(byte[] signed, Change change) throws Exception {
        try (var document = Loader.loadPDF(signed)) {
            change.apply(document);
            var output = new ByteArrayOutputStream();
            document.saveIncremental(output);
            var bytes = output.toByteArray();
            assertTrue(bytes.length > signed.length, "nothing was appended");
            assertTrue(Arrays.equals(signed, Arrays.copyOf(bytes, signed.length)), "the signed bytes were touched");
            return bytes;
        }
    }

    private static JsonArray changes(byte[] pdf) throws Exception {
        var path = Files.write(Files.createTempDirectory("attack").resolve("original.pdf"), pdf);
        var service = new ConversionEvidenceService(validator -> {
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            return validator.validateDocument();
        }, List::of);
        var evidence = service.evidence(path).getAsJsonObject("evidence");
        assertEquals(1, evidence.getAsJsonArray("signatures").size(), "the signature is no longer found");
        return evidence.getAsJsonObject("pdf").getAsJsonArray("changesAfterLastSignature");
    }

    private static void assertReported(byte[] pdf) throws Exception {
        var found = changes(pdf);
        assertNotEquals(0, found.size(), "a change after the signature went unreported");
    }

    private static String text(byte[] pdf, int pageIndex) throws Exception {
        try (var document = Loader.loadPDF(pdf)) {
            var stripper = new PDFTextStripper();
            stripper.setStartPage(pageIndex + 1);
            stripper.setEndPage(pageIndex + 1);
            return stripper.getText(document).trim();
        }
    }

    private static COSStream contents(PDDocument document, int pageIndex) {
        return document.getPage(pageIndex).getCOSObject().getCOSStream(COSName.CONTENTS);
    }

    /// The page's content stream keeps its object number and gets another price.
    private static void rewriteInPlace(PDDocument document, int pageIndex) throws Exception {
        var stream = contents(document, pageIndex);
        try (var out = stream.createOutputStream(COSName.FLATE_DECODE)) {
            out.write("BT /F1 12 Tf 72 720 Td (Kupna cena 9000 EUR) Tj ET".getBytes(StandardCharsets.US_ASCII));
        }
        stream.setNeedToBeUpdated(true);
    }

    private static COSBase contentsReference(PDDocument document, int pageIndex) {
        return document.getPage(pageIndex).getCOSObject().getItem(COSName.CONTENTS);
    }

    private static COSDictionary catalog(PDDocument document) {
        return document.getDocumentCatalog().getCOSObject();
    }

    private static byte[] rewritten(int pageIndex) throws Exception {
        var pdf = appended(document -> rewriteInPlace(document, pageIndex));
        assertTrue(text(pdf, pageIndex).contains("9000"), "the rewritten content is not what the page shows");
        return pdf;
    }

    // Controls: what the fixture is, and what must stay allowed.

    @Test
    void theSignedFileItselfHasNoChanges() throws Exception {
        assertEquals(0, changes(signed).size());
        assertTrue(text(signed, LAST).contains("1000"));
    }

    @Test
    void aDocumentTimestampIsNotAChange() throws Exception {
        var timestamped = ConversionTestPdfs.documentTimestamp(signed, ContentTimestampTest.authority());
        assertEquals(0, changes(timestamped).size(), changes(timestamped).toString());
    }

    @Test
    void certificatesAddedToTheSecurityStoreAreNotAChange() throws Exception {
        var pdf = appended(document -> {
            var certificate = document.getDocument().createCOSStream();
            try (var out = certificate.createOutputStream(COSName.FLATE_DECODE)) {
                out.write(new byte[] {0x30, 0x03, 0x02, 0x01, 0x01});
            }
            var certificates = new COSArray();
            certificates.add(certificate);
            var store = new COSDictionary();
            store.setItem(COSName.getPDFName("Certs"), certificates);
            catalog(document).setItem(DSS, store);
        });
        assertEquals(0, changes(pdf).size(), changes(pdf).toString());
    }

    @Test
    void twoDocumentTimestampsAreNotAChange() throws Exception {
        var once = ConversionTestPdfs.documentTimestamp(signed, ContentTimestampTest.authority());
        // The engine's test key expired in 2024, which a second timestamp would otherwise refuse.
        var verifier = new CommonCertificateVerifier();
        verifier.setAlertOnExpiredCertificate(new eu.europa.esig.dss.alert.LogOnStatusAlert());
        var service = new eu.europa.esig.dss.pades.signature.PAdESService(verifier);
        service.setTspSource(ContentTimestampTest.authority());
        byte[] twice;
        try (var stream = service.timestamp(new eu.europa.esig.dss.model.InMemoryDocument(once, "document.pdf"),
                new eu.europa.esig.dss.pades.PAdESTimestampParameters()).openStream()) {
            twice = stream.readAllBytes();
        }
        assertEquals(0, changes(twice).size(), changes(twice).toString());
    }

    /// The signed revision already has a security store, in objects of its own, and it grows.
    @Test
    void aSecurityStoreThatGrowsAfterSigningIsNotAChange() throws Exception {
        byte[] withStore;
        try (var document = Loader.loadPDF(ConversionTestPdfs.samplePdf())) {
            var certificates = new COSArray();
            certificates.add(certificateStream(document));
            var store = new COSDictionary();
            store.setItem(COSName.getPDFName("Certs"), new org.apache.pdfbox.cos.COSObject(certificates));
            catalog(document).setItem(DSS, new org.apache.pdfbox.cos.COSObject(store));
            var output = new ByteArrayOutputStream();
            document.save(output);
            withStore = output.toByteArray();
        }
        var signedWithStore = ConversionTestPdfs.sign(withStore, false);
        var grown = appended(signedWithStore, document -> {
            var store = catalog(document).getCOSDictionary(DSS);
            var certificates = store.getCOSArray(COSName.getPDFName("Certs"));
            certificates.add(certificateStream(document));
            certificates.setNeedToBeUpdated(true);
            var responses = new COSArray();
            responses.add(certificateStream(document));
            store.setItem(COSName.getPDFName("OCSPs"), responses);
        });
        var tail = new String(grown, signedWithStore.length, grown.length - signedWithStore.length, StandardCharsets.ISO_8859_1);
        assertFalse(tail.contains("/Type /Catalog"), "the store was meant to grow in its own objects");
        assertEquals(0, changes(grown).size(), changes(grown).toString());
    }

    private static COSStream certificateStream(PDDocument document) throws Exception {
        var certificate = document.getDocument().createCOSStream();
        try (var out = certificate.createOutputStream(COSName.FLATE_DECODE)) {
            out.write(new byte[] {0x30, 0x03, 0x02, 0x01, 0x01});
        }
        return certificate;
    }

    // Page content rewritten.

    @Test
    void contentRewrittenOnTheFirstPageIsReported() throws Exception {
        assertReported(rewritten(0));
    }

    @Test
    void contentRewrittenOnALatePageIsReported() throws Exception {
        assertReported(rewritten(LAST));
    }

    @Test
    void contentMovedToANewStreamOnALatePageIsReported() throws Exception {
        var pdf = appended(document -> {
            var stream = document.getDocument().createCOSStream();
            try (var out = stream.createOutputStream(COSName.FLATE_DECODE)) {
                out.write("BT /F1 12 Tf 72 720 Td (Kupna cena 9000 EUR) Tj ET".getBytes(StandardCharsets.US_ASCII));
            }
            document.getPage(LAST).getCOSObject().setItem(COSName.CONTENTS, stream);
        });
        assertTrue(text(pdf, LAST).contains("9000"));
        assertReported(pdf);
    }

    // The same rewrite, dressed as signature extension data.

    @Test
    void contentReachedThroughAnUnknownSecurityStoreKeyIsReported() throws Exception {
        var pdf = appended(document -> {
            rewriteInPlace(document, LAST);
            var store = new COSDictionary();
            store.setItem(COSName.getPDFName("X"), contentsReference(document, LAST));
            catalog(document).setItem(DSS, store);
        });
        assertTrue(text(pdf, LAST).contains("9000"));
        assertReported(pdf);
    }

    @Test
    void contentListedAsASecurityStoreCertificateIsReported() throws Exception {
        var pdf = appended(document -> {
            rewriteInPlace(document, LAST);
            var certificates = new COSArray();
            certificates.add(contentsReference(document, LAST));
            var store = new COSDictionary();
            store.setItem(COSName.getPDFName("Certs"), certificates);
            catalog(document).setItem(DSS, store);
        });
        assertTrue(text(pdf, LAST).contains("9000"));
        assertReported(pdf);
    }

    @Test
    void contentListedInValidationRelatedInformationIsReported() throws Exception {
        var pdf = appended(document -> {
            rewriteInPlace(document, LAST);
            var list = new COSArray();
            list.add(contentsReference(document, LAST));
            var entry = new COSDictionary();
            entry.setItem(COSName.getPDFName("Cert"), list);
            var related = new COSDictionary();
            related.setItem(COSName.getPDFName("0123456789ABCDEF0123456789ABCDEF01234567"), entry);
            var store = new COSDictionary();
            store.setItem(COSName.getPDFName("VRI"), related);
            catalog(document).setItem(DSS, store);
        });
        assertTrue(text(pdf, LAST).contains("9000"));
        assertReported(pdf);
    }

    @Test
    void contentLabelledAsASecurityStoreIsReported() throws Exception {
        var pdf = appended(document -> {
            rewriteInPlace(document, LAST);
            contents(document, LAST).setItem(COSName.TYPE, DSS);
        });
        assertTrue(text(pdf, LAST).contains("9000"));
        assertReported(pdf);
    }

    @Test
    void contentLabelledAsASignatureIsReported() throws Exception {
        var pdf = appended(document -> {
            rewriteInPlace(document, LAST);
            contents(document, LAST).setItem(COSName.TYPE, COSName.SIG);
        });
        assertTrue(text(pdf, LAST).contains("9000"));
        assertReported(pdf);
    }

    @Test
    void contentLabelledAsADocumentTimestampIsReported() throws Exception {
        var pdf = appended(document -> {
            rewriteInPlace(document, 0);
            contents(document, 0).setItem(COSName.TYPE, COSName.DOC_TIME_STAMP);
        });
        assertTrue(text(pdf, 0).contains("9000"));
        assertReported(pdf);
    }

    @Test
    void aPageRelabelledAsASignatureIsReported() throws Exception {
        var pdf = appended(document -> {
            rewriteInPlace(document, LAST);
            document.getPage(LAST).getCOSObject().setItem(COSName.TYPE, COSName.SIG);
        });
        assertReported(pdf);
    }

    // What a page shows changed without its content stream.

    @Test
    void aFontSwappedOnALatePageIsReported() throws Exception {
        var pdf = appended(document -> {
            var fonts = document.getPage(LAST).getResources().getCOSObject().getCOSDictionary(COSName.FONT);
            var name = fonts.keySet().iterator().next();
            fonts.getCOSDictionary(name).setItem(COSName.BASE_FONT, COSName.getPDFName("Symbol"));
            fonts.getCOSDictionary(name).setNeedToBeUpdated(true);
        });
        assertReported(pdf);
    }

    @Test
    void aSmallerVisibleAreaOnALatePageIsReported() throws Exception {
        var pdf = appended(document -> document.getPage(LAST).setCropBox(new PDRectangle(0, 0, 10, 10)));
        assertReported(pdf);
    }

    // Pages added and removed.

    @Test
    void anAddedPageIsReported() throws Exception {
        assertReported(appended(document -> document.addPage(new PDPage(PDRectangle.A4))));
    }

    @Test
    void aRemovedPageIsReported() throws Exception {
        assertReported(appended(document -> document.removePage(LAST)));
    }

    // Document level.

    @Test
    void changedDocumentInformationIsReported() throws Exception {
        assertReported(appended(document -> document.getDocumentInformation().setTitle("Iny nazov")));
    }

    @Test
    void addedMetadataIsReported() throws Exception {
        assertReported(appended(document -> {
            var metadata = new org.apache.pdfbox.pdmodel.common.PDMetadata(document);
            metadata.importXMPMetadata("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".getBytes(StandardCharsets.UTF_8));
            document.getDocumentCatalog().setMetadata(metadata);
        }));
    }

    @Test
    void aCommentDressedAsAHiddenSignatureFieldIsReported() throws Exception {
        var pdf = appended(document -> {
            var note = new COSDictionary();
            note.setItem(COSName.TYPE, COSName.SIG);
            note.setItem(COSName.FT, COSName.SIG);
            note.setItem(COSName.SUBTYPE, COSName.getPDFName("FreeText"));
            note.setItem(COSName.RECT, new PDRectangle(72, 600, 300, 40));
            note.setString(COSName.CONTENTS, "Kupna cena 9000 EUR");
            var annotations = new COSArray();
            var existing = document.getPage(LAST).getCOSObject().getCOSArray(COSName.ANNOTS);
            if (existing != null) annotations.addAll(existing);
            annotations.add(note);
            document.getPage(LAST).getCOSObject().setItem(COSName.ANNOTS, annotations);
        });
        assertReported(pdf);
    }

    @Test
    void anAttachmentAddedAfterSigningIsReported() throws Exception {
        var pdf = appended(document -> {
            var specification = new PDComplexFileSpecification();
            specification.setFile("dodatok.txt");
            specification.setEmbeddedFile(new PDEmbeddedFile(document, new ByteArrayInputStream("dodatok".getBytes())));
            var tree = new PDEmbeddedFilesNameTreeNode();
            tree.setNames(Map.of("dodatok.txt", specification));
            var names = new PDDocumentNameDictionary(document.getDocumentCatalog());
            names.setEmbeddedFiles(tree);
            document.getDocumentCatalog().setNames(names);
        });
        assertReported(pdf);
    }

    @Test
    void aScriptRunOnOpeningIsReported() throws Exception {
        assertReported(appended(document ->
                document.getDocumentCatalog().setOpenAction(new PDActionJavaScript("app.alert('x');"))));
    }

    @Test
    void theSignatureFieldTakenOffItsPageIsReported() throws Exception {
        var pdf = appended(document -> {
            assertFalse(document.getPage(0).getAnnotations().isEmpty(), "the signature widget is not on page 1");
            document.getPage(0).getCOSObject().removeItem(COSName.ANNOTS);
        });
        assertReported(pdf);
    }
}
