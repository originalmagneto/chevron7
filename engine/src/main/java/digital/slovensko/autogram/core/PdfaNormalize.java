package digital.slovensko.autogram.core;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDDocumentCatalog;
import org.apache.pdfbox.pdmodel.common.PDMetadata;
import org.apache.pdfbox.pdfwriter.compress.CompressParameters;
import org.apache.pdfbox.pdmodel.graphics.color.PDOutputIntent;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;

/**
 * Rewrites a PDF as PDF/A-2B.
 *
 * The app reaches this from Swift after it has attached the osvedčovacia doložka
 * to an already converted PDF/A. That attachment is written as an incremental
 * update, which leaves the original cross-reference table and metadata in place:
 * a scan of the bytes still finds every PDF/A marker, so a string-level check
 * passes while an external validator such as Acrobat Preflight may not. Loading
 * the file here and saving it whole produces a single fresh page tree and one
 * cross-reference table, which is the artifact those validators actually read.
 *
 * Usage: PdfaNormalize &lt;input.pdf&gt; &lt;output.pdf&gt; &lt;sRGB.icc&gt; &lt;title&gt;
 */
public final class PdfaNormalize {
    private static final String PDFA_PART = "2";
    private static final String PDFA_CONFORMANCE = "B";

    private PdfaNormalize() {
    }

    public static void main(String[] args) {
        if (args.length < 3) {
            System.err.println("Usage: PdfaNormalize <input.pdf> <output.pdf> <sRGB.icc> [title]");
            System.exit(2);
            return;
        }

        var input = new File(args[0]);
        var output = new File(args[1]);
        var iccProfile = new File(args[2]);
        var title = args.length > 3 ? args[3] : "Dokument";

        try {
            normalize(input, output, iccProfile, title);
        } catch (Exception exception) {
            System.err.println("PdfaNormalize failed: " + exception);
            System.exit(1);
        }
    }

    static void normalize(File input, File output, File iccProfile, String title) throws Exception {
        try (var document = Loader.loadPDF(input)) {
            // PDF/A forbids encryption, and the source may carry a permissions
            // dictionary even when it opened without a password.
            if (document.isEncrypted()) {
                document.setAllSecurityToBeRemoved(true);
            }

            var information = document.getDocumentInformation();
            information.setTitle(title);
            if (information.getProducer() == null || information.getProducer().isBlank()) {
                information.setProducer("Autogram macOS");
            }

            var catalog = document.getDocumentCatalog();
            // PDF/A forbids image interpolation (rule 6.2.8-3), and scans and macOS PDFKit
            // image pages ask for it; without this the output claims PDF/A-2b and fails veraPDF.
            ImageInterpolation.clear(catalog.getCOSObject());
            applyOutputIntent(document, catalog, iccProfile);
            catalog.setMetadata(xmpMetadata(document, title, information.getProducer()));
            // An attached file must stay reachable through the catalog for PDF/A,
            // and the clause is exactly such a file. PDFBox carries /AF and
            // /AFRelationship through as COS entries, so this only guards against
            // a source that never had the catalog entry.
            if (catalog.getCOSObject().getDictionaryObject(COSName.getPDFName("AF")) == null
                    && catalog.getNames() != null && catalog.getNames().getEmbeddedFiles() != null) {
                System.err.println("PdfaNormalize: embedded files present without a catalog /AF entry");
            }

            // Written without object streams on purpose. PDF/A allows them, but
            // every consumer of this file - our own validator included - reads
            // the catalog by scanning the bytes, and an ObjStm hides
            // /OutputIntents, /AF and /AFRelationship from that scan. The file
            // grows a little; the alternative is a document that is valid and
            // reads as invalid.
            document.save(output, CompressParameters.NO_COMPRESSION);
        }
    }

    private static void applyOutputIntent(PDDocument document, PDDocumentCatalog catalog, File iccProfile)
            throws Exception {
        if (!catalog.getOutputIntents().isEmpty()) {
            return;
        }
        try (InputStream profile = new FileInputStream(iccProfile)) {
            var intent = new PDOutputIntent(document, profile);
            intent.setInfo("sRGB IEC61966-2.1");
            intent.setOutputCondition("sRGB IEC61966-2.1");
            intent.setOutputConditionIdentifier("sRGB IEC61966-2.1");
            intent.setRegistryName("http://www.color.org");
            catalog.addOutputIntent(intent);
        }
    }

    /**
     * Written by hand rather than through XMPBox: the packet is small, the exact
     * shape matters to the validators that read it, and this keeps the engine
     * free of another dependency.
     *
     * The identification uses the RDF attribute form, {@code pdfaid:part="2"},
     * rather than child elements. Both are valid XMP, but consumers here scan
     * the bytes for that literal.
     */
    private static PDMetadata xmpMetadata(PDDocument document, String title, String producer) throws Exception {
        var timestamp = ZonedDateTime.now().format(DateTimeFormatter.ISO_OFFSET_DATE_TIME);
        var packet = """
                <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
                <x:xmpmeta xmlns:x="adobe:ns:meta/">
                  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                    <rdf:Description rdf:about=""
                        xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"
                        pdfaid:part="%s"
                        pdfaid:conformance="%s"/>
                    <rdf:Description rdf:about=""
                        xmlns:dc="http://purl.org/dc/elements/1.1/">
                      <dc:title><rdf:Alt><rdf:li xml:lang="x-default">%s</rdf:li></rdf:Alt></dc:title>
                    </rdf:Description>
                    <rdf:Description rdf:about=""
                        xmlns:xmp="http://ns.adobe.com/xap/1.0/">
                      <xmp:CreateDate>%s</xmp:CreateDate>
                      <xmp:ModifyDate>%s</xmp:ModifyDate>
                      <xmp:CreatorTool>%s</xmp:CreatorTool>
                    </rdf:Description>
                    <rdf:Description rdf:about=""
                        xmlns:pdf="http://ns.adobe.com/pdf/1.3/">
                      <pdf:Producer>%s</pdf:Producer>
                    </rdf:Description>
                  </rdf:RDF>
                </x:xmpmeta>
                <?xpacket end="w"?>
                """.formatted(PDFA_PART, PDFA_CONFORMANCE, escape(title), timestamp, timestamp,
                escape(producer), escape(producer));

        var metadata = new PDMetadata(document,
                new ByteArrayInputStream(packet.getBytes(StandardCharsets.UTF_8)));
        metadata.getCOSObject().setName(COSName.TYPE, "Metadata");
        metadata.getCOSObject().setName(COSName.SUBTYPE, "XML");
        return metadata;
    }

    private static String escape(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }
}
