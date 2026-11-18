package digital.slovensko.autogram.core;

import eu.europa.esig.dss.alert.LogOnStatusAlert;
import eu.europa.esig.dss.asic.xades.ASiCWithXAdESSignatureParameters;
import eu.europa.esig.dss.asic.xades.signature.ASiCWithXAdESService;
import eu.europa.esig.dss.enumerations.ASiCContainerType;
import eu.europa.esig.dss.enumerations.DigestAlgorithm;
import eu.europa.esig.dss.enumerations.MimeType;
import eu.europa.esig.dss.enumerations.MimeTypeEnum;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.enumerations.SignaturePackaging;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.token.Pkcs12SignatureToken;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDDocumentNameDictionary;
import org.apache.pdfbox.pdmodel.PDEmbeddedFilesNameTreeNode;
import org.apache.pdfbox.pdmodel.common.filespecification.PDComplexFileSpecification;
import org.apache.pdfbox.pdmodel.common.filespecification.PDEmbeddedFile;
import org.apache.pdfbox.Loader;

import javax.imageio.IIOImage;
import javax.imageio.ImageIO;
import javax.imageio.ImageWriteParam;
import java.awt.image.BufferedImage;
import java.awt.image.Raster;
import java.awt.image.WritableRaster;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

/// ASiC-E containers and images for the E→E conversion tests, signed with the same test key as
/// `ConversionTestPdfs.sign`.
public final class ConversionTestContainers {
    /// One data object of a container: its entry name and bytes.
    public record Entry(String name, byte[] bytes) {
    }

    private ConversionTestContainers() {
    }

    /// One XAdES Baseline B signature over every entry, in the given order.
    public static byte[] xadesAsice(List<Entry> entries) throws Exception {
        return signed(entries, new Date());
    }

    /// Signs only the named entries of `asice` and adds that signature to it as the next
    /// `META-INF/signaturesN.xml`; everything else in the container stays as it was.
    public static byte[] addSignatureCovering(byte[] asice, List<String> names) throws Exception {
        var contents = new java.util.LinkedHashMap<String, byte[]>();
        var signatureFiles = 0;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(asice))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                contents.put(entry.getName(), zip.readAllBytes());
                if (entry.getName().matches("META-INF/signatures\\d*\\.xml")) {
                    signatureFiles++;
                }
            }
        }
        var covered = new ArrayList<Entry>();
        for (var name : names) {
            covered.add(new Entry(name, Objects.requireNonNull(contents.get(name), name)));
        }
        // A later signing time gives the new signature its own deterministic id.
        var partial = signed(covered, new Date(System.currentTimeMillis() + 60_000L));
        byte[] signature = null;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(partial))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                if (entry.getName().matches("META-INF/signatures\\d*\\.xml")) {
                    signature = zip.readAllBytes();
                }
            }
        }
        contents.put("META-INF/signatures" + signatureFiles + ".xml", Objects.requireNonNull(signature));
        return zipped(contents);
    }

    /// A PNG of the given size, 16-bit grey or 8-bit RGB.
    public static byte[] png(int width, int height, boolean sixteenBit) throws IOException {
        var image = new BufferedImage(width, height,
                sixteenBit ? BufferedImage.TYPE_USHORT_GRAY : BufferedImage.TYPE_INT_RGB);
        var graphics = image.createGraphics();
        graphics.setColor(java.awt.Color.WHITE);
        graphics.fillRect(0, 0, width, height);
        graphics.setColor(java.awt.Color.DARK_GRAY);
        graphics.drawLine(0, 0, width - 1, height - 1);
        graphics.dispose();
        var output = new ByteArrayOutputStream();
        if (!ImageIO.write(image, "png", output)) {
            throw new IOException("No PNG writer");
        }
        return output.toByteArray();
    }

    /// A JPEG of the given size, RGB or (four components, Adobe marker) CMYK.
    public static byte[] jpeg(int width, int height, boolean cmyk) throws IOException {
        var writer = ImageIO.getImageWritersByFormatName("jpeg").next();
        var output = new ByteArrayOutputStream();
        try (var stream = ImageIO.createImageOutputStream(output)) {
            writer.setOutput(stream);
            var parameters = writer.getDefaultWriteParam();
            parameters.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
            parameters.setCompressionQuality(0.9f);
            if (cmyk) {
                WritableRaster raster = Raster.createBandedRaster(java.awt.image.DataBuffer.TYPE_BYTE,
                        width, height, 4, null);
                for (var y = 0; y < height; y++) {
                    for (var x = 0; x < width; x++) {
                        raster.setSample(x, y, 0, (x * 255) / Math.max(1, width - 1));
                        raster.setSample(x, y, 1, (y * 255) / Math.max(1, height - 1));
                    }
                }
                writer.write(null, new IIOImage(raster, null, null), parameters);
            } else {
                var image = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
                var graphics = image.createGraphics();
                graphics.setColor(java.awt.Color.ORANGE);
                graphics.fillRect(0, 0, width, height);
                graphics.dispose();
                writer.write(null, new IIOImage(image, null, null), parameters);
            }
        } finally {
            writer.dispose();
        }
        return output.toByteArray();
    }

    /// A one-page PDF carrying one embedded file named `name`.
    public static byte[] pdfWithEmbeddedFile(String name, byte[] content) throws Exception {
        try (PDDocument document = Loader.loadPDF(ConversionTestPdfs.samplePdf())) {
            var embedded = new PDEmbeddedFile(document, new ByteArrayInputStream(content));
            embedded.setSubtype("text/plain");
            embedded.setSize(content.length);
            var specification = new PDComplexFileSpecification();
            specification.setFile(name);
            specification.setFileUnicode(name);
            specification.setEmbeddedFile(embedded);
            specification.setEmbeddedFileUnicode(embedded);
            var tree = new PDEmbeddedFilesNameTreeNode();
            tree.setNames(Map.of(name, specification));
            var names = new PDDocumentNameDictionary(document.getDocumentCatalog());
            names.setEmbeddedFiles(tree);
            document.getDocumentCatalog().setNames(names);
            var output = new ByteArrayOutputStream();
            document.save(output);
            return output.toByteArray();
        }
    }

    private static byte[] signed(List<Entry> entries, Date signingDate) throws Exception {
        try (var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(ConversionTestContainers.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()))) {
            var key = token.getKeys().get(0);
            var parameters = new ASiCWithXAdESSignatureParameters();
            parameters.aSiC().setContainerType(ASiCContainerType.ASiC_E);
            parameters.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
            parameters.setSignaturePackaging(SignaturePackaging.DETACHED);
            parameters.setDigestAlgorithm(DigestAlgorithm.SHA256);
            parameters.setSigningCertificate(key.getCertificate());
            parameters.setCertificateChain(key.getCertificateChain());
            parameters.bLevel().setSigningDate(signingDate);
            var verifier = new CommonCertificateVerifier();
            // The engine's test key expired in 2024, as in SigningJob's own verifier setup.
            verifier.setAlertOnExpiredCertificate(new LogOnStatusAlert());
            var service = new ASiCWithXAdESService(verifier);
            var documents = new ArrayList<DSSDocument>();
            for (var entry : entries) {
                documents.add(new InMemoryDocument(entry.bytes(), entry.name(), mimeType(entry.name())));
            }
            var toSign = service.getDataToSign(documents, parameters);
            var value = token.sign(toSign, parameters.getDigestAlgorithm(), key);
            try (var stream = service.signDocument(documents, parameters, value).openStream()) {
                return stream.readAllBytes();
            }
        }
    }

    private static MimeType mimeType(String name) {
        var lower = name.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".pdf")) return MimeTypeEnum.PDF;
        if (lower.endsWith(".png")) return MimeTypeEnum.PNG;
        if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return MimeTypeEnum.JPEG;
        return MimeTypeEnum.BINARY;
    }

    /// A zip with `mimetype` first and stored, as ASiC requires, the rest deflated.
    private static byte[] zipped(Map<String, byte[]> contents) throws IOException {
        var output = new ByteArrayOutputStream();
        try (var zip = new ZipOutputStream(output)) {
            var mimetype = contents.get("mimetype");
            if (mimetype != null) {
                var entry = new ZipEntry("mimetype");
                entry.setMethod(ZipEntry.STORED);
                entry.setSize(mimetype.length);
                var crc = new CRC32();
                crc.update(mimetype);
                entry.setCrc(crc.getValue());
                zip.putNextEntry(entry);
                zip.write(mimetype);
                zip.closeEntry();
            }
            for (var item : contents.entrySet()) {
                if (item.getKey().equals("mimetype")) continue;
                zip.putNextEntry(new ZipEntry(item.getKey()));
                zip.write(item.getValue());
                zip.closeEntry();
            }
        }
        return output.toByteArray();
    }
}
