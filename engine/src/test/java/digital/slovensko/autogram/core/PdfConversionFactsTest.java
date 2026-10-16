package digital.slovensko.autogram.core;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.PDDocumentNameDictionary;
import org.apache.pdfbox.pdmodel.PDEmbeddedFilesNameTreeNode;
import org.apache.pdfbox.pdmodel.common.filespecification.PDComplexFileSpecification;
import org.apache.pdfbox.pdmodel.common.filespecification.PDEmbeddedFile;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PdfConversionFactsTest {
    private static final String ICC = "/System/Library/ColorSync/Profiles/sRGB Profile.icc";

    @TempDir
    Path temporary;

    private byte[] normalized(byte[] pdf) throws Exception {
        var input = temporary.resolve("in.pdf");
        var output = temporary.resolve("out.pdf");
        Files.write(input, pdf);
        PdfaNormalize.normalize(input.toFile(), output.toFile(), new File(ICC), "Test");
        return Files.readAllBytes(output);
    }

    @Test
    void plainPdfIsNotPdfa() throws Exception {
        var facts = PdfConversionFacts.read(ConversionTestPdfs.samplePdf());
        assertFalse(facts.get("pdfaCompliant").getAsBoolean());
        assertFalse(facts.has("declaredPdfaPart"));
        assertFalse(facts.get("hasEmbeddedFiles").getAsBoolean());
    }

    @Test
    /// PdfaNormalize only declares PDF/A and adds the OutputIntent; a standard font it does not
    /// embed keeps the file from being PDF/A, which is why E→E checks with veraPDF.
    void normalizerDeclaresPdfaButDoesNotEmbedFonts() throws Exception {
        var facts = PdfConversionFacts.read(normalized(ConversionTestPdfs.withText("Zmluva")));
        assertEquals(2, facts.get("declaredPdfaPart").getAsInt());
        assertEquals("B", facts.get("declaredPdfaConformance").getAsString());
        assertFalse(facts.get("pdfaCompliant").getAsBoolean());
        assertTrue(facts.getAsJsonArray("pdfaErrors").toString().contains("font"), facts.toString());
    }

    @Test
    void pdfaWithAttachmentIsNotKeepable() throws Exception {
        var pdf = normalized(ConversionTestPdfs.withText("Zmluva"));
        try (var document = Loader.loadPDF(pdf)) {
            var embedded = new PDEmbeddedFile(document, new ByteArrayInputStream("príloha".getBytes()));
            var specification = new PDComplexFileSpecification();
            specification.setFile("priloha.txt");
            specification.setEmbeddedFile(embedded);
            var tree = new PDEmbeddedFilesNameTreeNode();
            tree.setNames(Map.of("priloha.txt", specification));
            var names = new PDDocumentNameDictionary(document.getDocumentCatalog());
            names.setEmbeddedFiles(tree);
            document.getDocumentCatalog().setNames(names);
            var output = new ByteArrayOutputStream();
            document.save(output);
            pdf = output.toByteArray();
        }
        assertTrue(PdfConversionFacts.read(pdf).get("hasEmbeddedFiles").getAsBoolean());
    }
}
