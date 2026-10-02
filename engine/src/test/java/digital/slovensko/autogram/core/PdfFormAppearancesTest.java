package digital.slovensko.autogram.core;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.interactive.form.PDAcroForm;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Acrobat hides a PAdES signature of a PDF whose signed revision still says
 * /NeedAppearances true (verified 2026-10-02 with a JSF web form export). Before such a
 * PDF is signed, its fields get real appearance streams and the flag is cleared.
 */
class PdfFormAppearancesTest {
    @Test
    void fixtureReallyAsksTheViewerToRedrawItsFields() throws Exception {
        var source = NeedAppearancesFixture.webForm(true);

        try (var document = Loader.loadPDF(source)) {
            var acroForm = document.getDocumentCatalog().getAcroForm(null);
            assertTrue(acroForm.getNeedAppearances());
            assertEquals(4, widgetCount(acroForm));
            assertEquals(0, widgetsWithAppearance(acroForm));
        }
    }

    @Test
    void generatesFieldAppearancesAndClearsNeedAppearances() throws Exception {
        var source = NeedAppearancesFixture.webForm(true);

        var prepared = PdfFormAppearances.withGeneratedAppearances(source);

        try (var document = Loader.loadPDF(prepared)) {
            var acroForm = document.getDocumentCatalog().getAcroForm(null);
            assertFalse(acroForm.getNeedAppearances());
            assertNotNull(acroForm.getDefaultAppearance());
            assertFalse(acroForm.getDefaultAppearance().isBlank());
            assertEquals(4, widgetCount(acroForm), "no field may be lost");
            assertEquals(4, widgetsWithAppearance(acroForm), "every widget gets an appearance stream");
        }
    }

    @Test
    void appendsAnIncrementalUpdateAndKeepsTheSourceBytes() throws Exception {
        var source = NeedAppearancesFixture.webForm(true);

        var prepared = PdfFormAppearances.withGeneratedAppearances(source);

        assertTrue(prepared.length > source.length);
        assertArrayEquals(source, Arrays.copyOf(prepared, source.length), "the original revision stays a verbatim prefix");
        assertEquals(occurrences(source, "startxref") + 1, occurrences(prepared, "startxref"));
    }

    @Test
    void leavesAnAlreadySignedPdfByteIdentical() throws Exception {
        var source = NeedAppearancesFixture.signedWebForm();

        assertArrayEquals(source, PdfFormAppearances.withGeneratedAppearances(source));
    }

    @Test
    void leavesARealSignedPdfByteIdentical() throws Exception {
        var source = Files.readAllBytes(Path.of("src/test/resources/digital/slovensko/autogram/sample_signed.pdf"));

        assertArrayEquals(source, PdfFormAppearances.withGeneratedAppearances(source));
    }

    @Test
    void leavesAFormWithoutNeedAppearancesByteIdentical() throws Exception {
        var source = NeedAppearancesFixture.webForm(false);

        assertArrayEquals(source, PdfFormAppearances.withGeneratedAppearances(source));
    }

    @Test
    void leavesAPdfWithoutFormByteIdentical() throws Exception {
        var source = NeedAppearancesFixture.withoutAcroForm();

        assertArrayEquals(source, PdfFormAppearances.withGeneratedAppearances(source));
    }

    @Test
    void leavesSomethingThatIsNoPdfByteIdentical() {
        var source = "not a pdf".getBytes(StandardCharsets.US_ASCII);

        assertArrayEquals(source, PdfFormAppearances.withGeneratedAppearances(source));
    }

    private static int widgetCount(PDAcroForm acroForm) {
        int count = 0;
        for (var field : acroForm.getFieldTree()) {
            count += field.getWidgets().size();
        }
        return count;
    }

    private static int widgetsWithAppearance(PDAcroForm acroForm) {
        int count = 0;
        for (var field : acroForm.getFieldTree()) {
            for (var widget : field.getWidgets()) {
                if (widget.getAppearance() != null && widget.getAppearance().getNormalAppearance() != null) {
                    count++;
                }
            }
        }
        return count;
    }

    private static int occurrences(byte[] content, String token) {
        var text = new String(content, StandardCharsets.ISO_8859_1);
        int count = 0;
        for (int index = text.indexOf(token); index >= 0; index = text.indexOf(token, index + token.length())) {
            count++;
        }
        return count;
    }
}
