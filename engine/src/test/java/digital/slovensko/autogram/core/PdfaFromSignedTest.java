package digital.slovensko.autogram.core;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDResources;
import org.apache.pdfbox.pdmodel.font.PDType1Font;
import org.apache.pdfbox.pdmodel.font.Standard14Fonts;
import org.apache.pdfbox.pdmodel.interactive.form.PDAcroForm;
import org.apache.pdfbox.pdmodel.interactive.form.PDSignatureField;
import org.apache.pdfbox.pdmodel.interactive.form.PDTextField;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.rendering.PDFRenderer;
import org.apache.pdfbox.text.PDFTextStripper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import org.apache.pdfbox.contentstream.operator.Operator;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.cos.COSNumber;
import org.apache.pdfbox.pdfparser.PDFStreamParser;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;

import javax.imageio.IIOImage;
import javax.imageio.ImageIO;
import javax.imageio.ImageTypeSpecifier;
import javax.imageio.metadata.IIOMetadataNode;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PdfaFromSignedTest {
    private static final File ICC = new File("/System/Library/ColorSync/Profiles/sRGB Profile.icc");

    @TempDir
    Path temporary;

    private PdfaFromSigned.Result convert(byte[] pdf, boolean raster) throws Exception {
        var input = Files.write(temporary.resolve("in.pdf"), pdf);
        return PdfaFromSigned.convert(input.toFile(), temporary.resolve("out.pdf").toFile(), ICC, "Zmluva", raster);
    }

    private byte[] output() throws Exception {
        return Files.readAllBytes(temporary.resolve("out.pdf"));
    }

    private static boolean hasSignatureField(byte[] pdf) throws Exception {
        try (var document = Loader.loadPDF(pdf)) {
            var form = document.getDocumentCatalog().getAcroForm(null);
            if (form == null) return false;
            for (var field : form.getFieldTree()) {
                if (field instanceof PDSignatureField) return true;
            }
            return false;
        }
    }

    @Test
    void signedPdfLosesItsSignatureAndPermissions() throws Exception {
        var signed = ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), true);
        assertTrue(hasSignatureField(signed));

        convert(signed, false);

        assertFalse(hasSignatureField(output()));
        try (var document = Loader.loadPDF(output())) {
            assertNull(document.getDocumentCatalog().getCOSObject().getDictionaryObject(org.apache.pdfbox.cos.COSName.PERMS));
            assertEquals(new String(output(), java.nio.charset.StandardCharsets.ISO_8859_1).contains("/ByteRange"), false);
        }
    }

    @Test
    void visibleSignatureStampStaysOnThePage() throws Exception {
        var unsigned = ConversionTestPdfs.samplePdf();
        var signed = ConversionTestPdfs.sign(unsigned, true);

        convert(signed, false);

        try (var before = Loader.loadPDF(unsigned); var after = Loader.loadPDF(output())) {
            // DSS places the stamp at 50,50 from the top left, 200 x 60 points.
            var plain = new PDFRenderer(before).renderImageWithDPI(0, 72);
            var stamped = new PDFRenderer(after).renderImageWithDPI(0, 72);
            var differs = false;
            for (var x = 55; x < 245 && !differs; x += 3) {
                for (var y = 55; y < 105 && !differs; y += 3) {
                    differs = plain.getRGB(x, y) != stamped.getRGB(x, y);
                }
            }
            assertTrue(differs, "the stamp region of the converted page must differ from the unsigned page");
        }
    }

    @Test
    void twoSignaturePdfConverts() throws Exception {
        var twice = ConversionTestPdfs.sign(ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false), false);

        convert(twice, false);

        assertFalse(hasSignatureField(output()));
    }

    @Test
    void filledFormFieldValueStaysVisible() throws Exception {
        byte[] form;
        try (var document = Loader.loadPDF(ConversionTestPdfs.withText("Zmluva"))) {
            var acroForm = new PDAcroForm(document);
            document.getDocumentCatalog().setAcroForm(acroForm);
            var resources = new PDResources();
            resources.put(org.apache.pdfbox.cos.COSName.getPDFName("Helv"), new PDType1Font(Standard14Fonts.FontName.HELVETICA));
            acroForm.setDefaultResources(resources);
            acroForm.setDefaultAppearance("/Helv 12 Tf 0 g");
            var field = new PDTextField(acroForm);
            field.setPartialName("meno");
            acroForm.getFields().add(field);
            var widget = field.getWidgets().getFirst();
            widget.setRectangle(new PDRectangle(72, 600, 200, 20));
            widget.setPage(document.getPage(0));
            document.getPage(0).getAnnotations().add(widget);
            field.setValue("Ján Novák");
            var output = new ByteArrayOutputStream();
            document.save(output);
            form = output.toByteArray();
        }

        convert(form, false);

        try (var document = Loader.loadPDF(output())) {
            assertTrue(new PDFTextStripper().getText(document).contains("Ján Novák"));
            assertNull(document.getDocumentCatalog().getAcroForm(null));
        }
    }

    @Test
    void rasterModeIsPdfaWithoutText() throws Exception {
        var signed = ConversionTestPdfs.sign(ConversionTestPdfs.withText("Zmluva"), true);

        var result = convert(signed, true);

        assertTrue(result.compliant(), result.errors().toString());
        try (PDDocument document = Loader.loadPDF(output())) {
            assertEquals("", new PDFTextStripper().getText(document).strip());
        }
        assertFalse(hasSignatureField(output()));
    }

    @Test
    void unembeddedFontsAreReportedNotCompliant() throws Exception {
        var result = convert(ConversionTestPdfs.withText("Zmluva"), false);

        assertFalse(result.compliant());
        assertTrue(result.errors().toString().contains("font"), result.errors().toString());
    }

    private static final float A4_SHORT = 595.2756f;
    private static final float A4_LONG = 841.8898f;
    private static final float MARGIN = 28.3465f;

    private PdfaFromSigned.Result merge(boolean raster, Object... namesAndBytes) throws Exception {
        var inputs = new ArrayList<PdfaFromSigned.Input>();
        for (var index = 0; index < namesAndBytes.length; index += 2) {
            var name = (String) namesAndBytes[index];
            var file = Files.write(temporary.resolve("in-" + index), (byte[]) namesAndBytes[index + 1]);
            inputs.add(new PdfaFromSigned.Input(file.toFile(), name));
        }
        return PdfaFromSigned.merge(inputs, temporary.resolve("out.pdf").toFile(), ICC, "Zlúčený", raster);
    }

    /// Two A4 pages with only drawn rectangles, so no font can make the result non-compliant.
    private static byte[] twoPagePdf() throws Exception {
        try (var document = new PDDocument()) {
            for (var index = 0; index < 2; index++) {
                var page = new PDPage(PDRectangle.A4);
                document.addPage(page);
                try (var content = new PDPageContentStream(document, page)) {
                    content.setNonStrokingColor(0.2f, 0.4f, 0.6f);
                    content.addRect(72, 72 + index * 100, 200, 100);
                    content.fill();
                }
            }
            var output = new ByteArrayOutputStream();
            document.save(output);
            return output.toByteArray();
        }
    }

    /// An 8-bit RGB PNG whose pHYs chunk states `dpi`.
    private static byte[] pngWithResolution(int width, int height, int dpi) throws Exception {
        var image = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
        var graphics = image.createGraphics();
        graphics.setColor(java.awt.Color.WHITE);
        graphics.fillRect(0, 0, width, height);
        graphics.dispose();
        var writer = ImageIO.getImageWritersByFormatName("png").next();
        var parameters = writer.getDefaultWriteParam();
        var metadata = writer.getDefaultImageMetadata(ImageTypeSpecifier.createFromRenderedImage(image), parameters);
        var root = new IIOMetadataNode("javax_imageio_png_1.0");
        var physical = new IIOMetadataNode("pHYs");
        var perMeter = Integer.toString(Math.round(dpi / 0.0254f));
        physical.setAttribute("pixelsPerUnitXAxis", perMeter);
        physical.setAttribute("pixelsPerUnitYAxis", perMeter);
        physical.setAttribute("unitSpecifier", "meter");
        root.appendChild(physical);
        metadata.mergeTree("javax_imageio_png_1.0", root);
        var output = new ByteArrayOutputStream();
        try (var stream = ImageIO.createImageOutputStream(output)) {
            writer.setOutput(stream);
            writer.write(null, new IIOImage(image, null, metadata), parameters);
        } finally {
            writer.dispose();
        }
        return output.toByteArray();
    }

    /// The placement (x, y, width, height) of every image drawn on a page, read from the
    /// `cm` that precedes each `Do`; the merge draws each image as `q w 0 0 h x y cm /Im Do Q`.
    private static List<float[]> imagePlacements(PDPage page) throws Exception {
        var tokens = new PDFStreamParser(page).parse();
        var placements = new ArrayList<float[]>();
        float[] matrix = null;
        for (var index = 0; index < tokens.size(); index++) {
            if (tokens.get(index) instanceof Operator operator) {
                if (operator.getName().equals("cm")) {
                    matrix = new float[6];
                    for (var operand = 0; operand < 6; operand++) {
                        matrix[operand] = ((COSNumber) tokens.get(index - 6 + operand)).floatValue();
                    }
                } else if (operator.getName().equals("Do") && matrix != null) {
                    var name = (COSName) tokens.get(index - 1);
                    if (page.getResources().isImageXObject(name)) {
                        placements.add(new float[] {matrix[4], matrix[5], matrix[0], matrix[3]});
                    }
                }
            }
        }
        return placements;
    }

    private static PDPage onlyPage(PDDocument document) {
        assertEquals(1, document.getNumberOfPages());
        return document.getPage(0);
    }

    @Test
    void mergeKeepsOrderAndOutline() throws Exception {
        var result = merge(false,
                "zmluva.pdf", ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), true),
                "priloha.pdf", twoPagePdf(),
                "foto.png", ConversionTestContainers.png(400, 300, false));

        assertTrue(result.compliant(), result.errors().toString());
        assertFalse(hasSignatureField(output()));
        assertFalse(new String(output(), java.nio.charset.StandardCharsets.ISO_8859_1).contains("/ByteRange"));
        try (var document = Loader.loadPDF(output())) {
            assertEquals(4, document.getNumberOfPages());
            // Nothing of the sources' page trees comes along: every page object is a page of the output.
            assertEquals(4, document.getDocument().getObjectsByType(COSName.PAGE).size());
            var titles = new ArrayList<String>();
            var pages = new ArrayList<Integer>();
            for (var item : document.getDocumentCatalog().getDocumentOutline().children()) {
                titles.add(item.getTitle());
                pages.add(document.getPages().indexOf(item.findDestinationPage(document)) + 1);
            }
            assertEquals(List.of("zmluva.pdf", "priloha.pdf", "foto.png"), titles);
            assertEquals(List.of(1, 2, 4), pages);
        }
    }

    @Test
    void imagePageIsA4InTheImageOrientation() throws Exception {
        var result = merge(false, "sken.png", ConversionTestContainers.png(3000, 2000, false));

        assertTrue(result.compliant(), result.errors().toString());
        try (var document = Loader.loadPDF(output())) {
            var page = onlyPage(document);
            assertEquals(A4_LONG, page.getMediaBox().getWidth(), 0.01);
            assertEquals(A4_SHORT, page.getMediaBox().getHeight(), 0.01);
            var placement = imagePlacements(page).getFirst();
            assertTrue(placement[0] >= MARGIN - 0.01 && placement[1] >= MARGIN - 0.01, Arrays.toString(placement));
            assertTrue(placement[0] + placement[2] <= A4_LONG - MARGIN + 0.01, Arrays.toString(placement));
            assertTrue(placement[1] + placement[3] <= A4_SHORT - MARGIN + 0.01, Arrays.toString(placement));
            // Wider than tall, so fitted to the width and centered vertically.
            assertEquals(A4_LONG - 2 * MARGIN, placement[2], 0.01);
            assertEquals(placement[2] * 2000 / 3000, placement[3], 0.01);
            assertEquals((A4_SHORT - placement[3]) / 2, placement[1], 0.01);
        }
    }

    @Test
    void smallImageIsNotEnlarged() throws Exception {
        var result = merge(false, "podpis.png", pngWithResolution(300, 300, 300));

        assertTrue(result.compliant(), result.errors().toString());
        try (var document = Loader.loadPDF(output())) {
            var page = onlyPage(document);
            assertEquals(A4_SHORT, page.getMediaBox().getWidth(), 0.01);
            var placement = imagePlacements(page).getFirst();
            assertEquals(72, placement[2], 0.05);
            assertEquals(72, placement[3], 0.05);
            assertEquals((A4_SHORT - 72) / 2, placement[0], 0.05);
        }
    }

    @Test
    void imageWithoutResolutionIsDrawnAt150Dpi() throws Exception {
        merge(false, "ikona.png", ConversionTestContainers.png(150, 300, false));

        try (var document = Loader.loadPDF(output())) {
            var placement = imagePlacements(onlyPage(document)).getFirst();
            assertEquals(72, placement[2], 0.05);
            assertEquals(144, placement[3], 0.05);
        }
    }

    @Test
    void cmykJpegBecomesRgbPage() throws Exception {
        var result = merge(false, "foto.jpg", ConversionTestContainers.jpeg(600, 400, true));

        assertTrue(result.compliant(), result.errors().toString());
        try (var document = Loader.loadPDF(output())) {
            var page = onlyPage(document);
            var placement = imagePlacements(page).getFirst();
            var rendered = new PDFRenderer(document).renderImageWithDPI(0, 72);
            var height = rendered.getHeight();
            // The fixture has no ink at its top left corner and full cyan and magenta at the bottom right.
            var left = Math.round(placement[0]) + 3;
            var top = height - Math.round(placement[1] + placement[3]) + 3;
            var paper = new java.awt.Color(rendered.getRGB(left, top));
            assertTrue(paper.getRed() > 200 && paper.getGreen() > 200 && paper.getBlue() > 200, paper.toString());
            var right = Math.round(placement[0] + placement[2]) - 4;
            var bottom = height - Math.round(placement[1]) - 4;
            var ink = new java.awt.Color(rendered.getRGB(right, bottom));
            assertTrue(ink.getRed() < 128 && ink.getBlue() > ink.getRed(), ink.toString());
        }
    }

    @Test
    void rgbJpegMerges() throws Exception {
        var result = merge(false, "foto.jpg", ConversionTestContainers.jpeg(400, 600, false));

        assertTrue(result.compliant(), result.errors().toString());
        try (var document = Loader.loadPDF(output())) {
            var page = onlyPage(document);
            assertEquals(A4_SHORT, page.getMediaBox().getWidth(), 0.01);
            // A JFIF density without a unit states no resolution, so 150 dpi applies.
            var placement = imagePlacements(page).getFirst();
            assertEquals(192, placement[2], 0.05);
            assertEquals(288, placement[3], 0.05);
        }
    }

    @Test
    void sixteenBitPngMerges() throws Exception {
        var result = merge(false, "sken.png", ConversionTestContainers.png(800, 600, true));

        assertTrue(result.compliant(), result.errors().toString());
        try (var document = Loader.loadPDF(output())) {
            for (var name : onlyPage(document).getResources().getXObjectNames()) {
                var image = (org.apache.pdfbox.pdmodel.graphics.image.PDImageXObject)
                        onlyPage(document).getResources().getXObject(name);
                assertEquals(8, image.getBitsPerComponent());
            }
        }
    }

    @Test
    void unreadableInputExitsTwo() throws Exception {
        var truncated = Files.write(temporary.resolve("cut.pdf"),
                Arrays.copyOf(ConversionTestPdfs.samplePdf(), 100));
        var exit = PdfaFromSigned.run(new String[] {"--merge", temporary.resolve("out.pdf").toString(),
                ICC.getPath(), "Zlúčený", truncated.toString(), "cut.pdf"});

        assertEquals(2, exit);
    }

    @Test
    void unsupportedInputExitsTwo() throws Exception {
        var text = Files.writeString(temporary.resolve("poznamka.pdf"), "nie je to PDF");
        var exit = PdfaFromSigned.run(new String[] {"--merge", temporary.resolve("out.pdf").toString(),
                ICC.getPath(), "Zlúčený", text.toString(), "poznamka.pdf"});

        assertEquals(2, exit);
    }

    @Test
    void mergeCommandLineWritesTheDocument() throws Exception {
        var first = Files.write(temporary.resolve("a"), twoPagePdf());
        var second = Files.write(temporary.resolve("b"), ConversionTestContainers.png(200, 100, false));
        var exit = PdfaFromSigned.run(new String[] {"--merge", temporary.resolve("out.pdf").toString(),
                ICC.getPath(), "Zlúčený", "--raster", first.toString(), "a.pdf", second.toString(), "b.png"});

        assertEquals(0, exit);
        try (var document = Loader.loadPDF(output())) {
            assertEquals(3, document.getNumberOfPages());
        }
    }

    @Test
    void mergeCommandLineRefusesAnOddPair() {
        assertEquals(1, PdfaFromSigned.run(new String[] {"--merge", "out.pdf", ICC.getPath(), "T", "a.pdf"}));
    }

    @Test
    void rasterMergeHasNoText() throws Exception {
        var result = merge(true,
                "zmluva.pdf", ConversionTestPdfs.sign(ConversionTestPdfs.withText("Zmluva"), true),
                "foto.png", ConversionTestContainers.png(400, 300, false));

        assertTrue(result.compliant(), result.errors().toString());
        try (var document = Loader.loadPDF(output())) {
            assertEquals(2, document.getNumberOfPages());
            assertEquals("", new PDFTextStripper().getText(document).strip());
        }
        assertFalse(hasSignatureField(output()));
    }
}
