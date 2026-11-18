package digital.slovensko.autogram.core;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.pdfa.PDFAStructureValidator;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.common.PDNameTreeNode;
import org.apache.pdfbox.pdmodel.common.filespecification.PDComplexFileSpecification;
import org.apache.pdfbox.pdmodel.common.filespecification.PDFileSpecification;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotationFileAttachment;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
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
        Integer pages = null;
        var embeddedNames = new JsonArray();
        try (PDDocument document = Loader.loadPDF(pdf)) {
            pages = document.getNumberOfPages();
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
            embeddedFileNames(document).forEach(embeddedNames::add);
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
        if (pages != null) facts.addProperty("pages", pages);
        facts.add("embeddedFileNames", embeddedNames);
        return facts;
    }

    public static JsonObject read(DSSDocument pdf) {
        try (var stream = pdf.openStream()) {
            return read(stream.readAllBytes());
        } catch (IOException exception) {
            throw new java.io.UncheckedIOException(exception);
        }
    }

    /// The names of the files the PDF embeds (the EmbeddedFiles name tree, then file attachment
    /// annotations), each once, in the order found.
    static List<String> embeddedFileNames(PDDocument document) throws IOException {
        var names = new LinkedHashSet<String>();
        var dictionary = document.getDocumentCatalog().getNames();
        if (dictionary != null && dictionary.getEmbeddedFiles() != null) {
            collectNames(dictionary.getEmbeddedFiles(), names, 0);
        }
        for (var page : document.getPages()) {
            for (var annotation : page.getAnnotations()) {
                if (annotation instanceof PDAnnotationFileAttachment attachment) {
                    var name = fileName(attachment.getFile(), null);
                    if (name != null) names.add(name);
                }
            }
        }
        return new ArrayList<>(names);
    }

    private static void collectNames(PDNameTreeNode<PDComplexFileSpecification> node, Set<String> names, int depth)
            throws IOException {
        if (depth > 32) return;
        var entries = node.getNames();
        if (entries != null) {
            for (var entry : entries.entrySet()) {
                var name = fileName(entry.getValue(), entry.getKey());
                if (name != null) names.add(name);
            }
        }
        var kids = node.getKids();
        if (kids != null) {
            for (var kid : kids) {
                collectNames(kid, names, depth + 1);
            }
        }
    }

    private static String fileName(PDFileSpecification specification, String fallback) {
        String name = null;
        if (specification instanceof PDComplexFileSpecification complex) {
            name = complex.getFileUnicode();
            if (name == null || name.isBlank()) name = complex.getFile();
        } else if (specification != null) {
            name = specification.getFile();
        }
        if (name == null || name.isBlank()) name = fallback;
        return name == null || name.isBlank() ? null : name;
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
