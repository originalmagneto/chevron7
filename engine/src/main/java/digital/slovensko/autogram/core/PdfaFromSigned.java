package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.FileDocument;
import eu.europa.esig.dss.pdfa.PDFAStructureValidator;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.graphics.image.JPEGFactory;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotationFileAttachment;
import org.apache.pdfbox.rendering.ImageType;
import org.apache.pdfbox.rendering.PDFRenderer;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

/**
 * Turns an original that may not stay byte for byte in a guaranteed conversion (E→E) into a
 * new PDF/A-2b: the signatures and their permissions go, every form field and visible
 * signature stamp is flattened into page content so the visible information content stays,
 * embedded files and scripts go, then {@link PdfaNormalize} writes the PDF/A identification
 * and veraPDF (DSS's {@link PDFAStructureValidator}) decides whether the result is PDF/A.
 *
 * <p>Usage: {@code PdfaFromSigned <in.pdf> <out.pdf> <iccProfile> <title> [--raster]}. Exit 0:
 * written and compliant; 3: written but not compliant (veraPDF messages on stderr); 2: input
 * unreadable; 1: anything else. {@code --raster} renders every page to an image first, for a
 * source whose fonts cannot be made compliant.
 */
public final class PdfaFromSigned {
    static final int RASTER_DPI = 200;

    private PdfaFromSigned() {
    }

    public record Result(boolean compliant, List<String> errors) {
    }

    public static void main(String[] args) {
        if (args.length < 4 || args.length > 5 || (args.length == 5 && !args[4].equals("--raster"))) {
            System.err.println("Usage: PdfaFromSigned <in.pdf> <out.pdf> <iccProfile> <title> [--raster]");
            System.exit(1);
        }
        try {
            var result = convert(new File(args[0]), new File(args[1]), new File(args[2]), args[3], args.length == 5);
            if (!result.compliant()) {
                result.errors().stream().limit(5).forEach(System.err::println);
                System.exit(3);
            }
            System.exit(0);
        } catch (IOException exception) {
            System.err.println("PdfaFromSigned: " + exception.getClass().getSimpleName());
            System.exit(2);
        } catch (Exception exception) {
            System.err.println("PdfaFromSigned: " + exception.getClass().getSimpleName());
            System.exit(1);
        }
    }

    public static Result convert(File input, File output, File iccProfile, String title, boolean raster)
            throws Exception {
        var intermediate = Files.createTempFile("pdfa-from-signed", ".pdf").toFile();
        try {
            try (PDDocument source = Loader.loadPDF(input)) {
                if (raster) {
                    try (var rendered = rasterized(source)) {
                        rendered.save(intermediate);
                    }
                } else {
                    stripAndFlatten(source);
                    source.save(intermediate);
                }
            }
            PdfaNormalize.normalize(intermediate, output, iccProfile, title);
            var check = new PDFAStructureValidator().validate(new FileDocument(output));
            return new Result(check.isCompliant(), List.copyOf(check.getErrorMessages()));
        } finally {
            Files.deleteIfExists(intermediate.toPath());
        }
    }

    static void stripAndFlatten(PDDocument document) throws IOException {
        if (document.isEncrypted()) {
            document.setAllSecurityToBeRemoved(true);
        }
        var catalog = document.getDocumentCatalog();
        var form = catalog.getAcroForm(null);
        if (form != null) {
            for (var field : form.getFieldTree()) {
                if (field instanceof org.apache.pdfbox.pdmodel.interactive.form.PDSignatureField) {
                    field.getCOSObject().removeItem(COSName.V);
                    field.getCOSObject().removeItem(COSName.getPDFName("Lock"));
                    field.getCOSObject().removeItem(COSName.getPDFName("SV"));
                }
            }
            if (form.getNeedAppearances()) {
                form.refreshAppearances();
            }
            form.flatten();
            form.getCOSObject().removeItem(COSName.SIG_FLAGS);
            catalog.getCOSObject().removeItem(COSName.ACRO_FORM);
        }
        catalog.getCOSObject().removeItem(COSName.PERMS);
        catalog.getCOSObject().removeItem(COSName.getPDFName("DSS"));
        catalog.getCOSObject().removeItem(COSName.AA);
        catalog.getCOSObject().removeItem(COSName.OPEN_ACTION);
        var names = catalog.getNames();
        if (names != null) {
            names.setEmbeddedFiles(null);
            names.setJavascript(null);
        }
        catalog.getCOSObject().removeItem(COSName.getPDFName("AF"));
        for (var page : document.getPages()) {
            page.getCOSObject().removeItem(COSName.AA);
            var kept = new ArrayList<org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotation>();
            for (var annotation : page.getAnnotations()) {
                if (!(annotation instanceof PDAnnotationFileAttachment)) {
                    kept.add(annotation);
                }
            }
            page.setAnnotations(kept);
        }
    }

    static PDDocument rasterized(PDDocument source) throws IOException {
        var renderer = new PDFRenderer(source);
        var target = new PDDocument();
        for (var index = 0; index < source.getNumberOfPages(); index++) {
            var box = source.getPage(index).getMediaBox();
            var image = renderer.renderImageWithDPI(index, RASTER_DPI, ImageType.RGB);
            var page = new PDPage(new PDRectangle(box.getWidth(), box.getHeight()));
            target.addPage(page);
            var xObject = JPEGFactory.createFromImage(target, image, 0.9f, RASTER_DPI);
            try (var content = new PDPageContentStream(target, page)) {
                content.drawImage(xObject, 0, 0, box.getWidth(), box.getHeight());
            }
        }
        return target;
    }
}
