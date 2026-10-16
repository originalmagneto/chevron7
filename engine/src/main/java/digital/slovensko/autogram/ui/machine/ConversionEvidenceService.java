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
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.function.Function;
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

    public ConversionEvidenceService() {
        this(validator -> SignatureValidator.getInstance().validate(validator),
                () -> SignatureValidator.getInstance().unavailableTrustedListCountries());
    }

    ConversionEvidenceService(Function<SignedDocumentValidator, Reports> validation,
            Supplier<? extends Collection<String>> unavailableCountries) {
        this.validation = validation;
        this.unavailableCountries = unavailableCountries;
    }

    public JsonObject evidence(Path path) {
        var document = new FileDocument(path.toFile());
        var validator = DSSUtils.createDocumentValidator(document);
        if (validator == null) {
            throw new IllegalArgumentException("UNSUPPORTED_DOCUMENT");
        }
        validator.setEnableEtsiValidationReport(true);
        var reports = validation.apply(validator);
        var simple = reports.getSimpleReport();
        var tree = MachineInspectionService.forTrustedValidation(new FirstReportReader(simple)).inspect(path);

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
        var pdf = pdfFacts(path, diagnostic);
        if (pdf != null) {
            evidence.add("pdf", pdf);
        }
        tree.add("evidence", evidence);
        return tree;
    }

    private static JsonObject signatureFacts(DiagnosticData diagnostic, SimpleReport simple, String id, String etsi,
            Set<String> unavailable) {
        var facts = new JsonObject();
        facts.addProperty("id", id);
        var signature = diagnostic.getSignatureById(id);
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

    /// PDF facts for a PDF source, or for an ASiC-E's only PDF data object; null otherwise.
    static JsonObject pdfFacts(Path path, DiagnosticData diagnostic) {
        byte[] content;
        try {
            content = Files.readAllBytes(path);
        } catch (IOException exception) {
            throw new java.io.UncheckedIOException(exception);
        }
        if (startsWith(content, "%PDF")) {
            var facts = PdfConversionFacts.read(content);
            facts.add("changesAfterLastSignature", changesAfterLastSignature(diagnostic));
            return facts;
        }
        if (!startsWith(content, "PK")) {
            return null;
        }
        var dataObjects = new ArrayList<String>();
        byte[] onlyPdf = null;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(content))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                var name = entry.getName();
                if (entry.isDirectory() || name.equals("mimetype") || name.startsWith("META-INF/")) {
                    continue;
                }
                dataObjects.add(name);
                var bytes = zip.readAllBytes();
                if (name.toLowerCase(Locale.ROOT).endsWith(".pdf")) {
                    onlyPdf = bytes;
                }
            }
        } catch (IOException exception) {
            return null;
        }
        var facts = onlyPdf != null && dataObjects.size() == 1 ? PdfConversionFacts.read(onlyPdf) : new JsonObject();
        facts.addProperty("asicDataObjectCount", dataObjects.size());
        if (onlyPdf != null && dataObjects.size() == 1) {
            facts.addProperty("asicDataObjectName", dataObjects.getFirst());
            var inner = DSSUtils.createDocumentValidator(new InMemoryDocument(onlyPdf));
            if (inner != null) {
                inner.setCertificateVerifier(new eu.europa.esig.dss.spi.validation.CommonCertificateVerifier());
            }
            facts.addProperty("asicDataObjectSigned", inner != null && !inner.getSignatures().isEmpty());
        }
        facts.add("changesAfterLastSignature", new JsonArray());
        return facts;
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
        var bytes = prefix.getBytes(StandardCharsets.US_ASCII);
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
    /// document is validated once; nested data objects are validated as usual.
    private static final class FirstReportReader implements MachineInspectionService.ValidatorReportReader {
        private SimpleReport first;

        FirstReportReader(SimpleReport first) {
            this.first = first;
        }

        @Override
        public synchronized SimpleReport read(SignedDocumentValidator validator) {
            if (first != null) {
                var report = first;
                first = null;
                return report;
            }
            return SignatureValidator.getInstance().validate(validator).getSimpleReport();
        }
    }
}
