package digital.slovensko.autogram.core;

import org.apache.pdfbox.Loader;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.opentest4j.AssertionFailedError;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Objects;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/// The qpdf check is only worth something if it fails on a damaged file, so it is tested itself.
class QpdfCheckTest {
    @BeforeEach
    void needsQpdf() {
        Assumptions.assumeTrue(QpdfCheck.qpdf() != null, "qpdf is not installed");
    }

    private static byte[] sample() throws IOException {
        try (var stream = Objects.requireNonNull(QpdfCheckTest.class
                .getResourceAsStream("/digital/slovensko/autogram/sample.pdf"))) {
            return stream.readAllBytes();
        }
    }

    /// The page object 1 0 redefined as a catalog, with a cross-reference offset of 0.
    private static byte[] damaged(byte[] source) {
        var text = new String(source, StandardCharsets.ISO_8859_1)
                + "\n1 0 obj\n<< /Type /Catalog >>\nendobj\nstartxref\n0\n%%EOF\n";
        return text.getBytes(StandardCharsets.ISO_8859_1);
    }

    private static byte[] retitled(byte[] source) throws IOException {
        var output = new ByteArrayOutputStream();
        try (var document = Loader.loadPDF(source)) {
            document.getDocumentInformation().setTitle("Iný názov");
            document.getDocumentInformation().getCOSObject().setNeedToBeUpdated(true);
            document.saveIncremental(output);
        }
        return output.toByteArray();
    }

    @Test
    void cleanFilePasses() throws Exception {
        assertDoesNotThrow(() -> QpdfCheck.assertClean(sample(), "sample"));
    }

    @Test
    void damagedFileFailsWithQpdfsOwnWords() throws Exception {
        var failure = assertThrows(AssertionFailedError.class, () -> QpdfCheck.assertClean(damaged(sample()), "damaged"));
        assertTrue(failure.getMessage().contains("WARNING"), failure.getMessage());
    }

    @Test
    void anUpdateMayKeepTheWarningsItsSourceAlreadyHad() throws Exception {
        var source = damaged(sample());
        assertDoesNotThrow(() -> QpdfCheck.assertNoNewFindings(source, source, "same bytes"));
    }

    @Test
    void anUpdateMustNotAddAWarning() throws Exception {
        var source = sample();
        assertThrows(AssertionFailedError.class,
                () -> QpdfCheck.assertNoNewFindings(source, damaged(source), "new damage"));
        assertDoesNotThrow(() -> QpdfCheck.assertNoNewFindings(source, retitled(source), "clean update"));
    }
}
