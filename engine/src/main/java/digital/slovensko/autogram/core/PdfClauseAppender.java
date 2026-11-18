package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.pdfa.PDFAStructureValidator;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSArray;
import org.apache.pdfbox.cos.COSDictionary;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.multipdf.PDFCloneUtility;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDDocumentNameDictionary;
import org.apache.pdfbox.pdmodel.PDEmbeddedFilesNameTreeNode;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDResources;
import org.apache.pdfbox.pdmodel.common.PDMetadata;
import org.apache.pdfbox.pdmodel.common.PDNameTreeNode;
import org.apache.pdfbox.pdmodel.common.filespecification.PDComplexFileSpecification;
import org.apache.pdfbox.pdmodel.common.filespecification.PDEmbeddedFile;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageFitDestination;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.outline.PDDocumentOutline;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Calendar;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Appends the osvedčovacia doložka of a guaranteed conversion to the new document, a PDF/A,
 * as one incremental update: the clause's own pages after every content page, the clause XDC
 * as an associated file ({@code /EmbeddedFiles} and the catalog's {@code /AF}, relationship
 * {@code /Supplement}), an outline item pointing at the first clause page, and the XMP
 * identification raised to PDF/A-3b, the part that allows an embedded file of any type.
 *
 * <p>The source bytes stay an exact prefix of the result: their SHA-256 is the fingerprint the
 * clause names, so nothing in the first revision may change. The clause pages are not hashed,
 * so their images lose interpolation here ({@link ImageInterpolation}), which PDF/A forbids.
 *
 * <p>veraPDF (DSS's {@link PDFAStructureValidator}) checks the result; the caller decides what
 * a refusal means. A signed or encrypted source is refused, because appending would invalidate
 * its signatures or need its key.
 *
 * <p>Usage (check only, writes nothing):
 * {@code PdfClauseAppender <source.pdf> <pages.pdf> <attachment> <name> <mimeType>}. Exit 0: the
 * result is PDF/A-3b; 3: it is not (up to five veraPDF messages on stderr); 2: an input is
 * unreadable or refused; 1: anything else.
 */
public final class PdfClauseAppender {
    public static final String OUTLINE_TITLE = "Osvedčovacia doložka";
    static final String PDFA_PROFILE = "PDF/A-3B";

    private static final COSName SUPPLEMENT = COSName.getPDFName("Supplement");
    private static final Pattern PART_ATTRIBUTE = Pattern.compile("(pdfaid:part\\s*=\\s*[\"'])\\s*\\d+\\s*([\"'])");
    private static final Pattern PART_ELEMENT = Pattern.compile("(<pdfaid:part>)\\s*\\d+\\s*(</pdfaid:part>)");
    private static final Pattern CONFORMANCE_ATTRIBUTE =
            Pattern.compile("(pdfaid:conformance\\s*=\\s*[\"'])\\s*[A-Za-z]+\\s*([\"'])");
    private static final Pattern CONFORMANCE_ELEMENT =
            Pattern.compile("(<pdfaid:conformance>)\\s*[A-Za-z]+\\s*(</pdfaid:conformance>)");

    private PdfClauseAppender() {
    }

    public record Attachment(String name, String mimeType, byte[] content) {
    }

    public record Result(byte[] pdf, int addedPages, boolean pdfaCompliant, List<String> pdfaErrors) {
    }

    public static void main(String[] args) {
        System.exit(run(args, System.err));
    }

    /** The command line's answer as its exit code; reasons go to {@code errors}, nothing is written. */
    static int run(String[] args, PrintStream errors) {
        if (args.length != 5) {
            errors.println("Usage: PdfClauseAppender <source.pdf> <pages.pdf> <attachment> <name> <mimeType>");
            return 1;
        }
        Result result;
        try {
            result = append(Files.readAllBytes(new File(args[0]).toPath()),
                    Files.readAllBytes(new File(args[1]).toPath()),
                    new Attachment(args[3], args[4], Files.readAllBytes(new File(args[2]).toPath())));
        } catch (IOException exception) {
            errors.println("PdfClauseAppender: " + exception.getClass().getSimpleName());
            return 2;
        } catch (Exception exception) {
            errors.println("PdfClauseAppender: " + exception.getClass().getSimpleName());
            return 1;
        }
        if (!result.pdfaCompliant()) {
            result.pdfaErrors().stream().limit(5).forEach(errors::println);
            return 3;
        }
        return 0;
    }

    public static Result append(byte[] source, byte[] clausePages, Attachment attachment) throws IOException {
        if (attachment == null || attachment.name() == null || attachment.name().isBlank()
                || attachment.mimeType() == null || attachment.mimeType().isBlank() || attachment.content() == null) {
            throw new IOException("The clause attachment needs a name, a MIME type and content");
        }
        if (contains(source, "/ByteRange")) {
            throw new IOException("The source carries a signature; appending would invalidate it");
        }
        byte[] output;
        int addedPages;
        try (var document = Loader.loadPDF(source); var pages = Loader.loadPDF(clausePages)) {
            if (document.isEncrypted()) {
                throw new IOException("The source is encrypted");
            }
            if (!document.getSignatureDictionaries().isEmpty()) {
                throw new IOException("The source carries a signature; appending would invalidate it");
            }
            if (pages.getNumberOfPages() == 0) {
                throw new IOException("The clause has no pages");
            }
            var catalog = document.getDocumentCatalog();
            var changed = Collections.newSetFromMap(new IdentityHashMap<COSDictionary, Boolean>());
            changed.add(catalog.getCOSObject());

            var firstClausePage = importPages(document, pages, changed);
            addedPages = pages.getNumberOfPages();
            attach(document, attachment, changed);
            addOutlineItem(document, firstClausePage, changed);
            declarePdfa3b(document);

            for (var dictionary : changed) {
                dictionary.setNeedToBeUpdated(true);
            }
            var buffer = new ByteArrayOutputStream(source.length + clausePages.length + attachment.content().length);
            document.saveIncremental(buffer, changed);
            output = buffer.toByteArray();
        }
        if (output.length <= source.length || !Arrays.equals(output, 0, source.length, source, 0, source.length)) {
            throw new IOException("The incremental update did not keep the source as its prefix");
        }
        var errors = pdfaErrors(output);
        return new Result(output, addedPages, errors.isEmpty(), errors);
    }

    /**
     * Why veraPDF does not accept {@code pdf} as PDF/A-3b; empty when it does. The same check
     * runs on the appended document before it is signed and on the signed output.
     */
    public static List<String> pdfaErrors(byte[] pdf) {
        var check = new PDFAStructureValidator().validate(new InMemoryDocument(pdf));
        var profileMatches = PDFA_PROFILE.equals(check.getProfileId());
        if (check.isCompliant() && profileMatches) {
            return List.of();
        }
        var errors = new ArrayList<String>();
        if (check.getErrorMessages() != null) {
            errors.addAll(check.getErrorMessages());
        }
        if (!profileMatches) {
            errors.add("veraPDF validated the result as " + check.getProfileId() + ", not " + PDFA_PROFILE);
        }
        if (errors.isEmpty()) {
            errors.add("veraPDF did not accept the result as " + PDFA_PROFILE);
        }
        return List.copyOf(errors);
    }

    /**
     * Copies each clause page into the source as a fresh page: media and crop box, rotation, a
     * deep copy of its resources and contents and, if present, its transparency group. The
     * page's parent, annotations and anything else that ties it to the clause document stay
     * behind, so the copy reaches only new objects.
     */
    private static PDPage importPages(PDDocument document, PDDocument pages, Set<COSDictionary> changed)
            throws IOException {
        var cloner = new PDFCloneUtility(document) {
        };
        PDPage first = null;
        for (var page : pages.getPages()) {
            // Annotations are deliberately not copied: the rendered clause has none.
            var copy = new PDPage(page.getMediaBox());
            if (page.getCOSObject().containsKey(COSName.CROP_BOX)) {
                copy.setCropBox(page.getCropBox());
            }
            if (page.getRotation() != 0) {
                copy.setRotation(page.getRotation());
            }
            var resources = page.getResources();
            copy.setResources(resources == null ? new PDResources()
                    : new PDResources(cloner.cloneForNewDocument(resources.getCOSObject())));
            var contents = page.getCOSObject().getDictionaryObject(COSName.CONTENTS);
            if (contents != null) {
                copy.getCOSObject().setItem(COSName.CONTENTS, cloner.cloneForNewDocument(contents));
            }
            var group = page.getCOSObject().getDictionaryObject(COSName.GROUP);
            if (group != null) {
                copy.getCOSObject().setItem(COSName.GROUP, cloner.cloneForNewDocument(group));
            }
            ImageInterpolation.clear(copy.getCOSObject());
            document.addPage(copy);
            if (first == null) {
                first = copy;
            }
        }
        // addPage changes the root of the page tree (its /Kids and /Count).
        changed.add(document.getPages().getCOSObject());
        return first;
    }

    private static void attach(PDDocument document, Attachment attachment, Set<COSDictionary> changed)
            throws IOException {
        var now = Calendar.getInstance();
        var file = new PDEmbeddedFile(document, new ByteArrayInputStream(attachment.content()));
        file.setSubtype(attachment.mimeType());
        file.setSize(attachment.content().length);
        file.setCreationDate(now);
        file.setModDate(now);

        var specification = new PDComplexFileSpecification();
        specification.setFile(attachment.name());
        specification.setFileUnicode(attachment.name());
        specification.setEmbeddedFile(file);
        specification.setEmbeddedFileUnicode(file);
        specification.setFileDescription(OUTLINE_TITLE);
        specification.getCOSObject().setItem(COSName.AF_RELATIONSHIP, SUPPLEMENT);
        // Referenced from the name tree and from /AF: one object, not two inline copies.
        specification.getCOSObject().setDirect(false);

        var catalog = document.getDocumentCatalog();
        var names = catalog.getNames();
        if (names == null) {
            names = new PDDocumentNameDictionary(catalog);
            catalog.setNames(names);
        }
        changed.add(names.getCOSObject());

        var entries = new LinkedHashMap<String, PDComplexFileSpecification>();
        var existing = names.getEmbeddedFiles();
        if (existing != null) {
            collect(existing, entries);
        }
        if (entries.containsKey(attachment.name())) {
            throw new IOException("The source already embeds a file named " + attachment.name());
        }
        entries.put(attachment.name(), specification);
        var tree = new PDEmbeddedFilesNameTreeNode();
        tree.setNames(entries);
        names.setEmbeddedFiles(tree);

        // Always a new direct array in the catalog, which this update writes anyway; an
        // indirect /AF array of the source is copied rather than changed in place.
        var files = new COSArray();
        if (catalog.getCOSObject().getDictionaryObject(COSName.AF) instanceof COSArray existingFiles) {
            for (var entry : existingFiles) {
                files.add(entry);
            }
        }
        files.add(specification.getCOSObject());
        catalog.getCOSObject().setItem(COSName.AF, files);
    }

    private static void collect(PDNameTreeNode<PDComplexFileSpecification> node,
                                Map<String, PDComplexFileSpecification> entries) throws IOException {
        var names = node.getNames();
        if (names != null) {
            entries.putAll(names);
        }
        var kids = node.getKids();
        if (kids != null) {
            for (var kid : kids) {
                collect(kid, entries);
            }
        }
    }

    private static void addOutlineItem(PDDocument document, PDPage target, Set<COSDictionary> changed) {
        var catalog = document.getDocumentCatalog();
        var outline = catalog.getDocumentOutline();
        if (outline == null) {
            outline = new PDDocumentOutline();
            catalog.setDocumentOutline(outline);
        }
        var previousLast = outline.getLastChild();
        if (previousLast != null) {
            changed.add(previousLast.getCOSObject());
        }
        changed.add(outline.getCOSObject());

        var destination = new PDPageFitDestination();
        destination.setPage(target);
        var item = new PDOutlineItem();
        item.setTitle(OUTLINE_TITLE);
        item.setDestination(destination);
        outline.addLast(item);
    }

    private static void declarePdfa3b(PDDocument document) throws IOException {
        var catalog = document.getDocumentCatalog();
        var metadata = catalog.getMetadata();
        if (metadata == null) {
            throw new IOException("The source has no XMP metadata, so it is not PDF/A");
        }
        String packet;
        try (var input = metadata.exportXMPMetadata()) {
            packet = new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
        var raised = replace(packet, PART_ATTRIBUTE, PART_ELEMENT, "3");
        if (raised == null) {
            throw new IOException("The source's XMP metadata names no PDF/A part");
        }
        var conformed = replace(raised, CONFORMANCE_ATTRIBUTE, CONFORMANCE_ELEMENT, "B");
        if (conformed == null) {
            throw new IOException("The source's XMP metadata names no PDF/A conformance level");
        }
        // A new, unfiltered stream: PDF/A forbids a filter on the metadata stream.
        var updated = new PDMetadata(document, new ByteArrayInputStream(conformed.getBytes(StandardCharsets.UTF_8)));
        updated.getCOSObject().setName(COSName.TYPE, "Metadata");
        updated.getCOSObject().setName(COSName.SUBTYPE, "XML");
        catalog.setMetadata(updated);
    }

    /** Replaces the value in whichever XMP form the packet uses; null when it uses neither. */
    private static String replace(String packet, Pattern attribute, Pattern element, String value) {
        var byAttribute = attribute.matcher(packet);
        if (byAttribute.find()) {
            return byAttribute.replaceAll("$1" + value + "$2");
        }
        var byElement = element.matcher(packet);
        if (byElement.find()) {
            return byElement.replaceAll("$1" + value + "$2");
        }
        return null;
    }

    private static boolean contains(byte[] haystack, String needle) {
        var pattern = needle.getBytes(StandardCharsets.ISO_8859_1);
        outer:
        for (var index = 0; index <= haystack.length - pattern.length; index++) {
            for (var offset = 0; offset < pattern.length; offset++) {
                if (haystack[index + offset] != pattern[offset]) {
                    continue outer;
                }
            }
            return true;
        }
        return false;
    }
}
