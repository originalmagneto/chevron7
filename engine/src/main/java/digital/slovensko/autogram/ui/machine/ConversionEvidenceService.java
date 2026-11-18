package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import digital.slovensko.autogram.core.PdfConversionFacts;
import digital.slovensko.autogram.core.SignatureValidator;
import digital.slovensko.autogram.util.DSSUtils;
import eu.europa.esig.dss.diagnostic.CertificateWrapper;
import eu.europa.esig.dss.diagnostic.DiagnosticData;
import eu.europa.esig.dss.diagnostic.SignatureWrapper;
import eu.europa.esig.dss.enumerations.Indication;
import eu.europa.esig.dss.enumerations.QCTypeEnum;
import eu.europa.esig.dss.enumerations.TimestampType;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.FileDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.simplereport.SimpleReport;
import eu.europa.esig.dss.validation.SignedDocumentValidator;
import eu.europa.esig.dss.validation.reports.Reports;
import org.bouncycastle.asn1.ASN1String;
import org.bouncycastle.asn1.x509.CertificatePolicies;
import org.bouncycastle.asn1.x509.PolicyQualifierId;
import org.bouncycastle.asn1.x509.PolicyQualifierInfo;
import org.bouncycastle.asn1.x509.UserNotice;
import org.bouncycastle.cert.X509CertificateHolder;
import org.w3c.dom.Element;

import javax.imageio.ImageIO;
import javax.imageio.metadata.IIOMetadataFormatImpl;
import javax.imageio.stream.MemoryCacheImageInputStream;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.OutputKeys;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import java.util.function.Predicate;
import java.util.function.Supplier;
import java.util.stream.Collectors;
import java.util.zip.ZipInputStream;

/**
 * Everything a guaranteed conversion of an electronic document (E→E, § 36 ods. 4 zákona
 * 305/2013) records about the original's signatures: the validation tree the app already
 * shows, plus the ETSI TS 119 102-2 report, each signature's value, revision, signer facts
 * (identifier, mandant, mandate) and the PDF/A facts that decide whether the PDF may be kept.
 * One validation against the trusted lists feeds all of it.
 */
public final class ConversionEvidenceService {
    static final String DSS_VERSION = "6.4";
    /// Matched by local name: DSS 6.4 writes ETSI TS 119 102-2 v1.4.1, other versions differ.
    static final String ANY_NAMESPACE = "*";
    private static final String MANDATE_POLICY_PREFIX = "1.3.158.36061701.1.1.";

    private final Function<SignedDocumentValidator, Reports> validation;
    private final Supplier<? extends Collection<String>> unavailableCountries;
    /// Data objects larger than this are listed with their hash only (a container with several).
    private final long dataObjectLimit;
    /// Whether DSS finds any signature in PDF bytes; throws when it cannot tell.
    private final Predicate<byte[]> signatureProbe;

    public ConversionEvidenceService() {
        this(validator -> SignatureValidator.getInstance().validate(validator),
                () -> SignatureValidator.getInstance().unavailableTrustedListCountries());
    }

    ConversionEvidenceService(Function<SignedDocumentValidator, Reports> validation,
            Supplier<? extends Collection<String>> unavailableCountries) {
        this(validation, unavailableCountries, DATA_OBJECT_LIMIT, ConversionEvidenceService::hasSignatures);
    }

    /// Tests only: a smaller size limit and a signature probe that can fail.
    ConversionEvidenceService(Function<SignedDocumentValidator, Reports> validation,
            Supplier<? extends Collection<String>> unavailableCountries, long dataObjectLimit,
            Predicate<byte[]> signatureProbe) {
        this.validation = validation;
        this.unavailableCountries = unavailableCountries;
        this.dataObjectLimit = dataObjectLimit;
        this.signatureProbe = signatureProbe;
    }

    public JsonObject evidence(Path path) {
        byte[] content;
        try {
            content = Files.readAllBytes(path);
        } catch (IOException exception) {
            throw new java.io.UncheckedIOException(exception);
        }
        var body = evidenceBody(new FileDocument(path.toFile()), content, null);
        var tree = MachineInspectionService.forTrustedValidation(
                new FirstReportReader(body.reports().getSimpleReport(), validation)).inspect(path);
        tree.add("evidence", body.evidence());
        return tree;
    }

    /// The `evidence` object of one document and the reports it came from.
    private record EvidenceBody(JsonObject evidence, Reports reports) {
    }

    /// Validates `document` once and builds its `evidence` object (no tree). `knownPdfFacts`,
    /// when given, are the PDF facts already read from `content`, so veraPDF does not run again.
    private EvidenceBody evidenceBody(DSSDocument document, byte[] content, JsonObject knownPdfFacts) {
        var validator = DSSUtils.createDocumentValidator(document);
        if (validator == null) {
            throw new IllegalArgumentException("UNSUPPORTED_DOCUMENT");
        }
        validator.setEnableEtsiValidationReport(true);
        var reports = validation.apply(validator);
        var simple = reports.getSimpleReport();

        var evidence = new JsonObject();
        evidence.addProperty("validationTime", simple.getValidationTime().toInstant().toString());
        evidence.addProperty("dssVersion", DSS_VERSION);
        var etsi = reports.getXmlValidationReport();
        evidence.addProperty("etsiReportBase64", base64(etsi));
        var unavailable = unavailableCountries.get().stream().map(ConversionEvidenceService::normalized)
                .collect(Collectors.toSet());
        var signatures = new JsonArray();
        var diagnostic = reports.getDiagnosticData();
        for (var id : simple.getSignatureIdList()) {
            signatures.add(signatureFacts(diagnostic, simple, id, etsi, unavailable));
        }
        evidence.add("signatures", signatures);
        evidence.add("documentTimestamps", documentTimestamps(diagnostic, simple));
        evidence.add("contentTimestamps", contentTimestamps(diagnostic, simple));
        var pdf = pdfFacts(content, diagnostic, knownPdfFacts);
        if (pdf != null) {
            evidence.add("pdf", pdf);
        }
        return new EvidenceBody(evidence, reports);
    }

    private static JsonObject signatureFacts(DiagnosticData diagnostic, SimpleReport simple, String id, String etsi,
            Set<String> unavailable) {
        var facts = new JsonObject();
        facts.addProperty("id", id);
        var signature = diagnostic.getSignatureById(id);
        // The container's signature file (`META-INF/signatures...xml`). For PAdES DSS names the
        // PDF itself, which is no signature file, so it is left out there.
        if (signature.getPDFRevision() == null && signature.getFilename() != null) {
            facts.addProperty("signatureFilename", signature.getFilename());
        }
        if (signature.getSignatureValue() != null) {
            facts.addProperty("signatureValueBase64", Base64.getEncoder().encodeToString(signature.getSignatureValue()));
        }
        var revision = signature.getPDFRevision();
        if (revision != null) {
            var range = revision.getSignatureByteRange();
            if (range != null && range.size() == 4) {
                facts.addProperty("signedRevisionLength", range.get(2).add(range.get(3)));
            }
        }
        facts.addProperty("productionPlace", productionPlace(signature));
        var certificate = signature.getSigningCertificate();
        if (certificate != null) {
            addCertificateFacts(facts, certificate);
        }
        facts.addProperty("trustedListUnavailable",
                simple.getIndication(id) == Indication.INDETERMINATE
                        && anchorCountry(signature).map(unavailable::contains).orElse(false));
        facts.addProperty("etsiSignatureReportBase64", slimReport(etsi, id));
        facts.add("timestamps", timestamps(signature, simple));
        return facts;
    }

    /// Timestamps that prove the signature existed (DSS: produced after its creation), with
    /// what the clause's TimeStamp block needs: issuer CN, time, state and qualification.
    private static JsonArray timestamps(SignatureWrapper signature, SimpleReport simple) {
        var timestamps = new JsonArray();
        for (var timestamp : signature.getAllTimestampsProducedAfterSignatureCreation()) {
            var entry = new JsonObject();
            entry.addProperty("id", timestamp.getId());
            if (timestamp.getType() != null) entry.addProperty("type", timestamp.getType().name());
            if (timestamp.getProductionTime() != null) {
                entry.addProperty("productionTime", timestamp.getProductionTime().toInstant().toString());
            }
            var certificate = timestamp.getSigningCertificate();
            if (certificate != null) entry.addProperty("producerCommonName", certificate.getCommonName());
            var indication = simple.getIndication(timestamp.getId());
            if (indication != null) entry.addProperty("indication", indication.name());
            var qualification = simple.getTimestampQualification(timestamp.getId());
            if (qualification != null) entry.addProperty("qualification", qualification.name());
            timestamps.add(entry);
        }
        return timestamps;
    }

    /// The PDF's document timestamps (DSS `DOCUMENT_TIMESTAMP`), each with the end of its
    /// `/ByteRange` as `coveredRevisionLength`: the revision it covers is that prefix.
    private static JsonArray documentTimestamps(DiagnosticData diagnostic, SimpleReport simple) {
        var timestamps = new JsonArray();
        for (var timestamp : diagnostic.getTimestampList()) {
            if (timestamp.getType() != TimestampType.DOCUMENT_TIMESTAMP) continue;
            var entry = new JsonObject();
            entry.addProperty("id", timestamp.getId());
            if (timestamp.getProductionTime() != null) {
                entry.addProperty("productionTime", timestamp.getProductionTime().toInstant().toString());
            }
            var certificate = timestamp.getSigningCertificate();
            if (certificate != null) entry.addProperty("producerCommonName", certificate.getCommonName());
            var indication = simple.getIndication(timestamp.getId());
            if (indication != null) entry.addProperty("indication", indication.name());
            var qualification = simple.getTimestampQualification(timestamp.getId());
            if (qualification != null) entry.addProperty("qualification", qualification.name());
            var revision = timestamp.getPDFRevision();
            var range = revision == null ? null : revision.getSignatureByteRange();
            if (range != null && range.size() == 4) {
                entry.addProperty("coveredRevisionLength", range.get(2).add(range.get(3)));
            }
            timestamps.add(entry);
        }
        return timestamps;
    }

    /// XAdES content timestamps (DSS `ALL_DATA_OBJECTS_TIMESTAMP`, `INDIVIDUAL_DATA_OBJECTS_TIMESTAMP`)
    /// in the signed properties of each signature, with the signature that carries them
    /// (`signatureId`) and the data objects they cover (`coveredDataObjects`, DSS's timestamp
    /// scope names, which name the data objects as the signature scopes do).
    private static JsonArray contentTimestamps(DiagnosticData diagnostic, SimpleReport simple) {
        var timestamps = new JsonArray();
        for (var signatureId : simple.getSignatureIdList()) {
            var signature = diagnostic.getSignatureById(signatureId);
            if (signature == null) continue;
            for (var timestamp : signature.getTimestampList()) {
                if (timestamp.getType() != TimestampType.ALL_DATA_OBJECTS_TIMESTAMP
                        && timestamp.getType() != TimestampType.INDIVIDUAL_DATA_OBJECTS_TIMESTAMP) {
                    continue;
                }
                var entry = new JsonObject();
                entry.addProperty("id", timestamp.getId());
                entry.addProperty("signatureId", signatureId);
                entry.addProperty("type", timestamp.getType().name());
                if (timestamp.getProductionTime() != null) {
                    entry.addProperty("productionTime", timestamp.getProductionTime().toInstant().toString());
                }
                var certificate = timestamp.getSigningCertificate();
                if (certificate != null) entry.addProperty("producerCommonName", certificate.getCommonName());
                var indication = simple.getIndication(timestamp.getId());
                if (indication != null) entry.addProperty("indication", indication.name());
                var qualification = simple.getTimestampQualification(timestamp.getId());
                if (qualification != null) entry.addProperty("qualification", qualification.name());
                var covered = new JsonArray();
                var scopes = timestamp.getTimestampScopes();
                if (scopes != null) {
                    for (var scope : scopes) {
                        if (scope.getName() != null && !covered.contains(new com.google.gson.JsonPrimitive(scope.getName()))) {
                            covered.add(scope.getName());
                        }
                    }
                }
                entry.add("coveredDataObjects", covered);
                timestamps.add(entry);
            }
        }
        return timestamps;
    }

    static void addCertificateFacts(JsonObject facts, CertificateWrapper certificate) {
        facts.addProperty("signerCommonName", certificate.getCommonName());
        if (certificate.getSubjectSerialNumber() != null && !certificate.getSubjectSerialNumber().isBlank()) {
            facts.addProperty("signerSerialNumber", certificate.getSubjectSerialNumber());
        }
        facts.addProperty("qcCompliance", certificate.isQcCompliance());
        var types = certificate.getQcTypes();
        if (types != null && types.contains(QCTypeEnum.QCT_ESEAL)) {
            facts.addProperty("qcType", "eseal");
        } else if (types != null && types.contains(QCTypeEnum.QCT_ESIGN)) {
            facts.addProperty("qcType", "esign");
        }
        var services = new JsonArray();
        for (var service : certificate.getTrustServices()) {
            if (service.getType() != null && !services.contains(new com.google.gson.JsonPrimitive(service.getType()))) {
                services.add(service.getType());
            }
        }
        facts.add("trustServiceTypes", services);
        var subject = X509Facts.of(certificate.getBinaries());
        var mandants = new JsonArray();
        subject.mandants().forEach(mandants::add);
        facts.add("mandants", mandants);
        var policies = new JsonArray();
        for (var policy : subject.policies()) {
            var entry = new JsonObject();
            entry.addProperty("oid", policy.oid());
            if (policy.explicitText() != null) {
                entry.addProperty("explicitText", policy.explicitText());
            }
            policies.add(entry);
        }
        facts.add("policies", policies);
        var mandate = subject.mandate();
        if (mandate != null) {
            facts.addProperty("mandate", mandate);
        }
    }

    /// The signature production place as one line, or null: XAdES/CAdES postal address
    /// parts, else the PDF signature dictionary's /Location.
    static String productionPlace(SignatureWrapper signature) {
        var parts = new ArrayList<String>();
        if (signature.isSignatureProductionPlacePresent()) {
            addPart(parts, signature.getStreetAddress());
            addPart(parts, signature.getPostalCode());
            addPart(parts, signature.getCity());
            if (signature.getPostalAddress() != null) {
                signature.getPostalAddress().forEach(part -> addPart(parts, part));
            }
            addPart(parts, signature.getCountryName());
        }
        if (parts.isEmpty() && signature.getPDFRevision() != null) {
            addPart(parts, signature.getPDFRevision().getLocation());
        }
        return parts.isEmpty() ? null : String.join(", ", parts);
    }

    private static void addPart(List<String> parts, String part) {
        if (part != null && !part.isBlank() && !parts.contains(part.trim())) {
            parts.add(part.trim());
        }
    }

    /// The country whose trusted list anchors this signature: the chain's last certificate,
    /// else the signing certificate's issuer country.
    private static java.util.Optional<String> anchorCountry(SignatureWrapper signature) {
        var chain = signature.getCertificateChain();
        for (var index = chain.size() - 1; index >= 0; index--) {
            var country = chain.get(index).getCountryName();
            if (country != null && !country.isBlank()) {
                return java.util.Optional.of(normalized(country));
            }
        }
        return java.util.Optional.empty();
    }

    /// A schema-valid ETSI report with only this signature's SignatureValidationReport and the
    /// validation objects reduced to their identifiers and types, so the signed record stays small.
    static String slimReport(String etsi, String signatureId) {
        try {
            var factory = DocumentBuilderFactory.newInstance();
            factory.setNamespaceAware(true);
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            var document = factory.newDocumentBuilder().parse(new ByteArrayInputStream(etsi.getBytes(StandardCharsets.UTF_8)));
            var reports = document.getElementsByTagNameNS(ANY_NAMESPACE, "SignatureValidationReport");
            for (var index = reports.getLength() - 1; index >= 0; index--) {
                var report = (Element) reports.item(index);
                if (!signatureId.equals(signatureIdentifier(report))) {
                    report.getParentNode().removeChild(report);
                }
            }
            var representations = document.getElementsByTagNameNS(ANY_NAMESPACE, "ValidationObjectRepresentation");
            for (var index = representations.getLength() - 1; index >= 0; index--) {
                var representation = representations.item(index);
                representation.getParentNode().removeChild(representation);
            }
            var output = new ByteArrayOutputStream();
            var transformer = TransformerFactory.newInstance().newTransformer();
            transformer.setOutputProperty(OutputKeys.ENCODING, "UTF-8");
            transformer.transform(new DOMSource(document), new StreamResult(output));
            return Base64.getEncoder().encodeToString(output.toByteArray());
        } catch (Exception exception) {
            throw new IllegalStateException("ETSI report could not be reduced", exception);
        }
    }

    private static String signatureIdentifier(Element report) {
        var identifiers = report.getElementsByTagNameNS(ANY_NAMESPACE, "SignatureIdentifier");
        return identifiers.getLength() == 0 ? null : ((Element) identifiers.item(0)).getAttribute("id");
    }

    /// In a container with several data objects, one larger than this is listed with its hash
    /// only, never parsed. A container's only data object is read whatever its size, as before.
    static final long DATA_OBJECT_LIMIT = 100L * 1024 * 1024;

    /// PDF facts for a PDF source, or for an ASiC-E's only PDF data object; null otherwise.
    /// A container also lists every data object (`dataObjects`) in zip entry order.
    private JsonObject pdfFacts(byte[] content, DiagnosticData diagnostic, JsonObject knownPdfFacts) {
        if (startsWith(content, "%PDF")) {
            var facts = knownPdfFacts != null ? knownPdfFacts.deepCopy() : PdfConversionFacts.read(content);
            facts.add("changesAfterLastSignature", changesAfterLastSignature(diagnostic));
            return facts;
        }
        if (!startsWith(content, "PK")) {
            return null;
        }
        var entries = new ArrayList<ContainerEntry>();
        try (var zip = new ZipInputStream(new ByteArrayInputStream(content))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                var name = entry.getName();
                if (entry.isDirectory() || name.equals("mimetype") || name.startsWith("META-INF/")) {
                    continue;
                }
                entries.add(new ContainerEntry(name, zip.readAllBytes()));
            }
        } catch (IOException exception) {
            return null;
        }
        // The only data object counts as the container's PDF by its bytes, never its name.
        var onlyPdf = entries.size() == 1 && kindOf(entries.getFirst().bytes()).equals("pdf")
                ? entries.getFirst().bytes() : null;
        var onlyPdfFacts = onlyPdf != null ? readPdfFacts(onlyPdf) : null;
        var facts = onlyPdfFacts != null ? onlyPdfFacts.deepCopy() : new JsonObject();
        facts.addProperty("asicDataObjectCount", entries.size());
        if (onlyPdf != null) {
            facts.addProperty("asicDataObjectName", entries.getFirst().name());
            facts.addProperty("asicDataObjectSigned", signedOrUnknown(onlyPdf));
        }
        var names = new HashSet<String>();
        for (var entry : entries) {
            if (!names.add(entry.name())) {
                // Two entries under one name make the data object ambiguous; the app refuses it.
                facts.addProperty("duplicateDataObjectName", entry.name());
                break;
            }
        }
        facts.add("changesAfterLastSignature", new JsonArray());
        var coverage = signatureCoverage(diagnostic);
        var dataObjects = new JsonArray();
        for (var entry : entries) {
            // The only PDF's facts are reused, so veraPDF does not run twice on the same bytes.
            var known = onlyPdfFacts != null && kindOf(entry.bytes()).equals("pdf") ? onlyPdfFacts : null;
            dataObjects.add(dataObjectFacts(entry, coverage.getOrDefault(entry.name(), List.of()), known,
                    entries.size() > 1));
        }
        facts.add("dataObjects", dataObjects);
        return facts;
    }

    record ContainerEntry(String name, byte[] bytes) {
    }

    /// For each signed file name, the ids of the signatures whose scope names it, in the order
    /// DSS lists the signatures.
    static Map<String, List<String>> signatureCoverage(DiagnosticData diagnostic) {
        var coverage = new HashMap<String, List<String>>();
        for (var signature : diagnostic.getSignatures()) {
            var scopes = signature.getSignatureScopes();
            if (scopes == null) continue;
            for (var scope : scopes) {
                var name = scope.getName();
                if (name == null) continue;
                var ids = coverage.computeIfAbsent(name, key -> new ArrayList<>());
                if (!ids.contains(signature.getId())) ids.add(signature.getId());
            }
        }
        return coverage;
    }

    /// One data object: name, size, hash and the signatures covering it, plus what its kind,
    /// read from its bytes, tells: PDF facts and page count, or image size and resolution.
    /// A PDF that carries PAdES signatures also gets its own `evidence` (see `addNestedEvidence`).
    private JsonObject dataObjectFacts(ContainerEntry entry, List<String> coveredBy, JsonObject knownPdfFacts,
            boolean limited) {
        var bytes = entry.bytes();
        var facts = new JsonObject();
        facts.addProperty("name", entry.name());
        facts.addProperty("size", bytes.length);
        facts.addProperty("sha256Base64", sha256Base64(bytes));
        var covered = new JsonArray();
        coveredBy.forEach(covered::add);
        facts.add("coveredBy", covered);
        var kind = kindOf(bytes);
        if (limited && bytes.length > dataObjectLimit) {
            facts.addProperty("kind", "other");
            facts.addProperty("problem", "TOO_LARGE");
            return facts;
        }
        switch (kind) {
            case "pdf" -> {
                var pdf = knownPdfFacts != null ? knownPdfFacts : readPdfFacts(bytes);
                if (pdf.has("readable") && !pdf.get("readable").getAsBoolean()) {
                    facts.addProperty("kind", "other");
                    facts.addProperty("problem", "UNREADABLE");
                    return facts;
                }
                facts.addProperty("kind", "pdf");
                pdf.entrySet().forEach(item -> facts.add(item.getKey(), item.getValue()));
                addNestedEvidence(facts, bytes, pdf);
            }
            case "png", "jpeg" -> {
                if (!addImageFacts(facts, bytes)) {
                    facts.addProperty("kind", "other");
                    facts.addProperty("problem", "UNREADABLE");
                    return facts;
                }
                facts.addProperty("kind", kind);
            }
            default -> facts.addProperty("kind", "other");
        }
        return facts;
    }

    /// A PDF data object that carries PAdES signatures or document timestamps gets `evidence`:
    /// the same keys as the top-level evidence (no tree), from one more validation of its own
    /// bytes through the same injected validation and trusted list state, so
    /// `signedRevisionLength` and `coveredRevisionLength` are relative to it. A PDF with document
    /// timestamps only gets it with no signatures, so its timestamps are not lost. Never
    /// recurses: the nested `pdf` facts of a PDF list no data objects. A failure leaves the kind
    /// `pdf`, omits `evidence` and adds `problem` "NESTED_UNREADABLE".
    private void addNestedEvidence(JsonObject facts, byte[] bytes, JsonObject pdfFacts) {
        try {
            if (!signatureProbe.test(bytes) && !hasDocumentTimestamps(bytes)) return;
            var body = evidenceBody(new InMemoryDocument(bytes), bytes, pdfFacts);
            if (body.evidence().getAsJsonArray("signatures").isEmpty()
                    && body.evidence().getAsJsonArray("documentTimestamps").isEmpty()) {
                return;
            }
            facts.add("evidence", body.evidence());
        } catch (RuntimeException exception) {
            facts.addProperty("problem", "NESTED_UNREADABLE");
        }
    }

    /// Whether the only PDF carries signatures of its own; true when DSS cannot tell, so a PDF
    /// whose signatures could not be read never takes the unsigned path.
    private boolean signedOrUnknown(byte[] bytes) {
        try {
            return signatureProbe.test(bytes);
        } catch (RuntimeException exception) {
            return true;
        }
    }

    /// Whether DSS finds any signature in these PDF bytes, without validating it. Throws when
    /// DSS cannot read them, never answering "unsigned" for bytes it could not look into.
    static boolean hasSignatures(byte[] bytes) {
        var validator = DSSUtils.createDocumentValidator(new InMemoryDocument(bytes));
        if (validator == null) {
            throw new IllegalArgumentException("No validator for PDF bytes");
        }
        validator.setCertificateVerifier(new eu.europa.esig.dss.spi.validation.CommonCertificateVerifier());
        return !validator.getSignatures().isEmpty();
    }

    /// Whether DSS finds a document timestamp (a timestamp revision, PAdES-LTA or the content
    /// timestamp before a PAdES signature) in these PDF bytes, without validating it. Throws
    /// when DSS cannot read them.
    static boolean hasDocumentTimestamps(byte[] bytes) {
        var validator = DSSUtils.createDocumentValidator(new InMemoryDocument(bytes));
        if (validator == null) {
            throw new IllegalArgumentException("No validator for PDF bytes");
        }
        validator.setCertificateVerifier(new eu.europa.esig.dss.spi.validation.CommonCertificateVerifier());
        return !validator.getDetachedTimestamps().isEmpty();
    }

    /// `PdfConversionFacts.read`, with a PDFBox runtime failure on malformed bytes reported as
    /// `readable` false like an I/O failure, so one bad data object never fails the evidence.
    private static JsonObject readPdfFacts(byte[] bytes) {
        try {
            return PdfConversionFacts.read(bytes);
        } catch (RuntimeException exception) {
            var facts = new JsonObject();
            facts.addProperty("readable", false);
            return facts;
        }
    }

    private static final byte[] PNG_SIGNATURE = {(byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
    private static final byte[] JPEG_SIGNATURE = {(byte) 0xFF, (byte) 0xD8, (byte) 0xFF};

    /// `pdf`, `png`, `jpeg` or `other`, from the leading bytes only, never the name.
    static String kindOf(byte[] bytes) {
        if (startsWith(bytes, "%PDF")) return "pdf";
        if (startsWith(bytes, PNG_SIGNATURE)) return "png";
        if (startsWith(bytes, JPEG_SIGNATURE)) return "jpeg";
        return "other";
    }

    /// Adds `widthPx`, `heightPx` and, when the file states a resolution, `dpiX` and `dpiY`.
    /// False when no image reader can read the header.
    private static boolean addImageFacts(JsonObject facts, byte[] bytes) {
        try (var input = new MemoryCacheImageInputStream(new ByteArrayInputStream(bytes))) {
            var readers = ImageIO.getImageReaders(input);
            if (!readers.hasNext()) return false;
            var reader = readers.next();
            try {
                reader.setInput(input, true, false);
                facts.addProperty("widthPx", reader.getWidth(0));
                facts.addProperty("heightPx", reader.getHeight(0));
                try {
                    var metadata = reader.getImageMetadata(0);
                    if (metadata != null && metadata.isStandardMetadataFormatSupported()) {
                        var root = metadata.getAsTree(IIOMetadataFormatImpl.standardMetadataFormatName);
                        var dpiX = dpi(root, "HorizontalPixelSize");
                        var dpiY = dpi(root, "VerticalPixelSize");
                        if (dpiX != null && dpiY != null) {
                            facts.addProperty("dpiX", dpiX);
                            facts.addProperty("dpiY", dpiY);
                        }
                    }
                } catch (IOException | RuntimeException exception) {
                    // The size is known; a resolution the reader cannot parse is simply not stated.
                }
                return true;
            } finally {
                reader.dispose();
            }
        } catch (IOException | RuntimeException exception) {
            return false;
        }
    }

    /// Dots per inch from the standard metadata's millimetres per pixel, rounded to two places.
    private static Double dpi(org.w3c.dom.Node root, String name) {
        for (var dimension = root.getFirstChild(); dimension != null; dimension = dimension.getNextSibling()) {
            if (!"Dimension".equals(dimension.getNodeName())) continue;
            for (var child = dimension.getFirstChild(); child != null; child = child.getNextSibling()) {
                if (!name.equals(child.getNodeName())) continue;
                var value = ((Element) child).getAttribute("value");
                try {
                    var millimetres = Double.parseDouble(value);
                    if (millimetres <= 0 || Double.isNaN(millimetres) || Double.isInfinite(millimetres)) return null;
                    return Math.round(25.4 / millimetres * 100.0) / 100.0;
                } catch (NumberFormatException exception) {
                    return null;
                }
            }
        }
        return null;
    }

    private static String sha256Base64(byte[] bytes) {
        try {
            return Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException(exception);
        }
    }

    /// Kinds of change DSS found after the last PAdES signature's revision, other than
    /// extension data (DSS dictionary, document timestamps): content nobody signed.
    static JsonArray changesAfterLastSignature(DiagnosticData diagnostic) {
        SignatureWrapper last = null;
        BigInteger lastEnd = BigInteger.valueOf(-1);
        for (var signature : diagnostic.getSignatures()) {
            var revision = signature.getPDFRevision();
            if (revision == null || revision.getSignatureByteRange() == null || revision.getSignatureByteRange().size() != 4) {
                continue;
            }
            var end = revision.getSignatureByteRange().get(2).add(revision.getSignatureByteRange().get(3));
            if (end.compareTo(lastEnd) > 0) {
                lastEnd = end;
                last = signature;
            }
        }
        var changes = new JsonArray();
        if (last == null) {
            return changes;
        }
        var revision = last.getPDFRevision();
        if (!revision.getPdfSignatureOrFormFillChanges().isEmpty()) changes.add("SIGNATURE_OR_FORM_FILL");
        if (!revision.getPdfAnnotationChanges().isEmpty()) changes.add("ANNOTATION");
        if (!revision.getPdfUndefinedChanges().isEmpty()) changes.add("UNDEFINED");
        if (!revision.getPdfPageDifferenceConcernedPages().isEmpty()) changes.add("PAGE_DIFFERENCE");
        if (!revision.getPdfVisualDifferenceConcernedPages().isEmpty()) changes.add("VISUAL_DIFFERENCE");
        return changes;
    }

    private static boolean startsWith(byte[] content, String prefix) {
        return startsWith(content, prefix.getBytes(StandardCharsets.US_ASCII));
    }

    private static boolean startsWith(byte[] content, byte[] bytes) {
        if (content.length < bytes.length) return false;
        for (var index = 0; index < bytes.length; index++) {
            if (content[index] != bytes[index]) return false;
        }
        return true;
    }

    private static String base64(String text) {
        return Base64.getEncoder().encodeToString(text.getBytes(StandardCharsets.UTF_8));
    }

    private static String normalized(String country) {
        return country.trim().toUpperCase(Locale.ROOT);
    }

    /// Facts DSS's diagnostic data does not carry: subject `MANDANT ...` values and the
    /// `userNotice` explicit text of each certificate policy (the SAK mandate's text).
    record X509Facts(List<String> mandants, List<Policy> policies) {
        record Policy(String oid, String explicitText) {
        }

        static X509Facts of(byte[] certificate) {
            var mandants = new ArrayList<String>();
            var policies = new ArrayList<Policy>();
            if (certificate == null) {
                return new X509Facts(mandants, policies);
            }
            try {
                var holder = new X509CertificateHolder(certificate);
                for (var rdn : holder.getSubject().getRDNs()) {
                    for (var value : rdn.getTypesAndValues()) {
                        if (value.getValue() instanceof ASN1String text
                                && text.getString().startsWith("MANDANT ")) {
                            mandants.add(text.getString());
                        }
                    }
                }
                var extensions = holder.getExtensions();
                var certificatePolicies = extensions == null ? null : CertificatePolicies.fromExtensions(extensions);
                if (certificatePolicies != null) {
                    for (var information : certificatePolicies.getPolicyInformation()) {
                        String explicitText = null;
                        var qualifiers = information.getPolicyQualifiers();
                        if (qualifiers != null) {
                            for (var element : qualifiers) {
                                var qualifier = PolicyQualifierInfo.getInstance(element);
                                if (PolicyQualifierId.id_qt_unotice.equals(qualifier.getPolicyQualifierId())) {
                                    var notice = UserNotice.getInstance(qualifier.getQualifier());
                                    if (notice.getExplicitText() != null) {
                                        explicitText = notice.getExplicitText().getString();
                                    }
                                }
                            }
                        }
                        policies.add(new Policy(information.getPolicyIdentifier().getId(), explicitText));
                    }
                }
            } catch (IOException | RuntimeException exception) {
                // An unreadable extension leaves the facts DSS gave; the clause then omits them.
            }
            return new X509Facts(mandants, policies);
        }

        /// `Mandate` as the clause documents it: the last arc of a policy under the Slovak
        /// mandate arc plus that policy's explicit text.
        String mandate() {
            for (var policy : policies) {
                if (policy.oid().startsWith(MANDATE_POLICY_PREFIX)) {
                    var arc = policy.oid().substring(policy.oid().lastIndexOf('.') + 1);
                    return policy.explicitText() == null ? arc : arc + " " + policy.explicitText();
                }
            }
            return null;
        }
    }

    /// Hands the already computed report to the tree inspection for the top document, so the
    /// document is validated once; nested data objects go through the same injected validation.
    private static final class FirstReportReader implements MachineInspectionService.ValidatorReportReader {
        private SimpleReport first;
        private final Function<SignedDocumentValidator, Reports> validation;

        FirstReportReader(SimpleReport first, Function<SignedDocumentValidator, Reports> validation) {
            this.first = first;
            this.validation = validation;
        }

        @Override
        public synchronized SimpleReport read(SignedDocumentValidator validator) {
            if (first != null) {
                var report = first;
                first = null;
                return report;
            }
            return validation.apply(validator).getSimpleReport();
        }
    }
}
