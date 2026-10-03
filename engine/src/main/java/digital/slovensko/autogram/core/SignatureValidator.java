package digital.slovensko.autogram.core;

import java.io.IOException;
import java.io.StringReader;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.concurrent.ExecutorService;

import javax.xml.parsers.ParserConfigurationException;
import javax.xml.transform.TransformerException;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import javax.xml.transform.stream.StreamSource;

import eu.europa.esig.dss.simplereport.SimpleReport;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.xml.sax.InputSource;
import org.xml.sax.SAXException;

import digital.slovensko.autogram.util.XMLUtils;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.DSSException;
import eu.europa.esig.dss.service.crl.OnlineCRLSource;
import eu.europa.esig.dss.service.http.commons.CommonsDataLoader;
import eu.europa.esig.dss.service.http.commons.FileCacheDataLoader;
import eu.europa.esig.dss.service.ocsp.OnlineOCSPSource;
import eu.europa.esig.dss.spi.client.http.DSSCacheFileLoader;
import eu.europa.esig.dss.spi.tsl.TrustedListsCertificateSource;
import eu.europa.esig.dss.spi.x509.CertificateSource;
import eu.europa.esig.dss.spi.x509.KeyStoreCertificateSource;
import eu.europa.esig.dss.tsl.function.OfficialJournalSchemeInformationURI;
import eu.europa.esig.dss.tsl.function.TLPredicateFactory;
import eu.europa.esig.dss.tsl.job.TLValidationJob;
import eu.europa.esig.dss.tsl.source.LOTLSource;
import eu.europa.esig.dss.tsl.sync.SynchronizationStrategy;
import eu.europa.esig.dss.spi.validation.CertificateVerifier;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.validation.SignedDocumentValidator;
import eu.europa.esig.dss.validation.reports.Reports;

import static digital.slovensko.autogram.util.DSSUtils.*;

public class SignatureValidator {
    private static final String LOTL_URL = "https://ec.europa.eu/tools/lotl/eu-lotl.xml";
    private static final String OJ_URL = "https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=uriserv:OJ.C_.2019.276.01.0001.01.ENG";
    private CertificateVerifier verifier;
    private TLValidationJob validationJob;
    private ExecutorService executorService;
    private final SynchronizationStrategy synchronizationStrategy = new CustomSynchronizationStrategy();
    private List<String> configuredCountries = List.of();
    private static Logger logger = LoggerFactory.getLogger(SignatureValidator.class);

    // Singleton
    private static SignatureValidator instance;

    private SignatureValidator() {
    }

    public synchronized static SignatureValidator getInstance() {
        if (instance == null)
            instance = new SignatureValidator();

        return instance;
    }

    public synchronized Reports validate(SignedDocumentValidator docValidator) {
        // Trusted lists load lazily (a visible signature or an explicit validation warms
        // them); without them structural and cryptographic checks still run, only the
        // EU qualification stays undecided instead of throwing on a null verifier.
        if (verifier == null)
            verifier = new CommonCertificateVerifier();
        docValidator.setCertificateVerifier(verifier);

        // TODO: do not print stack trace inside DSS
        return docValidator.validateDocument();
    }

    public synchronized void updateLotl(List<String> tlCountries) {
        initialize(executorService, tlCountries);
    }

    public synchronized void refresh() {
        validationJob.offlineRefresh();
    }

    public synchronized void initialize(ExecutorService executorService, List<String> tlCountries) {
        initialize(executorService, tlCountries, TrustedListCacheLoader.standard(null));
    }

    /**
     * Loads the trusted lists of the given countries through {@code trustedListLoader}.
     * The lists run in parallel on {@code executorService}, so it needs a thread for the
     * caller's wait, one for the LOTL and one per country.
     */
    public synchronized void initialize(ExecutorService executorService, List<String> tlCountries,
            DSSCacheFileLoader trustedListLoader) {
        this.executorService = executorService;
        this.configuredCountries = List.copyOf(tlCountries);

        SimpleDateFormat formatter = new SimpleDateFormat("dd/MM/yyyy HH:mm:ss");
        logger.debug("Initializing signature validator at {}", formatter.format(new Date()));

        validationJob = new TLValidationJob();

        var lotlSource = new LOTLSource();
        lotlSource.setCertificateSource(getJournalCertificateSource());
        lotlSource.setSigningCertificatesAnnouncementPredicate(new OfficialJournalSchemeInformationURI(OJ_URL));
        lotlSource.setUrl(LOTL_URL);
        lotlSource.setPivotSupport(true);
        lotlSource.setTlPredicate(TLPredicateFactory.createEUTLCountryCodePredicate(tlCountries.toArray(new String[0])));

        validationJob.setOfflineDataLoader(trustedListLoader);

        var onlineFileLoader = new FileCacheDataLoader();
        onlineFileLoader.setCacheExpirationTime(0);
        onlineFileLoader.setDataLoader(new CommonsDataLoader());
        validationJob.setOnlineDataLoader(onlineFileLoader);

        var trustedListCertificateSource = new TrustedListsCertificateSource();
        validationJob.setTrustedListCertificateSource(trustedListCertificateSource);
        validationJob.setListOfTrustedListSources(lotlSource);
        validationJob.setSynchronizationStrategy(synchronizationStrategy);
        validationJob.setExecutorService(executorService);
        validationJob.setDebug(false);

        logger.debug("Starting signature validator offline refresh");
        validationJob.offlineRefresh();

        verifier = new CommonCertificateVerifier();
        verifier.setTrustedCertSources(trustedListCertificateSource);
        verifier.setCrlSource(new OnlineCRLSource());
        verifier.setOcspSource(new OnlineOCSPSource());

        logger.debug("Signature validator initialized at {}", formatter.format(new Date()));
    }

    private CertificateSource getJournalCertificateSource() throws AssertionError {
        try {
            var keystore = getClass().getResourceAsStream("lotlKeyStore.p12");
            return new KeyStoreCertificateSource(keystore, "PKCS12", "dss-password".toCharArray());

        } catch (DSSException | NullPointerException e) {
            throw new AssertionError("Cannot load LOTL keystore", e);
        }
    }

    public synchronized ValidationReports getSignatureValidationReport(SigningJob job) {
        var documentValidator = createDocumentValidator(job.getDocument());
        if (documentValidator == null)
            return new ValidationReports(null, job);

        return new ValidationReports(validate(documentValidator), job);
    }

    public static String getSignatureValidationReportHTML(Reports signatureValidationReport) {
        try {
            var document = XMLUtils.getSecureDocumentBuilder().parse(new InputSource(new StringReader(signatureValidationReport.getXmlSimpleReport())));
            var xmlSource = new DOMSource(document);

            var xsltFile = SignatureValidator.class.getResourceAsStream("simple-report-bootstrap4.xslt");
            var xsltSource = new StreamSource(xsltFile);

            var outputTarget = new StreamResult(new StringWriter());
            var transformer = XMLUtils.getSecureTransformerFactory().newTransformer(xsltSource);
            transformer.transform(xmlSource, outputTarget);

            var r = outputTarget.getWriter().toString().trim();

            var templateFile = SignatureValidator.class.getResourceAsStream("simple-report-template.html");
            var templateString = new String(templateFile.readAllBytes(), StandardCharsets.UTF_8);
            return templateString.replace("{{content}}", r);

        } catch (SAXException | IOException | ParserConfigurationException | TransformerException e) {
            return "Error transforming validation report";
        }
    }

    public static ValidationReports getSignatureCheckReport(SigningJob job) {
        var validator = createDocumentValidator(job.getDocument());
        if (validator == null)
            return new ValidationReports(null, job);

        validator.setCertificateVerifier(new CommonCertificateVerifier());
        return new ValidationReports(validator.validateDocument(), job);
    }

    public static SimpleReport getSignedDocumentSimpleReport(DSSDocument document) {
        var validator = createDocumentValidator(document);
        if (validator == null)
            return null;

        validator.setCertificateVerifier(new CommonCertificateVerifier());
        var report = validator.validateDocument().getSimpleReport();
        if (report.getSignatureIdList().size() == 0)
            return null;

        return report;
    }

    public static SignatureLevel getSignedDocumentSignatureLevel(SimpleReport report) {
        if (report == null)
            return null;

        return report.getSignatureFormat(report.getSignatureIdList().get(0));
    }

    /** The configured countries whose trusted list the last load could not bring in. */
    public synchronized List<String> unavailableTrustedListCountries() {
        if (validationJob == null)
            return List.of();

        return TrustedListAvailability.unavailable(configuredCountries,
                TrustedListAvailability.availableTerritories(validationJob.getSummary(), synchronizationStrategy));
    }

    /** True when at least one configured national trusted list came in. */
    public synchronized boolean hasAvailableTrustedList() {
        return validationJob != null && unavailableTrustedListCountries().size() < configuredCountries.size();
    }

    public synchronized boolean areTLsLoaded() {
        // TODO: consider validation turned off as well
        return validationJob.getSummary().getNumberOfProcessedTLs() > 0;
    }
}
