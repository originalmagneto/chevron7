package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.pdfa.PDFAStructureValidator;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSArray;
import org.apache.pdfbox.cos.COSBase;
import org.apache.pdfbox.cos.COSDictionary;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.cos.COSObject;
import org.apache.pdfbox.cos.COSStream;
import org.apache.pdfbox.pdfwriter.compress.CompressParameters;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDDocumentNameDestinationDictionary;
import org.apache.pdfbox.pdmodel.PDDocumentNameDictionary;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.common.filespecification.PDComplexFileSpecification;
import org.apache.pdfbox.pdmodel.encryption.AccessPermission;
import org.apache.pdfbox.pdmodel.encryption.StandardProtectionPolicy;
import org.apache.pdfbox.pdmodel.font.PDType1Font;
import org.apache.pdfbox.pdmodel.font.Standard14Fonts;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageDestination;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageFitDestination;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.outline.PDDocumentOutline;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem;
import org.apache.pdfbox.text.PDFTextStripper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PdfClauseAppenderTest {
    private static final File ICC = new File("/System/Library/ColorSync/Profiles/sRGB Profile.icc");
    private static final String XDC_MIME = "application/vnd.gov.sk.xmldatacontainer+xml";
    private static final String CLAUSE_NAME = "1563-261016-7.xml.xdcf";

    @TempDir
    Path temporary;

    private static byte[] resource(String name) throws IOException {
        try (var stream = Objects.requireNonNull(PdfClauseAppenderTest.class
                .getResourceAsStream("/digital/slovensko/autogram/core/" + name), name)) {
            return stream.readAllBytes();
        }
    }

    private static byte[] finalPdf() throws IOException {
        return resource("zako-p2e-final.pdf");
    }

    private static byte[] p2ePages() throws IOException {
        return resource("clause-pages-p2e.pdf");
    }

    private static PdfClauseAppender.Attachment clause() throws IOException {
        return new PdfClauseAppender.Attachment(CLAUSE_NAME, XDC_MIME, resource("clause-p2e.xdcf"));
    }

    private static PdfClauseAppender.Result appendP2E() throws IOException {
        return PdfClauseAppender.append(finalPdf(), p2ePages(), clause());
    }

    private static int pageCount(byte[] pdf) throws IOException {
        try (var document = Loader.loadPDF(pdf)) {
            return document.getNumberOfPages();
        }
    }

    private static int countOf(byte[] haystack, int from, String needle) {
        var text = new String(haystack, from, haystack.length - from, StandardCharsets.ISO_8859_1);
        var count = 0;
        for (var index = text.indexOf(needle); index >= 0; index = text.indexOf(needle, index + needle.length())) {
            count++;
        }
        return count;
    }

    @Test
    void appendKeepsSourceAsBytePrefix() throws Exception {
        var source = finalPdf();

        var result = appendP2E();

        assertTrue(result.pdf().length > source.length);
        assertTrue(Arrays.equals(result.pdf(), 0, source.length, source, 0, source.length),
                "revision 1 is the fingerprinted content and must stay byte for byte");
    }

    /** One incremental update, which carries only the new objects, never the source again. */
    @Test
    void appendWritesOneSmallRevision() throws Exception {
        var source = finalPdf();
        var pages = p2ePages();
        var attachment = clause();

        var result = PdfClauseAppender.append(source, pages, attachment);

        assertEquals(1, countOf(result.pdf(), source.length, "%%EOF"), "exactly one revision after the source");
        var tail = result.pdf().length - source.length;
        assertTrue(tail > attachment.content().length, "the tail carries at least the attachment");
        assertTrue(tail < pages.length + attachment.content().length + 16 * 1024,
                "the tail must not repeat the source: " + tail + " bytes");
    }

    @Test
    void appendAddsClausePagesAtTheEnd() throws Exception {
        var source = finalPdf();
        var pages = p2ePages();

        var result = appendP2E();

        var sourcePages = pageCount(source);
        var clausePages = pageCount(pages);
        assertEquals(clausePages, result.addedPages());
        assertEquals(sourcePages + clausePages, pageCount(result.pdf()));
        try (var document = Loader.loadPDF(result.pdf()); var expected = Loader.loadPDF(pages)) {
            for (var index = 0; index < clausePages; index++) {
                assertEquals(pageText(expected, index), pageText(document, sourcePages + index),
                        "clause page " + (index + 1) + " keeps its text");
            }
            // The form prints its title at the top of its first page, not on the last one.
            assertTrue(pageText(document, sourcePages).contains(PdfClauseAppender.OUTLINE_TITLE),
                    "the first clause page carries the clause's title");
            assertFalse(pageText(document, 0).contains(PdfClauseAppender.OUTLINE_TITLE),
                    "the content page stays without the clause");
        }
    }

    /** The clause pages are not hashed, so their images may and must lose interpolation. */
    @Test
    void importedClauseImagesDoNotInterpolate() throws Exception {
        assertTrue(interpolatingImages(p2ePages()) > 0, "the fixture's clause pages interpolate");

        var result = appendP2E();

        assertEquals(0, interpolatingImages(result.pdf()));
    }

    @Test
    void appendEmbedsClauseAsAssociatedFile() throws Exception {
        var attachment = clause();

        var result = appendP2E();

        try (var document = Loader.loadPDF(result.pdf())) {
            var catalog = document.getDocumentCatalog();
            var tree = catalog.getNames().getEmbeddedFiles();
            Map<String, PDComplexFileSpecification> entries = tree.getNames();
            assertEquals(List.of(CLAUSE_NAME), List.copyOf(entries.keySet()));
            var specification = entries.get(CLAUSE_NAME);
            assertEquals(CLAUSE_NAME, specification.getFileUnicode());
            assertEquals(CLAUSE_NAME, specification.getFile());
            assertEquals(COSName.getPDFName("Supplement"),
                    specification.getCOSObject().getCOSName(COSName.AF_RELATIONSHIP));
            var file = specification.getEmbeddedFile();
            assertEquals(XDC_MIME, file.getSubtype());
            assertEquals(attachment.content().length, file.getSize());
            assertNotNull(file.getModDate());
            assertArrayEquals(attachment.content(), file.toByteArray());

            var associated = (COSArray) catalog.getCOSObject().getDictionaryObject(COSName.AF);
            assertEquals(1, associated.size());
            assertSame(specification.getCOSObject(), associated.getObject(0),
                    "/AF and the name tree name the same file specification");
        }
    }

    @Test
    void appendAddsOutlineEntry() throws Exception {
        var sourcePages = pageCount(finalPdf());

        var result = appendP2E();

        try (var document = Loader.loadPDF(result.pdf())) {
            var outline = document.getDocumentCatalog().getDocumentOutline();
            var items = new ArrayList<PDOutlineItem>();
            outline.children().forEach(items::add);
            assertEquals(1, items.size());
            var item = items.get(0);
            assertEquals(PdfClauseAppender.OUTLINE_TITLE, item.getTitle());
            var destination = (PDPageDestination) item.getDestination();
            assertEquals(sourcePages, document.getPages().indexOf(destination.getPage()),
                    "the outline item opens the first clause page");
        }
    }

    @Test
    void appendDeclaresPdfa3b() throws Exception {
        var source = finalPdf();

        var result = appendP2E();

        try (var before = Loader.loadPDF(source); var after = Loader.loadPDF(result.pdf())) {
            var xmp = new String(after.getDocumentCatalog().getMetadata().toByteArray(), StandardCharsets.UTF_8);
            assertTrue(xmp.contains("pdfaid:part=\"3\""), xmp);
            assertTrue(xmp.contains("pdfaid:conformance=\"B\""), xmp);
            assertFalse(xmp.contains("pdfaid:part=\"2\""));
            var oldXmp = new String(before.getDocumentCatalog().getMetadata().toByteArray(), StandardCharsets.UTF_8);
            assertEquals(oldXmp.replace("pdfaid:part=\"2\"", "pdfaid:part=\"3\""), xmp,
                    "every other XMP property stays as it was");

            var oldIntents = before.getDocumentCatalog().getOutputIntents();
            var newIntents = after.getDocumentCatalog().getOutputIntents();
            assertEquals(oldIntents.size(), newIntents.size());
            for (var index = 0; index < oldIntents.size(); index++) {
                assertEquals(oldIntents.get(index).getOutputConditionIdentifier(),
                        newIntents.get(index).getOutputConditionIdentifier());
                try (var oldProfile = oldIntents.get(index).getDestOutputIntent().createInputStream();
                     var newProfile = newIntents.get(index).getDestOutputIntent().createInputStream()) {
                    assertArrayEquals(oldProfile.readAllBytes(), newProfile.readAllBytes());
                }
            }
        }
    }

    /** The element form of the XMP identification is raised as well as the attribute form. */
    @Test
    void appendRaisesTheElementFormOfThePdfaPart() throws Exception {
        var source = withMetadata(finalPdf(), metadata -> metadata.replaceFirst(
                "pdfaid:part=\"2\"\\s*pdfaid:conformance=\"B\"\\s*/>",
                "><pdfaid:part>2</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></rdf:Description>"));

        var result = PdfClauseAppender.append(source, p2ePages(), clause());

        try (var document = Loader.loadPDF(result.pdf())) {
            var xmp = new String(document.getDocumentCatalog().getMetadata().toByteArray(), StandardCharsets.UTF_8);
            assertTrue(xmp.contains("<pdfaid:part>3</pdfaid:part>"), xmp);
        }
        assertTrue(result.pdfaCompliant(), () -> String.join("\n", result.pdfaErrors()));
    }

    /** Today's real P→E document with its clause: the case the conversion depends on. */
    @Test
    void realP2EFinalPassesPdfa3b() throws Exception {
        var result = appendP2E();

        assertTrue(result.pdfaCompliant(), () -> String.join("\n", result.pdfaErrors()));
        assertTrue(result.pdfaErrors().isEmpty());
    }

    /** The new document alone is the PDF/A-2b it claims to be (it once failed rule 6.2.8-3). */
    @Test
    void p2eFinalAlonePassesPdfa2b() throws Exception {
        var check = new PDFAStructureValidator().validate(new InMemoryDocument(finalPdf()));

        assertTrue(check.isCompliant(), () -> String.join("\n", check.getErrorMessages()));
        assertEquals("PDF/A-2B", check.getProfileId());
    }

    @Test
    void e2eClausePassesPdfa3b() throws Exception {
        var source = convertedSignedSample(false);

        var result = PdfClauseAppender.append(source, resource("clause-pages-e2e.pdf"),
                new PdfClauseAppender.Attachment("dolozka.xml.xdcf", XDC_MIME, resource("clause-p2e.xdcf")));

        assertEquals(pageCount(source) + pageCount(resource("clause-pages-e2e.pdf")), pageCount(result.pdf()));
        assertTrue(result.pdfaCompliant(), () -> String.join("\n", result.pdfaErrors()));
    }

    /** A source whose cross-reference is a stream: the update must still only append. */
    @Test
    void xrefStreamSourceKeepsPrefix() throws Exception {
        byte[] source;
        try (var document = Loader.loadPDF(finalPdf())) {
            var output = new ByteArrayOutputStream();
            document.save(output, CompressParameters.DEFAULT_COMPRESSION);
            source = output.toByteArray();
        }
        assertTrue(countOf(source, 0, "/XRef") > 0, "the source must end in a cross-reference stream");

        var result = PdfClauseAppender.append(source, p2ePages(), clause());

        assertTrue(Arrays.equals(result.pdf(), 0, source.length, source, 0, source.length));
        assertEquals(pageCount(source) + pageCount(p2ePages()), pageCount(result.pdf()));
        assertTrue(result.pdfaCompliant(), () -> String.join("\n", result.pdfaErrors()));
    }

    /** The E→E raster route (veraPDF refused the vector conversion) as the content. */
    @Test
    void rasterSourcePassesPdfa3b() throws Exception {
        var source = convertedSignedSample(true);

        var result = PdfClauseAppender.append(source, p2ePages(), clause());

        assertTrue(Arrays.equals(result.pdf(), 0, source.length, source, 0, source.length));
        assertTrue(result.pdfaCompliant(), () -> String.join("\n", result.pdfaErrors()));
    }

    /** Bookmarks and named destinations the content already has survive the append. */
    @Test
    void sourceOutlineAndNamesSurvive() throws Exception {
        var source = withOutlineAndDestination(finalPdf());

        var result = PdfClauseAppender.append(source, p2ePages(), clause());

        try (var document = Loader.loadPDF(result.pdf())) {
            var catalog = document.getDocumentCatalog();
            var titles = new ArrayList<String>();
            catalog.getDocumentOutline().children().forEach(item -> titles.add(item.getTitle()));
            assertEquals(List.of("Zmluva", PdfClauseAppender.OUTLINE_TITLE), titles);
            assertNotNull(catalog.getNames().getDests().getValue("zaciatok"), "the named destination stays");
            assertEquals(1, catalog.getNames().getEmbeddedFiles().getNames().size());
        }
        assertTrue(result.pdfaCompliant(), () -> String.join("\n", result.pdfaErrors()));
    }

    /** Pages with fonts that are not embedded: veraPDF says no, and says why. */
    @Test
    void unembeddedFontPagesAreNotCompliant() throws Exception {
        var result = PdfClauseAppender.append(finalPdf(), helveticaPages(), clause());

        assertFalse(result.pdfaCompliant());
        assertFalse(result.pdfaErrors().isEmpty());
    }

    @Test
    void appendRefusesSignedOrEncryptedSource() throws Exception {
        var signed = ConversionTestPdfs.sign(finalPdf(), false);
        assertThrows(IOException.class, () -> PdfClauseAppender.append(signed, p2ePages(), clause()));

        byte[] encrypted;
        try (var document = Loader.loadPDF(finalPdf())) {
            var policy = new StandardProtectionPolicy("owner", "", new AccessPermission());
            policy.setEncryptionKeyLength(128);
            document.protect(policy);
            var output = new ByteArrayOutputStream();
            document.save(output);
            encrypted = output.toByteArray();
        }
        assertThrows(IOException.class, () -> PdfClauseAppender.append(encrypted, p2ePages(), clause()));
    }

    // MARK: - Helpers

    private static String pageText(PDDocument document, int index) throws IOException {
        var stripper = new PDFTextStripper();
        stripper.setStartPage(index + 1);
        stripper.setEndPage(index + 1);
        return stripper.getText(document);
    }

    private byte[] convertedSignedSample(boolean raster) throws Exception {
        var input = Files.write(temporary.resolve("signed-" + raster + ".pdf"),
                ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), true));
        var output = temporary.resolve("converted-" + raster + ".pdf");
        var conversion = PdfaFromSigned.convert(input.toFile(), output.toFile(), ICC, "Zmluva", raster);
        assertTrue(conversion.compliant(), () -> String.join("\n", conversion.errors()));
        return Files.readAllBytes(output);
    }

    private static byte[] withMetadata(byte[] pdf, java.util.function.UnaryOperator<String> change) throws IOException {
        try (var document = Loader.loadPDF(pdf)) {
            var metadata = document.getDocumentCatalog().getMetadata();
            var packet = new String(metadata.toByteArray(), StandardCharsets.UTF_8);
            var changed = change.apply(packet);
            assertFalse(packet.equals(changed), "the metadata change must apply");
            try (var output = metadata.getCOSObject().createOutputStream()) {
                output.write(changed.getBytes(StandardCharsets.UTF_8));
            }
            var buffer = new ByteArrayOutputStream();
            document.save(buffer, CompressParameters.NO_COMPRESSION);
            return buffer.toByteArray();
        }
    }

    private static byte[] withOutlineAndDestination(byte[] pdf) throws IOException {
        try (var document = Loader.loadPDF(pdf)) {
            var catalog = document.getDocumentCatalog();
            var outline = new PDDocumentOutline();
            var item = new PDOutlineItem();
            item.setTitle("Zmluva");
            var destination = new PDPageFitDestination();
            destination.setPage(document.getPage(0));
            item.setDestination(destination);
            outline.addLast(item);
            catalog.setDocumentOutline(outline);

            var names = new PDDocumentNameDictionary(catalog);
            var destinations = new PDDocumentNameDestinationDictionary(new COSDictionary());
            var named = new PDPageFitDestination();
            named.setPage(document.getPage(0));
            var entries = new COSArray();
            entries.add(new org.apache.pdfbox.cos.COSString("zaciatok"));
            entries.add(named);
            destinations.getCOSObject().setItem(COSName.NAMES, entries);
            names.getCOSObject().setItem(COSName.DESTS, destinations);
            catalog.setNames(names);

            var buffer = new ByteArrayOutputStream();
            document.save(buffer, CompressParameters.NO_COMPRESSION);
            return buffer.toByteArray();
        }
    }

    private static byte[] helveticaPages() throws IOException {
        try (var document = new PDDocument()) {
            var page = new PDPage(PDRectangle.A4);
            document.addPage(page);
            try (var content = new PDPageContentStream(document, page)) {
                content.beginText();
                content.setFont(new PDType1Font(Standard14Fonts.FontName.HELVETICA), 12);
                content.newLineAtOffset(72, 720);
                content.showText("Osvedcovacia dolozka");
                content.endText();
            }
            var output = new ByteArrayOutputStream();
            document.save(output);
            return output.toByteArray();
        }
    }

    /** Image XObjects reachable from the catalog that ask for interpolation. */
    private static int interpolatingImages(byte[] pdf) throws IOException {
        try (var document = Loader.loadPDF(pdf)) {
            var count = 0;
            var seen = Collections.newSetFromMap(new IdentityHashMap<COSBase, Boolean>());
            var pending = new ArrayDeque<COSBase>();
            pending.push(document.getDocumentCatalog().getCOSObject());
            while (!pending.isEmpty()) {
                var item = pending.pop();
                if (item instanceof COSObject reference) {
                    item = reference.getObject();
                }
                if (item == null || !seen.add(item)) {
                    continue;
                }
                if (item instanceof COSStream stream && COSName.IMAGE.equals(stream.getCOSName(COSName.SUBTYPE))
                        && stream.getBoolean(COSName.INTERPOLATE, false)) {
                    count++;
                }
                if (item instanceof COSDictionary dictionary) {
                    dictionary.getValues().forEach(pending::push);
                } else if (item instanceof COSArray array) {
                    array.forEach(pending::push);
                }
            }
            return count;
        }
    }
}
