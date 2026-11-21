package digital.slovensko.autogram.core;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSArray;
import org.apache.pdfbox.cos.COSBase;
import org.apache.pdfbox.cos.COSBoolean;
import org.apache.pdfbox.cos.COSDictionary;
import org.apache.pdfbox.cos.COSDocument;
import org.apache.pdfbox.cos.COSFloat;
import org.apache.pdfbox.cos.COSInteger;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.cos.COSNull;
import org.apache.pdfbox.cos.COSObject;
import org.apache.pdfbox.cos.COSObjectKey;
import org.apache.pdfbox.cos.COSStream;
import org.apache.pdfbox.cos.COSString;

import java.io.IOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

/// What the bytes after a PDF's last signed revision changed, judged without trusting any label
/// those bytes carry.
///
/// DSS compares the object trees of the two revisions. A page relabelled `/Type /Sig` after
/// signing is reported as no change at all, whatever else changed beneath it (DSS 6.5.1); it
/// does not look at the document information dictionary, and it counts new XMP metadata as
/// extension data. This check closes those: every object of the
/// signed revision must still read the same, except in the places where signature extension data
/// lands, and each of those is recognised by the role the object had when it was signed:
///
/// - the catalog may gain or change `/DSS` and `/Extensions`;
/// - whatever the signed revision's `/DSS` reached may change (the store only grows);
/// - the form's `/Fields` and a page's `/Annots` may gain signature fields that show nothing
///   (a document timestamp's field), and the form's `/SigFlags` may change.
///
/// A later visible signature field, a comment or a filled form field is a change here too; DSS
/// reports those under their own kinds.
public final class PdfPostSignatureChanges {
    private static final COSName DSS = COSName.getPDFName("DSS");
    private static final COSName EXTENSIONS = COSName.getPDFName("Extensions");
    private static final Set<COSName> CATALOG_FREE = Set.of(DSS, EXTENSIONS, COSName.ACRO_FORM);
    private static final Set<COSName> FORM_FREE = Set.of(COSName.FIELDS, COSName.SIG_FLAGS);
    private static final Set<COSName> PAGE_FREE = Set.of(COSName.ANNOTS);
    private static final int MAX_DEPTH = 64;
    private static final int MAX_REASONS = 8;

    private PdfPostSignatureChanges() {
    }

    /// Reasons, in English for the log, why the bytes after `signedLength` are more than
    /// signature extension data; empty when they are not, or when nothing follows the signed
    /// revision. A file that cannot be read either way is a reason too.
    public static List<String> find(byte[] pdf, long signedLength) {
        if (signedLength <= 0 || signedLength >= pdf.length) {
            return List.of();
        }
        try (var signed = Loader.loadPDF(Arrays.copyOf(pdf, (int) signedLength)); var whole = Loader.loadPDF(pdf)) {
            return new Comparison(signed.getDocument(), whole.getDocument()).run();
        } catch (IOException | RuntimeException exception) {
            return List.of("unreadable: " + exception.getClass().getSimpleName());
        }
    }

    private static final class Comparison {
        private final COSDocument signed;
        private final COSDocument whole;
        private final List<String> reasons = new ArrayList<>();
        private final Set<COSObjectKey> pages = new HashSet<>();
        private final Set<COSObjectKey> gainOnlyArrays = new HashSet<>();
        private final Set<COSObjectKey> store = new HashSet<>();
        private COSObjectKey catalog;
        private COSObjectKey form;

        Comparison(COSDocument signed, COSDocument whole) {
            this.signed = signed;
            this.whole = whole;
        }

        List<String> run() {
            var signedTrailer = signed.getTrailer();
            var wholeTrailer = whole.getTrailer();
            for (var name : List.of(COSName.ROOT, COSName.INFO, COSName.ENCRYPT)) {
                if (!canonical(signedTrailer.getItem(name), 0).equals(canonical(wholeTrailer.getItem(name), 0))) {
                    reason("trailer " + name.getName() + " changed");
                }
            }
            readRoles(signedTrailer);
            for (var key : new TreeSet<>(signed.getXrefTable().keySet())) {
                var before = object(signed, key);
                if (before == null || isFileStructure(before)) {
                    continue;
                }
                var after = object(whole, key);
                if (canonical(before, 0).equals(canonical(after, 0)) || store.contains(key)) {
                    continue;
                }
                if (!allowed(key, before, after)) {
                    reason("object " + key.getNumber() + " changed");
                }
            }
            return reasons;
        }

        private void reason(String text) {
            if (reasons.size() < MAX_REASONS) {
                reasons.add(text);
            }
        }

        /// The roles objects hold in the signed revision.
        private void readRoles(COSDictionary trailer) {
            if (!(trailer.getItem(COSName.ROOT) instanceof COSObject root) || !(root.getObject() instanceof COSDictionary rootDictionary)) {
                return;
            }
            catalog = root.getKey();
            collectPages(rootDictionary.getItem(COSName.PAGES), new HashSet<>(), 0);
            collectReachable(rootDictionary.getItem(DSS), 0);
            var formItem = rootDictionary.getItem(COSName.ACRO_FORM);
            if (formItem instanceof COSObject reference) {
                form = reference.getKey();
            }
            if (resolve(formItem) instanceof COSDictionary formDictionary
                    && formDictionary.getItem(COSName.FIELDS) instanceof COSObject fields) {
                gainOnlyArrays.add(fields.getKey());
            }
        }

        private void collectPages(COSBase node, Set<COSObjectKey> seen, int depth) {
            if (depth > MAX_DEPTH || !(node instanceof COSObject reference) || !seen.add(reference.getKey())) {
                return;
            }
            if (!(reference.getObject() instanceof COSDictionary dictionary)) {
                return;
            }
            if (resolve(dictionary.getItem(COSName.KIDS)) instanceof COSArray kids) {
                for (var index = 0; index < kids.size(); index++) {
                    collectPages(kids.get(index), seen, depth + 1);
                }
                return;
            }
            pages.add(reference.getKey());
            if (dictionary.getItem(COSName.ANNOTS) instanceof COSObject annotations) {
                gainOnlyArrays.add(annotations.getKey());
            }
        }

        private void collectReachable(COSBase node, int depth) {
            if (depth > MAX_DEPTH) {
                return;
            }
            if (node instanceof COSObject reference) {
                if (store.add(reference.getKey())) {
                    collectReachable(reference.getObject(), depth + 1);
                }
            } else if (node instanceof COSDictionary dictionary) {
                for (var name : dictionary.keySet()) {
                    collectReachable(dictionary.getItem(name), depth + 1);
                }
            } else if (node instanceof COSArray array) {
                for (var index = 0; index < array.size(); index++) {
                    collectReachable(array.get(index), depth + 1);
                }
            }
        }

        private boolean allowed(COSObjectKey key, COSBase before, COSBase after) {
            if (gainOnlyArrays.contains(key)) {
                return onlyGainedHiddenSignatureFields(before, after);
            }
            if (!(before instanceof COSDictionary old) || !(after instanceof COSDictionary now)
                    || before instanceof COSStream || after instanceof COSStream) {
                return false;
            }
            if (key.equals(catalog)) {
                return sameExcept(old, now, CATALOG_FREE) && formAllowed(old.getItem(COSName.ACRO_FORM), now.getItem(COSName.ACRO_FORM));
            }
            if (key.equals(form)) {
                return formDictionaryAllowed(old, now);
            }
            if (pages.contains(key)) {
                return sameExcept(old, now, PAGE_FREE) && listAllowed(old.getItem(COSName.ANNOTS), now.getItem(COSName.ANNOTS));
            }
            return false;
        }

        /// The catalog's `/AcroForm` entry: the same reference (the object is judged on its own),
        /// or a direct dictionary changed only as a form may be.
        private boolean formAllowed(COSBase old, COSBase now) {
            if (canonical(old, 0).equals(canonical(now, 0))) {
                return true;
            }
            return old instanceof COSDictionary oldForm && now instanceof COSDictionary nowForm && formDictionaryAllowed(oldForm, nowForm);
        }

        private boolean formDictionaryAllowed(COSDictionary old, COSDictionary now) {
            return sameExcept(old, now, FORM_FREE) && listAllowed(old.getItem(COSName.FIELDS), now.getItem(COSName.FIELDS));
        }

        /// A `/Fields` or `/Annots` entry: the same reference (the array object is judged on its
        /// own), or a direct array that only gained hidden signature fields. A list that was not
        /// there when signing counts as empty.
        private boolean listAllowed(COSBase old, COSBase now) {
            if (canonical(old, 0).equals(canonical(now, 0))) {
                return true;
            }
            if (old instanceof COSObject) {
                return false;
            }
            return onlyGainedHiddenSignatureFields(old == null ? new COSArray() : old, resolve(now));
        }

        private boolean onlyGainedHiddenSignatureFields(COSBase before, COSBase after) {
            if (!(before instanceof COSArray old) || !(after instanceof COSArray now) || now.size() < old.size()) {
                return false;
            }
            for (var index = 0; index < old.size(); index++) {
                if (!canonical(old.get(index), 0).equals(canonical(now.get(index), 0))) {
                    return false;
                }
            }
            for (var index = old.size(); index < now.size(); index++) {
                if (!isHiddenSignatureField(now.get(index))) {
                    return false;
                }
            }
            return true;
        }

        /// A signature field that was not in the signed revision and draws nothing: its rectangle
        /// has no area. A document timestamp's field is one.
        private boolean isHiddenSignatureField(COSBase item) {
            if (!(item instanceof COSObject reference) || signed.getXrefTable().containsKey(reference.getKey())) {
                return false;
            }
            if (!(reference.getObject() instanceof COSDictionary field) || field instanceof COSStream) {
                return false;
            }
            if (!COSName.SIG.equals(field.getCOSName(COSName.FT)) || field.containsKey(COSName.KIDS)) {
                return false;
            }
            var rectangle = field.getCOSArray(COSName.RECT);
            if (rectangle == null || rectangle.size() != 4) {
                return false;
            }
            var values = rectangle.toFloatArray();
            return values[0] == values[2] || values[1] == values[3];
        }

        private boolean sameExcept(COSDictionary old, COSDictionary now, Set<COSName> free) {
            var names = new HashSet<>(old.keySet());
            names.addAll(now.keySet());
            names.removeAll(free);
            for (var name : names) {
                if (!canonical(old.getItem(name), 0).equals(canonical(now.getItem(name), 0))) {
                    return false;
                }
            }
            return true;
        }
    }

    private static COSBase object(COSDocument document, COSObjectKey key) {
        if (!document.getXrefTable().containsKey(key)) {
            return null;
        }
        var value = document.getObjectFromPool(key).getObject();
        return value instanceof COSNull ? null : value;
    }

    private static COSBase resolve(COSBase item) {
        return item instanceof COSObject reference ? reference.getObject() : item;
    }

    /// Cross-reference and object streams hold the file's structure, not the document; what they
    /// contain is compared object by object.
    private static boolean isFileStructure(COSBase object) {
        if (!(object instanceof COSStream stream)) {
            return false;
        }
        var type = stream.getCOSName(COSName.TYPE);
        return COSName.XREF.equals(type) || COSName.OBJ_STM.equals(type);
    }

    /// One object written out the same way whatever its spelling in the file: references stay
    /// references, a stream is its dictionary and a digest of its stored bytes.
    private static String canonical(COSBase item, int depth) {
        if (item == null || item instanceof COSNull) {
            return "null";
        }
        if (depth > MAX_DEPTH) {
            return "deep";
        }
        if (item instanceof COSObject reference) {
            return reference.getKey().getNumber() + " " + reference.getKey().getGeneration() + " R";
        }
        if (item instanceof COSDictionary dictionary) {
            var text = new StringBuilder("<<");
            var names = new TreeSet<String>();
            dictionary.keySet().forEach(name -> names.add(name.getName()));
            for (var name : names) {
                text.append('/').append(name).append(' ')
                        .append(canonical(dictionary.getItem(COSName.getPDFName(name)), depth + 1)).append(' ');
            }
            text.append(">>");
            if (item instanceof COSStream stream) {
                text.append("stream ").append(digest(stream));
            }
            return text.toString();
        }
        if (item instanceof COSArray array) {
            var text = new StringBuilder("[");
            for (var index = 0; index < array.size(); index++) {
                text.append(canonical(array.get(index), depth + 1)).append(' ');
            }
            return text.append(']').toString();
        }
        if (item instanceof COSString string) {
            return "(" + HexFormat.of().formatHex(string.getBytes()) + ")";
        }
        if (item instanceof COSName name) {
            return "/" + name.getName();
        }
        if (item instanceof COSInteger integer) {
            return Long.toString(integer.longValue());
        }
        if (item instanceof COSFloat number) {
            return Float.toString(number.floatValue());
        }
        if (item instanceof COSBoolean flag) {
            return Boolean.toString(flag.getValue());
        }
        return item.getClass().getSimpleName();
    }

    private static String digest(COSStream stream) {
        try (var input = stream.createRawInputStream()) {
            var digest = MessageDigest.getInstance("SHA-256");
            var buffer = new byte[65536];
            for (var read = input.read(buffer); read >= 0; read = input.read(buffer)) {
                digest.update(buffer, 0, read);
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch (IOException exception) {
            return "unreadable";
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException(exception);
        }
    }
}
