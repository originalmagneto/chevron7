package digital.slovensko.autogram.core;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.pdfa.PDFAStructureValidator;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotationFileAttachment;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.regex.Pattern;

/**
 * What a guaranteed conversion (E→E) needs to know about a PDF before it may be kept byte for
 * byte as the new document: whether it is a valid PDF/A (vyhláška 70/2021 § 2 ods. 2 with
 * vyhláška 78/2020 § 46 ods. 2) and whether it carries embedded files (§ 46 ods. 2 písm. h)).
 */
public final class PdfConversionFacts {
    private static final Pattern PART = Pattern.compile("pdfaid:part(?:>|=\")\\s*(\\d)");
    private static final Pattern CONFORMANCE = Pattern.compile("pdfaid:conformance(?:>|=\")\\s*([A-Za-z])");

    private PdfConversionFacts() {
    }

    public static JsonObject read(byte[] pdf) {
        var facts = new JsonObject();
        Integer part = null;
        String conformance = null;
        var embedded = false;
        try (PDDocument document = Loader.loadPDF(pdf)) {
            var metadata = document.getDocumentCatalog().getMetadata();
            if (metadata != null) {
                try (var stream = metadata.exportXMPMetadata()) {
                    var xmp = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
                    var partMatch = PART.matcher(xmp);
                    if (partMatch.find()) part = Integer.parseInt(partMatch.group(1));
                    var conformanceMatch = CONFORMANCE.matcher(xmp);
                    if (conformanceMatch.find()) conformance = conformanceMatch.group(1).toUpperCase();
                }
            }
            embedded = hasEmbeddedFiles(document);
        } catch (IOException exception) {
            facts.addProperty("readable", false);
        }
        if (part != null) facts.addProperty("declaredPdfaPart", part);
        if (conformance != null) facts.addProperty("declaredPdfaConformance", conformance);
        var compliant = false;
        var errors = new JsonArray();
        if (part != null) {
            try {
                var result = new PDFAStructureValidator().validate(new InMemoryDocument(pdf));
                compliant = result.isCompliant();
                result.getErrorMessages().stream().limit(5).forEach(errors::add);
            } catch (RuntimeException exception) {
                errors.add("PDF/A validation failed: " + exception.getClass().getSimpleName());
            }
        }
        facts.addProperty("pdfaCompliant", compliant);
        facts.add("pdfaErrors", errors);
        facts.addProperty("hasEmbeddedFiles", embedded);
        return facts;
    }

    public static JsonObject read(DSSDocument pdf) {
        try (var stream = pdf.openStream()) {
            return read(stream.readAllBytes());
        } catch (IOException exception) {
            throw new java.io.UncheckedIOException(exception);
        }
    }

    static boolean hasEmbeddedFiles(PDDocument document) throws IOException {
        var names = document.getDocumentCatalog().getNames();
        if (names != null && names.getEmbeddedFiles() != null) {
            var tree = names.getEmbeddedFiles();
            if ((tree.getNames() != null && !tree.getNames().isEmpty())
                    || (tree.getKids() != null && !tree.getKids().isEmpty())) {
                return true;
            }
        }
        for (var page : document.getPages()) {
            for (var annotation : page.getAnnotations()) {
                if (annotation instanceof PDAnnotationFileAttachment) {
                    return true;
                }
            }
        }
        return false;
    }
}
