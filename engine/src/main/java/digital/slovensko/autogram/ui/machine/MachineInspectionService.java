package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import digital.slovensko.autogram.core.SignatureValidator;
import digital.slovensko.autogram.util.DSSUtils;
import eu.europa.esig.dss.asic.cades.extract.ASiCWithCAdESContainerExtractor;
import eu.europa.esig.dss.asic.cades.validation.ASiCContainerWithCAdESValidator;
import eu.europa.esig.dss.asic.xades.extract.ASiCWithXAdESContainerExtractor;
import eu.europa.esig.dss.asic.xades.validation.ASiCContainerWithXAdESValidator;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.FileDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.simplereport.SimpleReport;
import eu.europa.esig.dss.spi.signature.AdvancedSignature;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.spi.x509.tsp.TimestampToken;
import eu.europa.esig.dss.validation.SignedDocumentValidator;

import java.io.IOException;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;

public final class MachineInspectionService {
    static final long DEFAULT_NESTED_SIZE_LIMIT = 100L * 1024 * 1024;
    private long nestedSizeLimit = DEFAULT_NESTED_SIZE_LIMIT;

    private final ReportReader reportReader;
    private final ByteReportReader byteReportReader;
    private final TimestampQualificationEvaluator timestampQualificationEvaluator;
    private final boolean genericPathInspection;
    private final ValidatorReportReader validatorReportReader;

    public MachineInspectionService() {
        reportReader = null;
        byteReportReader = null;
        timestampQualificationEvaluator = new TimestampQualificationEvaluator();
        genericPathInspection = true;
        validatorReportReader = null;
    }

    MachineInspectionService(ReportReader reportReader) {
        this(reportReader, content -> readTrustedReport(documentValidator(new InMemoryDocument(content))));
    }

    MachineInspectionService(ReportReader reportReader, ByteReportReader byteReportReader) {
        this.reportReader = reportReader;
        this.byteReportReader = byteReportReader;
        timestampQualificationEvaluator = new TimestampQualificationEvaluator();
        genericPathInspection = false;
        validatorReportReader = null;
    }

    static MachineInspectionService withValidatorReportReader(ValidatorReportReader validatorReportReader) {
        return new MachineInspectionService(validatorReportReader, true);
    }

    public static MachineInspectionService forTrustedValidation() {
        return forTrustedValidation(MachineInspectionService::readTrustedReport);
    }

    public static MachineInspectionService forTrustedValidation(ValidatorReportReader validatorReportReader) {
        return new MachineInspectionService(validatorReportReader, true);
    }

    private MachineInspectionService(ValidatorReportReader validatorReportReader, boolean genericPathInspection) {
        reportReader = null;
        byteReportReader = null;
        timestampQualificationEvaluator = new TimestampQualificationEvaluator();
        this.genericPathInspection = genericPathInspection;
        this.validatorReportReader = validatorReportReader;
    }

    /// Test hook: a smaller limit for the TOO_LARGE case without a 100 MB fixture.
    MachineInspectionService withNestedSizeLimit(long bytes) {
        nestedSizeLimit = bytes;
        return this;
    }

    public JsonObject inspect(Path path) {
        if (genericPathInspection) {
            return inspectTree(new FileDocument(path.toFile()), 0);
        }
        return mapReport(reportReader.read(path));
    }

    /// One level of the signature tree: this document's own signatures and, for an ASiC
    /// container, its data objects. Data objects of the top document (depth 0) that are a
    /// PDF or an ASiC are inspected the same way; deeper ones are only marked.
    private JsonObject inspectTree(DSSDocument document, int depth) {
        var validator = documentValidator(document);
        JsonObject payload;
        if (validatorReportReader == null) {
            payload = inspectStructurally(document, validator);
        } else {
            var trusted = mapAsicInspection(readTrustedInspection(document, validator));
            payload = mergeStructuralIntegrityIfAvailable(trusted, document);
        }
        if (isAsic(validator) && payload.has("documents")) {
            addNestedContent(payload.getAsJsonArray("documents"), extractedDocuments(document, validator), depth);
        }
        return payload;
    }

    private void addNestedContent(com.google.gson.JsonArray entries, List<DSSDocument> extracted, int depth) {
        var byName = new LinkedHashMap<String, DSSDocument>();
        for (var candidate : extracted) {
            if (candidate.getName() != null) {
                byName.putIfAbsent(candidate.getName(), candidate);
            }
        }
        for (var element : entries) {
            var entry = element.getAsJsonObject();
            var source = byName.get(entry.get("name").getAsString());
            if (source == null) {
                continue;
            }
            try {
                var bytes = readOriginalBytes(source);
                var pdf = isPdf(bytes);
                if (!pdf && !isZip(bytes)) {
                    continue;
                }
                if (bytes.length > nestedSizeLimit) {
                    entry.addProperty("nestedSkipped", "TOO_LARGE");
                    continue;
                }
                var kind = pdf ? "PDF" : (isAsicContent(bytes, source.getName()) ? "ASIC" : null);
                if (kind == null) {
                    continue;
                }
                if (depth >= 1) {
                    entry.addProperty("nestedSkipped", "DEPTH_LIMIT");
                    continue;
                }
                var nested = inspectTree(new InMemoryDocument(bytes, source.getName()), depth + 1);
                nested.addProperty("kind", kind);
                entry.add("nested", nested);
            } catch (RuntimeException exception) {
                entry.addProperty("nestedError", "NESTED_INSPECTION_FAILED");
            }
        }
    }

    private static boolean isPdf(byte[] bytes) {
        return bytes.length >= 5 && bytes[0] == '%' && bytes[1] == 'P' && bytes[2] == 'D' && bytes[3] == 'F'
                && bytes[4] == '-';
    }

    private static boolean isZip(byte[] bytes) {
        return bytes.length >= 4 && bytes[0] == 'P' && bytes[1] == 'K' && bytes[2] == 3 && bytes[3] == 4;
    }

    private static boolean isAsicContent(byte[] bytes, String name) {
        try {
            var validator = DSSUtils.createDocumentValidator(new InMemoryDocument(bytes, name));
            return validator != null && isAsic(validator);
        } catch (RuntimeException exception) {
            return false;
        }
    }

    public JsonObject inspect(byte[] content) {
        if (genericPathInspection) {
            if (validatorReportReader == null) {
                return inspectStructurally(new InMemoryDocument(content));
            }
            var trusted = mapReport(validatorReportReader.read(documentValidator(new InMemoryDocument(content))));
            return mergeStructuralIntegrityIfAvailable(trusted, new InMemoryDocument(content));
        }
        return mapReport(byteReportReader.read(content));
    }

    public EmbeddedDocument extractEmbeddedDocument(Path path, String expectedName) {
        DSSDocument source = new FileDocument(path.toFile());
        var validator = documentValidator(source);
        if (!isAsic(validator)) {
            throw new MachineProtocolException("PREVIEW_UNSUPPORTED");
        }
        return extractedDocuments(source, validator).stream()
                .filter(document -> expectedName.equals(document.getName()))
                .findFirst()
                .map(document -> new EmbeddedDocument(
                        document.getName(),
                        document.getMimeType() == null ? "application/octet-stream"
                                : document.getMimeType().getMimeTypeString(),
                        readBytes(document)))
                .orElseThrow(() -> new MachineProtocolException("PREVIEW_DOCUMENT_NOT_FOUND"));
    }

    private JsonObject mergeStructuralIntegrityIfAvailable(JsonObject trusted, DSSDocument document) {
        try {
            return mergeCryptographicIntegrity(trusted, inspectStructurally(document));
        } catch (RuntimeException exception) {
            return trusted;
        }
    }

    static JsonObject mergeCryptographicIntegrity(JsonObject trusted, JsonObject structural) {
        var structuralSignatures = objectsById(structural.getAsJsonArray("signatures"));
        for (var value : trusted.getAsJsonArray("signatures")) {
            var signature = value.getAsJsonObject();
            var structuralSignature = structuralSignatures.get(stringValue(signature, "id"));
            if (structuralSignature == null) {
                continue;
            }
            copyBoolean(structuralSignature, signature, "cryptographicIntegrity");
            var structuralTimestamps = objectsById(structuralSignature.getAsJsonArray("timestamps"));
            for (var timestampValue : signature.getAsJsonArray("timestamps")) {
                var timestamp = timestampValue.getAsJsonObject();
                var structuralTimestamp = structuralTimestamps.get(stringValue(timestamp, "id"));
                if (structuralTimestamp != null) {
                    copyBoolean(structuralTimestamp, timestamp, "cryptographicIntegrity");
                }
            }
        }
        return trusted;
    }

    private static Map<String, JsonObject> objectsById(com.google.gson.JsonArray values) {
        var result = new LinkedHashMap<String, JsonObject>();
        if (values == null) {
            return result;
        }
        for (var value : values) {
            var object = value.getAsJsonObject();
            var id = stringValue(object, "id");
            if (id != null) {
                result.put(id, object);
            }
        }
        return result;
    }

    private static String stringValue(JsonObject value, String field) {
        return value.has(field) && !value.get(field).isJsonNull() ? value.get(field).getAsString() : null;
    }

    private static void copyBoolean(JsonObject source, JsonObject target, String field) {
        if (source.has(field) && source.get(field).isJsonPrimitive()
                && source.get(field).getAsJsonPrimitive().isBoolean()) {
            target.addProperty(field, source.get(field).getAsBoolean());
        }
    }

    /// True when the content is an ASiC container with at least one signature and every
    /// signature covers a data object byte-identical to the document. Bytes decide, never
    /// names: a signed PDF wrapped into a new container keeps its own signatures only when
    /// the container carries it unchanged.
    static boolean signaturesCoverDocument(byte[] container, byte[] document) {
        try {
            var validator = documentValidator(new InMemoryDocument(container));
            if (!isAsic(validator)) {
                return false;
            }
            var signatures = validator.getSignatures();
            if (signatures.isEmpty()) {
                return false;
            }
            for (var signature : signatures) {
                var covered = validator.getOriginalDocuments(signature.getId()).stream()
                        .anyMatch(original -> java.util.Arrays.equals(readOriginalBytes(original), document));
                if (!covered) {
                    return false;
                }
            }
            return true;
        } catch (RuntimeException exception) {
            return false;
        }
    }

    private static byte[] readOriginalBytes(DSSDocument document) {
        try (var stream = document.openStream()) {
            return stream.readAllBytes();
        } catch (IOException exception) {
            throw new java.io.UncheckedIOException(exception);
        }
    }

    static int readStructuralSignatureCount(Path path) {
        return documentValidator(new FileDocument(path.toFile())).getSignatures().size();
    }

    private static SimpleReport readTrustedReport(SignedDocumentValidator validator) {
        return SignatureValidator.getInstance().validate(validator).getSimpleReport();
    }

    private AsicInspection readTrustedInspection(DSSDocument document, SignedDocumentValidator validator) {
        var report = validatorReportReader.read(validator);
        if (!isAsic(validator)) {
            return new AsicInspection(report, null, Map.of());
        }
        var documents = asicDocuments(document, validator);
        var coverage = new LinkedHashMap<String, List<String>>();
        for (var signatureId : report.getSignatureIdList()) {
            coverage.put(signatureId, documentNames(validator.getOriginalDocuments(signatureId)));
        }
        return new AsicInspection(report, documents, coverage);
    }

    private JsonObject inspectStructurally(DSSDocument document) {
        return inspectStructurally(document, documentValidator(document));
    }

    private JsonObject inspectStructurally(DSSDocument document, SignedDocumentValidator validator) {
        var asic = isAsic(validator);
        var payload = new JsonObject();
        var signaturePayloads = new com.google.gson.JsonArray();
        for (var signature : validator.getSignatures()) {
            var mapped = mapStructuralSignature(readStructuralSignature(signature));
            if (asic) {
                var covered = documentNames(validator.getOriginalDocuments(signature.getId()));
                if (!covered.isEmpty()) {
                    var names = new com.google.gson.JsonArray();
                    covered.forEach(names::add);
                    mapped.add("documents", names);
                }
            }
            signaturePayloads.add(mapped);
        }
        payload.add("signatures", signaturePayloads);
        if (asic) {
            var documents = new com.google.gson.JsonArray();
            for (var name : asicDocuments(document, validator)) {
                var item = new JsonObject();
                item.addProperty("name", name);
                documents.add(item);
            }
            payload.add("documents", documents);
        }
        return payload;
    }

    private static StructuralSignature readStructuralSignature(AdvancedSignature signature) {
        boolean cryptographicIntegrity = false;
        try {
            signature.initBaselineRequirementsChecker(new CommonCertificateVerifier());
            signature.checkSignatureIntegrity();
            var verification = signature.getSignatureCryptographicVerification();
            cryptographicIntegrity = verification != null && verification.isSignatureValid();
        } catch (RuntimeException exception) {
            cryptographicIntegrity = false;
        }
        var certificate = signature.getSigningCertificateToken();
        var signerDisplayName = certificate == null ? null : DSSUtils.parseCN(certificate.getSubject().getRFC2253());
        var timestamps = signature.getSignatureTimestamps().stream()
                .map(MachineInspectionService::readStructuralTimestamp).toList();
        return new StructuralSignature(signature.getId(), signature.getDataFoundUpToLevel(), signerDisplayName,
                signature.getSigningTime(), cryptographicIntegrity, timestamps);
    }

    private static StructuralTimestamp readStructuralTimestamp(TimestampToken timestamp) {
        return new StructuralTimestamp(timestamp.getDSSIdAsString(), timestamp.getGenerationTime(),
                timestamp.getIssuerX500Principal() == null ? null : timestamp.getIssuerX500Principal().getName(),
                hasCryptographicIntegrity(timestamp));
    }

    private static boolean hasCryptographicIntegrity(TimestampToken timestamp) {
        try {
            return timestamp.isMessageImprintDataIntact()
                    && timestamp.getCertificateSource().getCertificates().stream().anyMatch(timestamp::isSignedBy);
        } catch (RuntimeException exception) {
            return false;
        }
    }

    private static JsonObject mapStructuralSignature(StructuralSignature source) {
        var signature = new JsonObject();
        addString(signature, "id", source.id());
        addEnum(signature, "format", source.format());
        addString(signature, "signerDisplayName", source.signerDisplayName());
        signature.add("signerCertificateQualification", JsonNull.INSTANCE);
        addDate(signature, "signingTime", source.signingTime());
        signature.addProperty("valid", source.cryptographicIntegrity());
        signature.addProperty("cryptographicIntegrity", source.cryptographicIntegrity());
        signature.addProperty("indication", "INDETERMINATE");
        signature.addProperty("qualifiedTimestampValid", false);
        var timestamps = new com.google.gson.JsonArray();
        for (var timestamp : source.timestamps()) {
            var item = new JsonObject();
            addString(item, "id", timestamp.id());
            addDate(item, "productionTime", timestamp.productionTime());
            addString(item, "producer", timestamp.producer());
            item.addProperty("valid", timestamp.cryptographicIntegrity());
            item.addProperty("cryptographicIntegrity", timestamp.cryptographicIntegrity());
            item.add("qualification", JsonNull.INSTANCE);
            timestamps.add(item);
        }
        signature.add("timestamps", timestamps);
        return signature;
    }

    private static SignedDocumentValidator documentValidator(DSSDocument document) {
        var validator = DSSUtils.createDocumentValidator(document);
        if (validator == null) {
            throw new IllegalArgumentException("Unsupported document");
        }
        validator.setCertificateVerifier(new CommonCertificateVerifier());
        return validator;
    }

    private static boolean isAsic(SignedDocumentValidator validator) {
        return validator instanceof ASiCContainerWithXAdESValidator || validator instanceof ASiCContainerWithCAdESValidator;
    }

    private static List<String> asicDocuments(DSSDocument document, SignedDocumentValidator validator) {
        return documentNames(extractedDocuments(document, validator));
    }

    private static List<DSSDocument> extractedDocuments(DSSDocument document, SignedDocumentValidator validator) {
        if (validator instanceof ASiCContainerWithXAdESValidator) {
            return new ASiCWithXAdESContainerExtractor(document).extract().getSignedDocuments();
        }
        return new ASiCWithCAdESContainerExtractor(document).extract().getSignedDocuments();
    }

    private static byte[] readBytes(DSSDocument document) {
        try (var stream = document.openStream()) {
            return stream.readAllBytes();
        } catch (IOException exception) {
            throw new MachineProtocolException("PREVIEW_READ_FAILED", exception);
        }
    }

    private static List<String> documentNames(List<DSSDocument> documents) {
        var names = new LinkedHashSet<String>();
        for (var document : documents) {
            if (document.getName() != null) {
                names.add(document.getName());
            }
        }
        return List.copyOf(names);
    }

    private JsonObject mapReport(SimpleReport report) {
        return mapAsicInspection(new AsicInspection(report, null, Map.of()));
    }

    private JsonObject mapAsicInspection(AsicInspection inspection) {
        var payload = new JsonObject();
        var signatures = new com.google.gson.JsonArray();
        for (var signatureId : inspection.report().getSignatureIdList()) {
            signatures.add(mapSignature(inspection.report(), signatureId,
                    inspection.coverage().getOrDefault(signatureId, List.of())));
        }
        payload.add("signatures", signatures);
        if (inspection.documents() != null) {
            var documents = new com.google.gson.JsonArray();
            for (var name : inspection.documents()) {
                var document = new JsonObject();
                document.addProperty("name", name);
                documents.add(document);
            }
            payload.add("documents", documents);
        }
        return payload;
    }

    private JsonObject mapSignature(SimpleReport report, String signatureId, List<String> coveredDocuments) {
        var signature = new JsonObject();
        addString(signature, "id", signatureId);
        addEnum(signature, "format", report.getSignatureFormat(signatureId));
        addString(signature, "signerDisplayName", report.getSignedBy(signatureId));
        addEnum(signature, "signerCertificateQualification", report.getSignatureQualification(signatureId));
        addDate(signature, "signingTime", report.getSigningTime(signatureId));
        signature.addProperty("valid", report.isValid(signatureId));
        addEnum(signature, "indication", report.getIndication(signatureId));
        addEnum(signature, "subIndication", report.getSubIndication(signatureId));
        addString(signature, "validationReason", firstValidationReason(report, signatureId));
        signature.addProperty("qualifiedTimestampValid",
                timestampQualificationEvaluator.hasValidQualifiedTimestamp(report, signatureId));

        var timestamps = new com.google.gson.JsonArray();
        for (var timestamp : report.getSignatureTimestamps(signatureId)) {
            timestamps.add(mapTimestamp(report, timestamp.getId()));
        }
        signature.add("timestamps", timestamps);
        if (!coveredDocuments.isEmpty()) {
            var documents = new com.google.gson.JsonArray();
            for (var name : coveredDocuments) {
                documents.add(name);
            }
            signature.add("documents", documents);
        }
        return signature;
    }

    private static String firstValidationReason(SimpleReport report, String signatureId) {
        return report.getAdESValidationErrors(signatureId).stream()
                .map(message -> message.getValue())
                .filter(value -> value != null && !value.isBlank())
                .findFirst()
                .orElse(null);
    }

    private static JsonObject mapTimestamp(SimpleReport report, String timestampId) {
        var timestamp = new JsonObject();
        addString(timestamp, "id", timestampId);
        addDate(timestamp, "productionTime", report.getProductionTime(timestampId));
        addString(timestamp, "producer", report.getProducedBy(timestampId));
        timestamp.addProperty("valid", report.isValid(timestampId));
        addEnum(timestamp, "qualification", report.getTimestampQualification(timestampId));
        return timestamp;
    }

    private static void addDate(JsonObject payload, String field, Date value) {
        if (value == null) {
            payload.add(field, JsonNull.INSTANCE);
            return;
        }
        payload.addProperty(field, Instant.ofEpochMilli(value.getTime()).toString());
    }

    private static void addString(JsonObject payload, String field, Object value) {
        if (value == null) {
            payload.add(field, JsonNull.INSTANCE);
            return;
        }
        payload.addProperty(field, value.toString());
    }

    private static void addEnum(JsonObject payload, String field, Enum<?> value) {
        if (value == null) {
            payload.add(field, JsonNull.INSTANCE);
            return;
        }
        payload.addProperty(field, value.name());
    }

    @FunctionalInterface
    interface ReportReader {
        SimpleReport read(Path path);
    }

    @FunctionalInterface
    interface ByteReportReader {
        SimpleReport read(byte[] content);
    }

    @FunctionalInterface
    public interface ValidatorReportReader {
        SimpleReport read(SignedDocumentValidator validator);
    }

    public record EmbeddedDocument(String name, String mediaType, byte[] content) {
    }

    private record AsicInspection(SimpleReport report, List<String> documents, Map<String, List<String>> coverage) {
    }

    private record StructuralSignature(String id, Enum<?> format, String signerDisplayName, Date signingTime,
            boolean cryptographicIntegrity, List<StructuralTimestamp> timestamps) {
    }

    private record StructuralTimestamp(String id, Date productionTime, String producer, boolean cryptographicIntegrity) {
    }
}
