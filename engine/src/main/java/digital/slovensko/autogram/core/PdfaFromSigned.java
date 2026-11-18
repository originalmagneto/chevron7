package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.FileDocument;
import eu.europa.esig.dss.pdfa.PDFAStructureValidator;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSDictionary;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PageMode;
import org.apache.pdfbox.pdmodel.interactive.action.PDActionGoTo;
import org.apache.pdfbox.pdmodel.interactive.action.PDActionURI;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotation;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotationLink;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageDestination;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageFitDestination;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.outline.PDDocumentOutline;
import org.apache.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.graphics.color.PDDeviceCMYK;
import org.apache.pdfbox.pdmodel.graphics.image.JPEGFactory;
import org.apache.pdfbox.pdmodel.graphics.image.LosslessFactory;
import org.apache.pdfbox.pdmodel.graphics.image.PDImageXObject;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotationFileAttachment;
import org.apache.pdfbox.rendering.ImageType;
import org.apache.pdfbox.rendering.PDFRenderer;
import org.apache.pdfbox.util.Matrix;

import org.w3c.dom.Element;

import javax.imageio.ImageIO;
import javax.imageio.metadata.IIOMetadata;
import javax.imageio.metadata.IIOMetadataFormatImpl;
import java.awt.Color;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;

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
 *
 * <p>{@code PdfaFromSigned --merge <out.pdf> <iccProfile> <title> [--raster] <in> <name>
 * [<in> <name>]...} merges several originals (PDF, PNG or JPEG, told apart by their bytes) into
 * one PDF/A in the given order, with one outline item per input named {@code <name>}, and exits
 * with the same codes.
 */
public final class PdfaFromSigned {
    static final int RASTER_DPI = 200;

    private PdfaFromSigned() {
    }

    public record Result(boolean compliant, List<String> errors) {
    }

    /** One file to merge and the name its outline item carries. */
    public record Input(File file, String name) {
    }

    public static void main(String[] args) {
        System.exit(run(args));
    }

    static int run(String[] args) {
        if (args.length > 0 && args[0].equals("--merge")) {
            return runMerge(args);
        }
        if (args.length < 4 || args.length > 5 || (args.length == 5 && !args[4].equals("--raster"))) {
            System.err.println("Usage: PdfaFromSigned <in.pdf> <out.pdf> <iccProfile> <title> [--raster]");
            return 1;
        }
        try {
            var result = convert(new File(args[0]), new File(args[1]), new File(args[2]), args[3], args.length == 5);
            return exitCode(result);
        } catch (IOException exception) {
            System.err.println("PdfaFromSigned: " + exception.getClass().getSimpleName());
            return 2;
        } catch (Exception exception) {
            System.err.println("PdfaFromSigned: " + exception.getClass().getSimpleName());
            return 1;
        }
    }

    private static int runMerge(String[] args) {
        var first = 4;
        var raster = args.length > first && args[first].equals("--raster");
        if (raster) {
            first++;
        }
        if (args.length < first + 2 || (args.length - first) % 2 != 0) {
            System.err.println("Usage: PdfaFromSigned --merge <out.pdf> <iccProfile> <title> [--raster] <in> <name> [<in> <name>]...");
            return 1;
        }
        var inputs = new ArrayList<Input>();
        for (var index = first; index < args.length; index += 2) {
            inputs.add(new Input(new File(args[index]), args[index + 1]));
        }
        try {
            return exitCode(merge(inputs, new File(args[1]), new File(args[2]), args[3], raster));
        } catch (IOException exception) {
            System.err.println("PdfaFromSigned: " + exception.getClass().getSimpleName());
            return 2;
        } catch (Exception exception) {
            System.err.println("PdfaFromSigned: " + exception.getClass().getSimpleName());
            return 1;
        }
    }

    private static int exitCode(Result result) {
        if (!result.compliant()) {
            result.errors().stream().limit(5).forEach(System.err::println);
            return 3;
        }
        return 0;
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

    /**
     * Merges the inputs, in order, into one new PDF/A-2b at {@code output}: each PDF stripped and
     * flattened as {@link #convert} does (or rendered to images with {@code raster}), each PNG or
     * JPEG on an A4 page of its own, and one outline item per input at its first page. An input
     * that is neither PDF, PNG nor JPEG by its bytes, or cannot be read, is an {@link IOException}.
     */
    public static Result merge(List<Input> inputs, File output, File iccProfile, String title, boolean raster)
            throws Exception {
        if (inputs.isEmpty()) {
            throw new IllegalArgumentException("Nothing to merge");
        }
        var intermediate = Files.createTempFile("pdfa-merge", ".pdf").toFile();
        var sources = new ArrayList<PDDocument>();
        try {
            try (var target = new PDDocument()) {
                var outline = new PDDocumentOutline();
                target.getDocumentCatalog().setDocumentOutline(outline);
                for (var input : inputs) {
                    var bytes = Files.readAllBytes(input.file().toPath());
                    var firstPage = switch (MergeInputKind.of(bytes)) {
                        case PDF -> appendPdf(target, bytes, raster, sources);
                        case PNG, JPEG -> MergeImagePage.append(target, bytes);
                    };
                    var item = new PDOutlineItem();
                    item.setTitle(input.name());
                    var destination = new PDPageFitDestination();
                    destination.setPage(firstPage);
                    item.setDestination(destination);
                    outline.addLast(item);
                }
                target.getDocumentCatalog().setPageMode(PageMode.USE_OUTLINES);
                target.save(intermediate);
            }
            PdfaNormalize.normalize(intermediate, output, iccProfile, title);
            var check = new PDFAStructureValidator().validate(new FileDocument(output));
            return new Result(check.isCompliant(), List.copyOf(check.getErrorMessages()));
        } finally {
            for (var source : sources) {
                source.close();
            }
            Files.deleteIfExists(intermediate.toPath());
        }
    }

    /** The kinds of data object a merge takes, recognized by their first bytes only. */
    enum MergeInputKind {
        PDF, PNG, JPEG;

        private static final byte[] PNG_SIGNATURE = {(byte) 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};

        static MergeInputKind of(byte[] bytes) throws IOException {
            if (startsWith(bytes, new byte[] {'%', 'P', 'D', 'F'})) {
                return PDF;
            }
            if (startsWith(bytes, PNG_SIGNATURE)) {
                return PNG;
            }
            if (startsWith(bytes, new byte[] {(byte) 0xFF, (byte) 0xD8, (byte) 0xFF})) {
                return JPEG;
            }
            throw new IOException("Not a PDF, PNG or JPEG");
        }

        private static boolean startsWith(byte[] bytes, byte[] prefix) {
            return bytes.length >= prefix.length && Arrays.equals(bytes, 0, prefix.length, prefix, 0, prefix.length);
        }
    }

    /**
     * Imports the pages of one PDF into {@code target} and returns the first imported page. The
     * page dictionaries are copied shallowly, so the loaded source stays open (in {@code sources})
     * until the target is saved; every reference back into the source page tree is cut or
     * re-pointed, so the source's own pages never come along.
     */
    private static PDPage appendPdf(PDDocument target, byte[] bytes, boolean raster, List<PDDocument> sources)
            throws IOException {
        var source = Loader.loadPDF(bytes);
        sources.add(source);
        PDDocument pages = source;
        if (raster) {
            pages = rasterized(source);
            sources.add(pages);
        } else {
            stripAndFlatten(source);
        }
        if (pages.getNumberOfPages() == 0) {
            throw new IOException("PDF without pages");
        }
        var imported = new IdentityHashMap<COSDictionary, PDPage>();
        PDPage first = null;
        for (var page : pages.getPages()) {
            var copy = target.importPage(page);
            if (!copy.getCOSObject().containsKey(COSName.RESOURCES) && page.getResources() != null) {
                // importPage leaves resources the page inherits from its source page tree behind.
                copy.setResources(page.getResources());
            }
            copy.getCOSObject().removeItem(COSName.B);
            copy.getCOSObject().removeItem(COSName.STRUCT_PARENTS);
            copy.getCOSObject().removeItem(COSName.getPDFName("PieceInfo"));
            imported.put(page.getCOSObject(), copy);
            if (first == null) {
                first = copy;
            }
        }
        for (var copy : imported.values()) {
            var annotations = new ArrayList<PDAnnotation>();
            for (var annotation : copy.getAnnotations()) {
                annotation.getCOSObject().removeItem(COSName.STRUCT_PARENT);
                annotation.setPage(copy);
                if (annotation instanceof PDAnnotationLink link && !repointLink(link, imported)) {
                    continue;
                }
                annotations.add(annotation);
            }
            copy.setAnnotations(annotations);
        }
        return first;
    }

    /**
     * Keeps a link only when it does not point at a page outside the imported ones: a page
     * destination is re-pointed at its imported copy, a URI or named destination stays as it
     * is, and any other action goes with the link.
     */
    private static boolean repointLink(PDAnnotationLink link, Map<COSDictionary, PDPage> imported)
            throws IOException {
        var destination = link.getDestination();
        if (destination == null && link.getAction() instanceof PDActionGoTo goTo) {
            destination = goTo.getDestination();
        } else if (destination == null && link.getAction() != null) {
            return link.getAction() instanceof PDActionURI;
        }
        if (destination instanceof PDPageDestination pageDestination) {
            var page = pageDestination.getPage();
            if (page == null) {
                return pageDestination.getPageNumber() < 0;
            }
            var copy = imported.get(page.getCOSObject());
            if (copy == null) {
                return false;
            }
            pageDestination.setPage(copy);
        }
        return true;
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

    /**
     * One PNG or JPEG on an A4 page of its own: portrait unless the image is wider than tall,
     * scaled to fit inside {@link #IMAGE_MARGIN} margins but never drawn larger than its stated
     * resolution ({@link #DEFAULT_IMAGE_DPI} when it states none), and centered. An 8-bit RGB or
     * grey JPEG keeps its bytes, turned upright by its EXIF orientation through the image matrix;
     * a CMYK JPEG and any PNG are redrawn into 8-bit sRGB (a PNG's
     * transparency onto white), because PDF/A with an sRGB output intent takes no DeviceCMYK
     * and a 16-bit or transparent image is a needless risk.
     */
    static final class MergeImagePage {
        static final float IMAGE_MARGIN = 10 / 25.4f * 72;
        static final float DEFAULT_IMAGE_DPI = 150;

        private MergeImagePage() {
        }

        static PDPage append(PDDocument target, byte[] bytes) throws IOException {
            PDImageXObject image;
            try {
                image = MergeInputKind.of(bytes) == MergeInputKind.JPEG ? jpeg(target, bytes) : png(target, bytes);
            } catch (RuntimeException exception) {
                // A corrupt image surfaces from ImageIO as any runtime exception; it is unreadable input.
                throw new IOException("Unreadable image", exception);
            }
            var resolution = resolution(bytes);
            var orientation = MergeInputKind.of(bytes) == MergeInputKind.JPEG ? exifOrientation(bytes) : 1;
            // Orientations 5 to 8 turn the stored pixels a quarter, so width and height swap on display.
            var turned = orientation >= 5;
            var naturalWidth = (turned ? image.getHeight() / resolution[1] : image.getWidth() / resolution[0]) * 72;
            var naturalHeight = (turned ? image.getWidth() / resolution[0] : image.getHeight() / resolution[1]) * 72;
            var landscape = naturalWidth > naturalHeight;
            var box = landscape
                    ? new PDRectangle(PDRectangle.A4.getHeight(), PDRectangle.A4.getWidth())
                    : new PDRectangle(PDRectangle.A4.getWidth(), PDRectangle.A4.getHeight());
            var scale = Math.min(1f, Math.min((box.getWidth() - 2 * IMAGE_MARGIN) / naturalWidth,
                    (box.getHeight() - 2 * IMAGE_MARGIN) / naturalHeight));
            var width = naturalWidth * scale;
            var height = naturalHeight * scale;
            var page = new PDPage(box);
            target.addPage(page);
            try (var content = new PDPageContentStream(target, page)) {
                content.drawImage(image, placement(orientation,
                        (box.getWidth() - width) / 2, (box.getHeight() - height) / 2, width, height));
            }
            return page;
        }

        /**
         * The image matrix that shows the stored pixels upright in the box (x, y, width, height)
         * for an EXIF orientation, so a JPEG keeps its bytes. In image space the stored column
         * u runs left to right and the stored row runs from v = 1 (top) down to v = 0; each
         * orientation maps the stored top-left based (column, row) to the displayed one.
         */
        static Matrix placement(int orientation, float x, float y, float width, float height) {
            float[][] corners = {{0, 0}, {1, 0}, {0, 1}};
            var mapped = new float[3][2];
            for (var index = 0; index < 3; index++) {
                var column = corners[index][0];
                var row = 1 - corners[index][1];
                float shownColumn;
                float shownRow;
                switch (orientation) {
                    case 2 -> { shownColumn = 1 - column; shownRow = row; }
                    case 3 -> { shownColumn = 1 - column; shownRow = 1 - row; }
                    case 4 -> { shownColumn = column; shownRow = 1 - row; }
                    case 5 -> { shownColumn = row; shownRow = column; }
                    case 6 -> { shownColumn = 1 - row; shownRow = column; }
                    case 7 -> { shownColumn = 1 - row; shownRow = 1 - column; }
                    case 8 -> { shownColumn = row; shownRow = 1 - column; }
                    default -> { shownColumn = column; shownRow = row; }
                }
                mapped[index][0] = x + width * shownColumn;
                mapped[index][1] = y + height * (1 - shownRow);
            }
            return new Matrix(mapped[1][0] - mapped[0][0], mapped[1][1] - mapped[0][1],
                    mapped[2][0] - mapped[0][0], mapped[2][1] - mapped[0][1], mapped[0][0], mapped[0][1]);
        }

        /**
         * The EXIF orientation (1 to 8) of a JPEG's APP1 segment, else 1. Read by hand from the
         * TIFF header and the first IFD, because ImageIO does not expose it.
         */
        static int exifOrientation(byte[] jpeg) {
            var position = 2;
            while (position + 4 <= jpeg.length && (jpeg[position] & 0xFF) == 0xFF) {
                var marker = jpeg[position + 1] & 0xFF;
                if (marker == 0xDA || marker == 0xD9) {
                    return 1;
                }
                var length = ((jpeg[position + 2] & 0xFF) << 8) | (jpeg[position + 3] & 0xFF);
                var start = position + 4;
                if (length < 2 || start + length - 2 > jpeg.length) {
                    return 1;
                }
                if (marker == 0xE1 && length >= 8 && jpeg[start] == 'E' && jpeg[start + 1] == 'x'
                        && jpeg[start + 2] == 'i' && jpeg[start + 3] == 'f' && jpeg[start + 4] == 0
                        && jpeg[start + 5] == 0) {
                    return tiffOrientation(jpeg, start + 6, start + length - 2);
                }
                position = start + length - 2;
            }
            return 1;
        }

        private static int tiffOrientation(byte[] data, int tiff, int end) {
            if (tiff + 8 > end) {
                return 1;
            }
            boolean bigEndian;
            if (data[tiff] == 'M' && data[tiff + 1] == 'M') {
                bigEndian = true;
            } else if (data[tiff] == 'I' && data[tiff + 1] == 'I') {
                bigEndian = false;
            } else {
                return 1;
            }
            var ifd = tiff + (int) read(data, tiff + 4, 4, bigEndian);
            if (ifd < tiff || ifd + 2 > end) {
                return 1;
            }
            var entries = (int) read(data, ifd, 2, bigEndian);
            for (var entry = 0; entry < entries; entry++) {
                var offset = ifd + 2 + entry * 12;
                if (offset + 12 > end) {
                    return 1;
                }
                if (read(data, offset, 2, bigEndian) == 0x0112 && read(data, offset + 2, 2, bigEndian) == 3) {
                    var value = (int) read(data, offset + 8, 2, bigEndian);
                    return value >= 1 && value <= 8 ? value : 1;
                }
            }
            return 1;
        }

        private static long read(byte[] data, int offset, int length, boolean bigEndian) {
            long value = 0;
            for (var index = 0; index < length; index++) {
                var octet = data[offset + (bigEndian ? index : length - 1 - index)] & 0xFF;
                value = (value << 8) | octet;
            }
            return value;
        }

        private static PDImageXObject jpeg(PDDocument target, byte[] bytes) throws IOException {
            var image = JPEGFactory.createFromByteArray(target, bytes);
            if (image.getBitsPerComponent() == 8 && image.getColorSpace().getNumberOfComponents() != 4) {
                return image;
            }
            return JPEGFactory.createFromImage(target, cmykJpegAsRgb(bytes), 0.9f);
        }

        private static PDImageXObject png(PDDocument target, byte[] bytes) throws IOException {
            var decoded = ImageIO.read(new ByteArrayInputStream(bytes));
            if (decoded == null) {
                throw new IOException("Unreadable PNG");
            }
            var colorSpace = decoded.getColorModel().getColorSpace();
            var rgb = colorSpace.getType() == java.awt.color.ColorSpace.TYPE_GRAY ? greyOnWhite(decoded) : onWhite(decoded);
            return LosslessFactory.createFromImage(target, rgb);
        }

        /**
         * Redraws a grey PNG, with or without alpha and of any depth, into 8-bit sRGB by hand.
         * PNG grey samples are encoded like sRGB, but Java2D takes the decoder's CS_GRAY as
         * linear and lightened grey with alpha (128 became 188); here every sample is scaled to
         * 8 bits as it is and blended onto white by its alpha.
         */
        static BufferedImage greyOnWhite(BufferedImage image) {
            var raster = image.getRaster();
            var colorModel = image.getColorModel();
            var greyMax = (1 << colorModel.getComponentSize(0)) - 1;
            var alpha = colorModel.hasAlpha();
            var alphaMax = alpha ? (1 << colorModel.getComponentSize(colorModel.getNumComponents() - 1)) - 1 : 1;
            var alphaBand = raster.getNumBands() - 1;
            var rgb = new BufferedImage(image.getWidth(), image.getHeight(), BufferedImage.TYPE_INT_RGB);
            for (var y = 0; y < image.getHeight(); y++) {
                for (var x = 0; x < image.getWidth(); x++) {
                    var grey = raster.getSample(x, y, 0) * 255.0 / greyMax;
                    if (alpha) {
                        var coverage = raster.getSample(x, y, alphaBand) / (double) alphaMax;
                        grey = grey * coverage + 255 * (1 - coverage);
                    }
                    var tone = (int) Math.max(0, Math.min(255, Math.round(grey)));
                    rgb.setRGB(x, y, (tone << 16) | (tone << 8) | tone);
                }
            }
            return rgb;
        }

        /** Redraws any image into 8-bit sRGB, transparency composed onto white. */
        private static BufferedImage onWhite(BufferedImage image) {
            var rgb = new BufferedImage(image.getWidth(), image.getHeight(), BufferedImage.TYPE_INT_RGB);
            var graphics = rgb.createGraphics();
            try {
                graphics.setColor(Color.WHITE);
                graphics.fillRect(0, 0, image.getWidth(), image.getHeight());
                graphics.drawImage(image, 0, 0, null);
            } finally {
                graphics.dispose();
            }
            return rgb;
        }

        /**
         * Decodes a four-component JPEG through its raw samples and PDFBox's CMYK profile. Without
         * an Adobe APP14 marker the samples are plain CMYK; with one they are stored inverted
         * (transform 0) or as YCCK (transform 2), Adobe's convention. PDFBox's own decoder
         * assumes the inverted form for every CMYK JPEG, which turns an unmarked one into a
         * negative.
         */
        private static BufferedImage cmykJpegAsRgb(byte[] bytes) throws IOException {
            var readers = ImageIO.getImageReadersByFormatName("jpeg");
            if (!readers.hasNext()) {
                throw new IOException("No JPEG reader");
            }
            var reader = readers.next();
            try (var stream = ImageIO.createImageInputStream(new ByteArrayInputStream(bytes))) {
                reader.setInput(stream);
                var transform = adobeTransform(reader.getImageMetadata(0));
                var samples = reader.readRaster(0, null);
                var raster = samples.createCompatibleWritableRaster();
                raster.setRect(samples);
                if (raster.getNumBands() != 4) {
                    throw new IOException("Unsupported JPEG colour model");
                }
                var pixel = new int[4];
                for (var y = 0; y < raster.getHeight(); y++) {
                    for (var x = 0; x < raster.getWidth(); x++) {
                        raster.getPixel(x, y, pixel);
                        if (transform == 2) {
                            var luma = pixel[0];
                            var blue = pixel[1] - 128;
                            var red = pixel[2] - 128;
                            pixel[0] = clamp(Math.round(luma + 1.402f * red));
                            pixel[1] = clamp(Math.round(luma - 0.344136f * blue - 0.714136f * red));
                            pixel[2] = clamp(Math.round(luma + 1.772f * blue));
                            pixel[3] = 255 - pixel[3];
                        } else if (transform >= 0) {
                            for (var band = 0; band < 4; band++) {
                                pixel[band] = 255 - pixel[band];
                            }
                        }
                        raster.setPixel(x, y, pixel);
                    }
                }
                return onWhite(PDDeviceCMYK.INSTANCE.toRGBImage(raster));
            } finally {
                reader.dispose();
            }
        }

        private static int clamp(int value) {
            return Math.max(0, Math.min(255, value));
        }

        /** The Adobe APP14 transform, or -1 when the JPEG carries no such marker. */
        private static int adobeTransform(IIOMetadata metadata) {
            try {
                var root = metadata.getAsTree("javax_imageio_jpeg_image_1.0");
                var markers = ((Element) root).getElementsByTagName("app14Adobe");
                if (markers.getLength() == 0) {
                    return -1;
                }
                return Integer.parseInt(((Element) markers.item(0)).getAttribute("transform"));
            } catch (RuntimeException exception) {
                return -1;
            }
        }

        /**
         * The horizontal and vertical resolution in dots per inch the file states (PNG pHYs in
         * metres, JPEG JFIF density in inches or centimetres), else {@link #DEFAULT_IMAGE_DPI}.
         * A value outside 10 to 10000 dpi counts as none.
         */
        static float[] resolution(byte[] bytes) {
            var fallback = new float[] {DEFAULT_IMAGE_DPI, DEFAULT_IMAGE_DPI};
            try (var stream = ImageIO.createImageInputStream(new ByteArrayInputStream(bytes))) {
                var readers = ImageIO.getImageReaders(stream);
                if (!readers.hasNext()) {
                    return fallback;
                }
                var reader = readers.next();
                try {
                    reader.setInput(stream);
                    var root = (Element) reader.getImageMetadata(0)
                            .getAsTree(IIOMetadataFormatImpl.standardMetadataFormatName);
                    var horizontal = dpi(root, "HorizontalPixelSize");
                    var vertical = dpi(root, "VerticalPixelSize");
                    if (horizontal < 0 || vertical < 0) {
                        return fallback;
                    }
                    return new float[] {horizontal, vertical};
                } finally {
                    reader.dispose();
                }
            } catch (IOException | RuntimeException exception) {
                return fallback;
            }
        }

        private static float dpi(Element root, String name) {
            var nodes = root.getElementsByTagName(name);
            if (nodes.getLength() == 0) {
                return -1;
            }
            var millimetresPerPixel = Float.parseFloat(((Element) nodes.item(0)).getAttribute("value"));
            var dpi = 25.4f / millimetresPerPixel;
            return dpi >= 10 && dpi <= 10000 ? dpi : -1;
        }
    }
}
