package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.spi.DSSUtils;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.fixup.AcroFormDefaultFixup;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Gives the form fields of an unsigned PDF real appearance streams before a PAdES signature.
 *
 * A PDF whose AcroForm says /NeedAppearances true asks the viewer to redraw its fields.
 * Acrobat then shows no signature at all for a PAdES signature of it (an empty Signatures
 * panel, verified 2026-10-02 with a JSF web form export), although the signature itself is
 * valid. PDFBox's stock AcroForm fixup supplies a default /DA and /DR (Helv, ZaDb) when the
 * form has none, builds every field's appearance and clears the flag; the result is
 * appended as an incremental update, so the original revision stays a verbatim prefix.
 *
 * An already signed PDF, an encrypted one, a PDF without the flag, and a form whose
 * appearances PDFBox cannot build all come back unchanged: a signed PDF must stay
 * byte-identical, and clearing the flag without appearances would change what a viewer draws.
 */
public final class PdfFormAppearances {
    private static final Logger logger = LoggerFactory.getLogger(PdfFormAppearances.class);

    private PdfFormAppearances() {
    }

    public static DSSDocument withGeneratedAppearances(DSSDocument document) {
        var source = DSSUtils.toByteArray(document);
        var prepared = withGeneratedAppearances(source);
        if (prepared == source) {
            return document;
        }
        return new InMemoryDocument(prepared, document.getName(), document.getMimeType());
    }

    public static byte[] withGeneratedAppearances(byte[] pdf) {
        if (!hasPdfHeader(pdf) || contains(pdf, "/ByteRange")) {
            return pdf;
        }
        try (var document = Loader.loadPDF(pdf)) {
            if (document.isEncrypted() || !document.getSignatureDictionaries().isEmpty()) {
                return pdf;
            }
            var catalog = document.getDocumentCatalog();
            var acroForm = catalog.getAcroForm(null);
            if (acroForm == null || !acroForm.getNeedAppearances()) {
                return pdf;
            }
            acroForm = catalog.getAcroForm(new AcroFormDefaultFixup(document));
            if (acroForm == null || acroForm.getNeedAppearances()) {
                logger.warn("Form field appearances could not be generated; NeedAppearances stays set");
                return pdf;
            }
            var output = new ByteArrayOutputStream();
            document.saveIncremental(output);
            return output.toByteArray();
        } catch (Exception exception) {
            logger.warn("Form field appearances could not be generated: {}", exception.toString());
            return pdf;
        }
    }

    private static boolean hasPdfHeader(byte[] content) {
        return content.length >= 5 && "%PDF-".equals(new String(content, 0, 5, StandardCharsets.ISO_8859_1));
    }

    private static boolean contains(byte[] content, String token) {
        return new String(content, StandardCharsets.ISO_8859_1).contains(token);
    }
}
