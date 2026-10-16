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

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;

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
}
