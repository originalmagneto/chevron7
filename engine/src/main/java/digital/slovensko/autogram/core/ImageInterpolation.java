package digital.slovensko.autogram.core;

import org.apache.pdfbox.contentstream.operator.Operator;
import org.apache.pdfbox.cos.COSArray;
import org.apache.pdfbox.cos.COSBase;
import org.apache.pdfbox.cos.COSDictionary;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.cos.COSObject;
import org.apache.pdfbox.cos.COSStream;
import org.apache.pdfbox.pdfparser.PDFStreamParser;
import org.apache.pdfbox.pdfwriter.ContentStreamWriter;

import java.io.IOException;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;

/**
 * Clears image interpolation, which PDF/A forbids (ISO 19005-2 and -3, rule 6.2.8-3: an image
 * dictionary's {@code /Interpolate} and an inline image's {@code /I} must be false when
 * present). Scans and macOS PDFKit image pages carry {@code /Interpolate true}.
 *
 * <p>The walk follows every object reachable from the given root, so images inside form
 * XObjects, patterns, Type 3 glyphs, soft masks and annotation appearances are reached too.
 * {@code /Parent} is never followed: started at a page, the walk stays within that page's own
 * objects. A content stream is rewritten only when it holds an inline image that interpolates;
 * every other stream keeps its bytes.
 */
final class ImageInterpolation {
    private ImageInterpolation() {
    }

    /** Clears interpolation on every image reachable from {@code root}; returns how many changed. */
    static int clear(COSBase root) throws IOException {
        var changed = 0;
        var seen = Collections.newSetFromMap(new IdentityHashMap<COSBase, Boolean>());
        var contentStreams = Collections.newSetFromMap(new IdentityHashMap<COSBase, Boolean>());
        var pending = new ArrayDeque<COSBase>();
        pending.push(root);
        while (!pending.isEmpty()) {
            var item = dereference(pending.pop());
            if (item == null || !seen.add(item)) {
                continue;
            }
            if (item instanceof COSStream stream) {
                if (COSName.IMAGE.equals(stream.getCOSName(COSName.SUBTYPE))) {
                    if (stream.getBoolean(COSName.INTERPOLATE, false)) {
                        stream.removeItem(COSName.INTERPOLATE);
                        changed++;
                    }
                } else if (contentStreams.contains(stream) || carriesContent(stream)) {
                    changed += clearInlineImages(stream);
                }
            }
            if (item instanceof COSDictionary dictionary) {
                markContentStreams(dictionary, contentStreams);
                for (var entry : dictionary.entrySet()) {
                    if (!COSName.PARENT.equals(entry.getKey())) {
                        pending.push(entry.getValue());
                    }
                }
            } else if (item instanceof COSArray array) {
                for (var element : array) {
                    pending.push(element);
                }
            }
        }
        return changed;
    }

    private static COSBase dereference(COSBase item) {
        return item instanceof COSObject reference ? reference.getObject() : item;
    }

    /** Form XObjects (annotation appearances included) and tiling patterns hold content. */
    private static boolean carriesContent(COSStream stream) {
        return COSName.FORM.equals(stream.getCOSName(COSName.SUBTYPE))
                || stream.getInt(COSName.PATTERN_TYPE) == 1;
    }

    /** Page contents, Type 3 glyph procedures and appearance streams without a subtype. */
    private static void markContentStreams(COSDictionary dictionary, Set<COSBase> contentStreams) {
        if (COSName.PAGE.equals(dictionary.getCOSName(COSName.TYPE))) {
            addStreams(dictionary.getDictionaryObject(COSName.CONTENTS), contentStreams);
        }
        if (dictionary.getDictionaryObject(COSName.CHAR_PROCS) instanceof COSDictionary procedures) {
            for (var procedure : procedures.getValues()) {
                addStreams(procedure, contentStreams);
            }
        }
        if (dictionary.getDictionaryObject(COSName.AP) instanceof COSDictionary appearances) {
            for (var appearance : appearances.getValues()) {
                var resolved = dereference(appearance);
                if (resolved instanceof COSStream) {
                    contentStreams.add(resolved);
                } else if (resolved instanceof COSDictionary states) {
                    for (var state : states.getValues()) {
                        addStreams(state, contentStreams);
                    }
                }
            }
        }
    }

    private static void addStreams(COSBase value, Set<COSBase> contentStreams) {
        var resolved = dereference(value);
        if (resolved instanceof COSStream) {
            contentStreams.add(resolved);
        } else if (resolved instanceof COSArray array) {
            for (var element : array) {
                if (dereference(element) instanceof COSStream stream) {
                    contentStreams.add(stream);
                }
            }
        }
    }

    /**
     * A stream that does not decode or parse is left as it is: the source may be any client PDF,
     * and veraPDF judges the result afterwards, so this must never be what fails a conversion.
     */
    private static int clearInlineImages(COSStream stream) throws IOException {
        List<Object> tokens;
        try (var input = stream.createInputStream()) {
            var content = input.readAllBytes();
            if (!mayHoldInlineImage(content)) {
                return 0;
            }
            tokens = new PDFStreamParser(content).parse();
        } catch (IOException | RuntimeException unreadable) {
            return 0;
        }
        var changed = 0;
        for (var token : tokens) {
            if (token instanceof Operator operator && operator.getImageParameters() != null) {
                var parameters = operator.getImageParameters();
                for (var key : List.of(COSName.I, COSName.INTERPOLATE)) {
                    if (parameters.getBoolean(key, false)) {
                        parameters.removeItem(key);
                        changed++;
                    }
                }
            }
        }
        if (changed > 0) {
            try (var output = stream.createOutputStream(COSName.FLATE_DECODE)) {
                new ContentStreamWriter(output).writeTokens(tokens);
            }
        }
        return changed;
    }

    /** Every inline image starts with the operator BI; most content streams have none. */
    private static boolean mayHoldInlineImage(byte[] content) {
        for (var index = 0; index + 1 < content.length; index++) {
            if (content[index] == 'B' && content[index + 1] == 'I') {
                return true;
            }
        }
        return false;
    }
}
