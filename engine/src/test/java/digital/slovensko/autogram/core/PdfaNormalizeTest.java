package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.FileDocument;
import eu.europa.esig.dss.pdfa.PDFAStructureValidator;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSArray;
import org.apache.pdfbox.cos.COSBase;
import org.apache.pdfbox.cos.COSDictionary;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.cos.COSObject;
import org.apache.pdfbox.cos.COSStream;
import org.apache.pdfbox.contentstream.operator.Operator;
import org.apache.pdfbox.pdfparser.PDFStreamParser;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDResources;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.graphics.form.PDFormXObject;
import org.apache.pdfbox.pdmodel.graphics.image.LosslessFactory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.IdentityHashMap;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PdfaNormalizeTest {
    private static final String ICC = "/System/Library/ColorSync/Profiles/sRGB Profile.icc";

    @TempDir
    Path temporaryDirectory;

    private Path sample() {
        return Path.of(PdfaNormalizeTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile());
    }

    private String normalizedText(Path source) throws Exception {
        var output = temporaryDirectory.resolve("normalized-" + System.nanoTime() + ".pdf");
        PdfaNormalize.normalize(source.toFile(), output.toFile(), new File(ICC), "Test");
        return new String(Files.readAllBytes(output), StandardCharsets.ISO_8859_1);
    }

    @Test
    void writesThePdfaIdentificationTheValidatorsLookFor() throws Exception {
        var text = normalizedText(sample());

        assertTrue(text.startsWith("%PDF-"), "must stay a PDF");
        assertTrue(text.contains("pdfaid:part=\"2\""), "PDF/A part, attribute form");
        assertTrue(text.contains("pdfaid:conformance=\"B\""), "PDF/A conformance, attribute form");
        assertTrue(text.contains("%%EOF"));
        assertTrue(text.contains("startxref"));
    }

    @Test
    void embedsTheOutputIntentWithAnIccProfile() throws Exception {
        var text = normalizedText(sample());

        assertTrue(text.contains("OutputIntent"));
        assertTrue(text.contains("GTS_PDFA"));
        assertTrue(text.contains("DestOutputProfile"));
    }

    /**
     * The whole reason this class exists. Everything downstream reads the catalog
     * by scanning bytes, and an object stream would hide /OutputIntents, /AF and
     * /AFRelationship from that scan.
     */
    @Test
    void writesWithoutObjectStreamsSoTheCatalogStaysReadable() throws Exception {
        var text = normalizedText(sample());

        assertFalse(text.contains("ObjStm"), "object streams would hide the catalog from byte scans");
    }

    /**
     * Mirrors what the app does: the osvedčovacia doložka is attached as an
     * incremental update, so the source arrives with two cross-reference tables
     * and stale metadata. Normalizing must leave exactly one of each.
     */
    @Test
    void collapsesAnIncrementallyUpdatedFileIntoOneCrossReferenceTable() throws Exception {
        var original = Files.readAllBytes(sample());
        var incremental = temporaryDirectory.resolve("incremental.pdf");
        var appended = new String(original, StandardCharsets.ISO_8859_1)
                + "\n% incremental update\n1 0 obj\n<< /Type /Catalog >>\nendobj\nstartxref\n0\n%%EOF\n";
        Files.write(incremental, appended.getBytes(StandardCharsets.ISO_8859_1));
        assertEquals(2, countOf(appended, "%%EOF"), "the fixture must really be incrementally updated");

        var text = normalizedText(incremental);

        assertEquals(1, countOf(text, "%%EOF"), "one end marker after normalizing");
        assertEquals(1, countOf(text, "startxref"), "one cross-reference table after normalizing");
    }

    /**
     * PDF/A-2 rule 6.2.8-3: an image may not ask for interpolation. Scans and PDFKit's image
     * pages carry /Interpolate true, so the normalizer must clear it on image XObjects, on
     * images nested in form XObjects and on inline images, or the output claims PDF/A-2b
     * while veraPDF refuses it.
     */
    @Test
    void normalizeClearsInterpolate() throws Exception {
        var source = temporaryDirectory.resolve("interpolating.pdf");
        Files.write(source, interpolatingImagesPdf());
        assertEquals(3, interpolatingImages(Files.readAllBytes(source)), "the fixture must interpolate");

        var output = temporaryDirectory.resolve("normalized.pdf");
        PdfaNormalize.normalize(source.toFile(), output.toFile(), new File(ICC), "Test");

        var bytes = Files.readAllBytes(output);
        assertEquals(0, interpolatingImages(bytes));
        var check = new PDFAStructureValidator().validate(new FileDocument(output.toFile()));
        assertTrue(check.isCompliant(), () -> String.join("\n", check.getErrorMessages()));
        assertTrue(check.getProfileId().replace("-", "").toUpperCase().contains("2B"), check.getProfileId());
    }

    /**
     * A client PDF on the E→E route may hold a content stream that does not decode. Looking for
     * inline images must not turn that into a failed normalization: veraPDF judges the result.
     */
    @Test
    void normalizeSurvivesAContentStreamThatDoesNotDecode() throws Exception {
        byte[] pdf;
        try (var document = new PDDocument()) {
            var page = new PDPage(PDRectangle.A4);
            document.addPage(page);
            var form = new PDFormXObject(document);
            form.setBBox(new PDRectangle(100, 100));
            try (var raw = form.getCOSObject().createRawOutputStream()) {
                raw.write("not really encoded".getBytes(StandardCharsets.ISO_8859_1));
            }
            form.getCOSObject().setItem(COSName.FILTER, COSName.getPDFName("UnknownDecode"));
            var resources = new PDResources();
            page.setResources(resources);
            var formName = resources.add(form).getName();
            var stream = new org.apache.pdfbox.pdmodel.common.PDStream(document);
            try (var out = stream.createOutputStream()) {
                out.write(("/" + formName + " Do\n").getBytes(StandardCharsets.ISO_8859_1));
            }
            page.setContents(stream);
            var output = new ByteArrayOutputStream();
            document.save(output);
            pdf = output.toByteArray();
        }
        var source = temporaryDirectory.resolve("undecodable.pdf");
        Files.write(source, pdf);

        var output = temporaryDirectory.resolve("normalized.pdf");
        PdfaNormalize.normalize(source.toFile(), output.toFile(), new File(ICC), "Test");

        assertTrue(Files.size(output) > 0);
    }

    /**
     * A content stream encoded with Flate and a PNG predictor: rewriting it to clear an inline
     * image's /I must drop the predictor parameters too, or the page content comes back as
     * garbage. The operators and the image data must survive unchanged.
     */
    @Test
    void rewritingAPredictorContentStreamKeepsThePageContent() throws Exception {
        var pdf = onePagePdf(contentWithInlineImage(true), true);
        var before = pageTokens(pdf);
        assertEquals(1, interpolatingImages(pdf), "the fixture's inline image interpolates");
        assertTrue(before.contains("re"), "the fixture decodes: " + before);

        var source = temporaryDirectory.resolve("predictor.pdf");
        Files.write(source, pdf);
        var output = temporaryDirectory.resolve("normalized.pdf");
        PdfaNormalize.normalize(source.toFile(), output.toFile(), new File(ICC), "Test");

        var bytes = Files.readAllBytes(output);
        assertEquals(before.replace("/I true ", ""), pageTokens(bytes));
        assertEquals(0, interpolatingImages(bytes));
        // PDFBox does not render the interpolating source at all, so the reference is the same
        // content written plainly without /I.
        assertArrayEquals(rendered(onePagePdf(contentWithInlineImage(false), false)), rendered(bytes),
                "the page looks as its content says");
        var check = new PDFAStructureValidator().validate(new FileDocument(output.toFile()));
        assertTrue(check.isCompliant(), () -> String.join("\n", check.getErrorMessages()));
    }

    private static final int PREDICTOR_COLUMNS = 8;

    /** A 2 x 2 grey inline image and a blue square, padded to whole predictor rows. */
    private static byte[] contentWithInlineImage(boolean interpolate) throws Exception {
        var plain = new ByteArrayOutputStream();
        plain.write(("q 100 0 0 100 350 600 cm\nBI /W 2 /H 2 /BPC 8 /CS /G " + (interpolate ? "/I true " : "") + "ID ")
                .getBytes(StandardCharsets.ISO_8859_1));
        plain.write(new byte[] {0, 64, (byte) 128, (byte) 255});
        plain.write("\nEI Q\nq 0 0 1 rg 10 10 50 50 re f Q\n".getBytes(StandardCharsets.ISO_8859_1));
        while (plain.size() % PREDICTOR_COLUMNS != 0) {
            plain.write(' ');
        }
        return plain.toByteArray();
    }

    /** One page with the given content, Flate with a PNG Up predictor or unfiltered. */
    private static byte[] onePagePdf(byte[] content, boolean predictor) throws Exception {
        try (var document = new PDDocument()) {
            var page = new PDPage(PDRectangle.A4);
            document.addPage(page);
            page.setResources(new PDResources());
            var stream = new org.apache.pdfbox.pdmodel.common.PDStream(document);
            try (var raw = stream.getCOSObject().createRawOutputStream()) {
                raw.write(predictor ? deflate(pngUpPredicted(content, PREDICTOR_COLUMNS)) : content);
            }
            if (predictor) {
                stream.getCOSObject().setItem(COSName.FILTER, COSName.FLATE_DECODE);
                var parameters = new COSDictionary();
                parameters.setInt(COSName.PREDICTOR, 12);
                parameters.setInt(COSName.COLUMNS, PREDICTOR_COLUMNS);
                stream.getCOSObject().setItem(COSName.DECODE_PARMS, parameters);
            }
            page.setContents(stream);
            var output = new ByteArrayOutputStream();
            document.save(output);
            return output.toByteArray();
        }
    }

    private static int[] rendered(byte[] pdf) throws Exception {
        try (var document = Loader.loadPDF(pdf)) {
            var image = new org.apache.pdfbox.rendering.PDFRenderer(document).renderImageWithDPI(0, 36);
            return image.getRGB(0, 0, image.getWidth(), image.getHeight(), null, 0, image.getWidth());
        }
    }

    private static byte[] pngUpPredicted(byte[] data, int columns) {
        var encoded = new ByteArrayOutputStream();
        var previous = new byte[columns];
        for (var row = 0; row < data.length; row += columns) {
            encoded.write(2); // PNG "Up"
            for (var column = 0; column < columns; column++) {
                encoded.write((byte) (data[row + column] - previous[column]));
            }
            System.arraycopy(data, row, previous, 0, columns);
        }
        return encoded.toByteArray();
    }

    private static byte[] deflate(byte[] data) {
        var deflater = new java.util.zip.Deflater();
        deflater.setInput(data);
        deflater.finish();
        var output = new ByteArrayOutputStream();
        var buffer = new byte[1024];
        while (!deflater.finished()) {
            output.write(buffer, 0, deflater.deflate(buffer));
        }
        deflater.end();
        return output.toByteArray();
    }

    /** The first page's content as tokens: operators by name, inline images with their data. */
    private static String pageTokens(byte[] pdf) throws Exception {
        try (var document = Loader.loadPDF(pdf);
             var input = document.getPage(0).getContents()) {
            var text = new StringBuilder();
            for (var token : new PDFStreamParser(input.readAllBytes()).parse()) {
                if (token instanceof Operator operator) {
                    if (operator.getImageParameters() != null) {
                        var parameters = new java.util.TreeMap<String, String>();
                        operator.getImageParameters().entrySet().forEach(entry ->
                                parameters.put(entry.getKey().getName(), String.valueOf(entry.getValue())));
                        parameters.forEach((key, value) -> text.append('/').append(key).append(' ')
                                .append(value).append(' '));
                        // Only the samples (W x H, one byte each here): PDFBox's parser counts the
                        // whitespace before EI as data, and its writer adds one more on every rewrite,
                        // which readers ignore because the samples end before it.
                        var samples = operator.getImageParameters().getInt(COSName.W)
                                * operator.getImageParameters().getInt(COSName.H);
                        text.append(java.util.HexFormat.of().formatHex(
                                java.util.Arrays.copyOf(operator.getImageData(), samples))).append(' ');
                    }
                    text.append(operator.getName()).append('\n');
                } else {
                    text.append(token).append(' ');
                }
            }
            return text.toString();
        }
    }

    /** One page: an image XObject, the same kind of image inside a form XObject, an inline image. */
    private static byte[] interpolatingImagesPdf() throws Exception {
        try (var document = new PDDocument()) {
            var page = new PDPage(PDRectangle.A4);
            document.addPage(page);
            var pixels = new BufferedImage(4, 4, BufferedImage.TYPE_INT_RGB);
            pixels.setRGB(1, 1, 0x336699);

            var direct = LosslessFactory.createFromImage(document, pixels);
            direct.getCOSObject().setBoolean(COSName.INTERPOLATE, true);

            var nested = LosslessFactory.createFromImage(document, pixels);
            nested.getCOSObject().setBoolean(COSName.INTERPOLATE, true);
            var form = new PDFormXObject(document);
            form.setBBox(new PDRectangle(100, 100));
            form.setResources(new PDResources());
            try (var content = new org.apache.pdfbox.pdmodel.PDFormContentStream(form)) {
                content.drawImage(nested, 0, 0, 100, 100);
            }

            // Written by hand, so the inline image surely carries /I true.
            var resources = new PDResources();
            page.setResources(resources);
            var imageName = resources.add(direct).getName();
            var formName = resources.add(form).getName();
            var content = new ByteArrayOutputStream();
            content.write(("q 100 0 0 100 50 600 cm /" + imageName + " Do Q\n"
                    + "q 1 0 0 1 200 600 cm /" + formName + " Do Q\n"
                    + "q 100 0 0 100 350 600 cm\nBI /W 2 /H 2 /BPC 8 /CS /G /I true ID ")
                    .getBytes(StandardCharsets.ISO_8859_1));
            content.write(new byte[] {0, 64, (byte) 128, (byte) 255});
            content.write("\nEI Q\n".getBytes(StandardCharsets.ISO_8859_1));
            var stream = new org.apache.pdfbox.pdmodel.common.PDStream(document);
            try (var out = stream.createOutputStream()) {
                out.write(content.toByteArray());
            }
            page.setContents(stream);
            var output = new ByteArrayOutputStream();
            document.save(output);
            return output.toByteArray();
        }
    }

    /** Counts image XObjects and inline images that ask for interpolation, wherever they sit. */
    private static int interpolatingImages(byte[] pdf) throws Exception {
        try (var document = Loader.loadPDF(pdf)) {
            var count = 0;
            var seen = Collections.newSetFromMap(new IdentityHashMap<COSBase, Boolean>());
            var pending = new ArrayDeque<COSBase>();
            pending.push(document.getDocumentCatalog().getCOSObject());
            while (!pending.isEmpty()) {
                var item = pending.pop();
                if (item instanceof COSObject reference) {
                    item = reference.getObject();
                }
                if (item == null || !seen.add(item)) {
                    continue;
                }
                if (item instanceof COSStream stream) {
                    if (COSName.IMAGE.equals(stream.getCOSName(COSName.SUBTYPE))
                            && stream.getBoolean(COSName.INTERPOLATE, false)) {
                        count++;
                    }
                    if (!COSName.IMAGE.equals(stream.getCOSName(COSName.SUBTYPE))) {
                        count += interpolatingInlineImages(stream);
                    }
                }
                if (item instanceof COSDictionary dictionary) {
                    for (var entry : dictionary.entrySet()) {
                        if (!COSName.PARENT.equals(entry.getKey())) {
                            pending.push(entry.getValue());
                        }
                    }
                } else if (item instanceof COSArray array) {
                    for (var element : array) {
                        pending.push(element);
                    }
                }
            }
            return count;
        }
    }

    private static int interpolatingInlineImages(COSStream stream) {
        try (var input = stream.createInputStream()) {
            var count = 0;
            for (var token : new PDFStreamParser(input.readAllBytes()).parse()) {
                if (token instanceof Operator operator && operator.getImageParameters() != null) {
                    var parameters = operator.getImageParameters();
                    if (parameters.getBoolean(COSName.I, false) || parameters.getBoolean(COSName.INTERPOLATE, false)) {
                        count++;
                    }
                }
            }
            return count;
        } catch (Exception notContent) {
            return 0;
        }
    }

    private static int countOf(String haystack, String needle) {
        int count = 0;
        int index = haystack.indexOf(needle);
        while (index >= 0) {
            count++;
            index = haystack.indexOf(needle, index + needle.length());
        }
        return count;
    }
}
