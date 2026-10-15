package digital.slovensko.autogram.core;

import javax.xml.crypto.dsig.CanonicalizationMethod;

import digital.slovensko.autogram.core.eforms.dto.EFormAttributes;
import digital.slovensko.autogram.core.errors.AutogramException;
import digital.slovensko.autogram.core.errors.SigningParametersException;
import digital.slovensko.autogram.core.errors.UnknownEformException;
import digital.slovensko.autogram.util.AsicContainerUtils;
import digital.slovensko.autogram.core.eforms.EFormUtils;
import digital.slovensko.autogram.core.eforms.xdc.XDCValidator;
import digital.slovensko.autogram.core.eforms.dto.XsltParams;
import eu.europa.esig.dss.asic.cades.ASiCWithCAdESSignatureParameters;
import eu.europa.esig.dss.asic.xades.ASiCWithXAdESSignatureParameters;
import eu.europa.esig.dss.cades.CAdESSignatureParameters;
import eu.europa.esig.dss.enumerations.ASiCContainerType;
import eu.europa.esig.dss.enumerations.DigestAlgorithm;
import eu.europa.esig.dss.enumerations.ImageScaling;
import eu.europa.esig.dss.enumerations.MimeTypeEnum;
import eu.europa.esig.dss.enumerations.SignatureForm;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.enumerations.SignaturePackaging;
import eu.europa.esig.dss.enumerations.VisualSignatureRotation;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.pades.PAdESSignatureParameters;
import eu.europa.esig.dss.pades.SignatureFieldParameters;
import eu.europa.esig.dss.pades.SignatureImageParameters;
import eu.europa.esig.dss.spi.x509.tsp.TSPSource;
import eu.europa.esig.dss.xades.XAdESSignatureParameters;

import java.time.Instant;
import java.util.Date;

import static digital.slovensko.autogram.core.errors.SigningParametersException.Error.WRONG_MIME_TYPE;
import static digital.slovensko.autogram.core.errors.SigningParametersException.Error.XSLT_NO_XDC;

public class SigningParameters {
    private final SignatureLevel level;
    private final DigestAlgorithm digestAlgorithm;
    private final ASiCContainerType container;
    private final SignaturePackaging packaging;
    private final boolean en319132;
    private final String infoCanonicalization;
    private final String propertiesCanonicalization;
    private final String keyInfoCanonicalization;
    private final EFormAttributes eFormAttributes;
    private final boolean checkPDFACompliance;
    private final int visualizationWidth;
    private final TSPSource tspSource;
    private VisiblePadesAppearance visiblePadesAppearance;
    private boolean plainRecordXdc;
    private TSPSource contentTimestampSource;
    private boolean extendsExistingContainer;

    private SigningParameters(
            SignatureLevel level, DigestAlgorithm digestAlgorithm, ASiCContainerType container, SignaturePackaging signaturePackaging,
            boolean en319132, String infoCanonicalization, String propertiesCanonicalization, String keyInfoCanonicalization,
            EFormAttributes eFormAttributes, boolean checkPDFACompliance, int preferredPreviewWidth, TSPSource tspSource) {

        this.level = level;
        this.digestAlgorithm = digestAlgorithm;
        this.container = container;
        this.packaging = signaturePackaging;
        this.en319132 = en319132;
        this.infoCanonicalization = infoCanonicalization;
        this.propertiesCanonicalization = propertiesCanonicalization;
        this.keyInfoCanonicalization = keyInfoCanonicalization;
        this.checkPDFACompliance = checkPDFACompliance;
        this.visualizationWidth = preferredPreviewWidth;
        this.tspSource = tspSource;
        this.eFormAttributes = eFormAttributes;
    }

    public static SigningParameters buildParameters(
            SignatureLevel level, DigestAlgorithm digestAlgorithm, ASiCContainerType container, SignaturePackaging packaging,
            boolean en319132, String infoCanonicalization, String propertiesCanonicalization, String keyInfoCanonicalization,
            EFormAttributes eFormAttributes, boolean autoLoadEform, String fsFormId, boolean checkPDFACompliance,
            int preferredPreviewWidth, DSSDocument document, TSPSource tspSource, boolean plainXmlEnabled) throws AutogramException {

        if (level == null)
            throw new SigningParametersException("Nebol zadaný typ podpisu", "Typ/level podpisu je povinný atribút");

        if (document == null)
            throw new SigningParametersException("Dokument je prázdny", "Dokument poskytnutý na podpis je prázdny");

        if (document.getMimeType() == null)
            throw new SigningParametersException("Dokument nemá definovaný MIME type", "Dokument poskytnutý na podpis nemá definovaný MIME type");

        if (digestAlgorithm == null)
            digestAlgorithm = DigestAlgorithm.SHA256;

        var extractedDocument = document;
        if (AutogramMimeType.isAsice(document.getMimeType()))
            extractedDocument = AsicContainerUtils.getOriginalDocument(document);

        if (AutogramMimeType.isXML(extractedDocument.getMimeType()) && XDCValidator.isXDCContent(extractedDocument))
            extractedDocument.setMimeType(AutogramMimeType.XML_DATACONTAINER);

        fsFormId = EFormUtils.translateFsFormId(fsFormId);
        eFormAttributes = EFormAttributes.build(eFormAttributes, autoLoadEform, fsFormId, extractedDocument, propertiesCanonicalization);

        var extractedDocumentMimeType = extractedDocument.getMimeType();

        if (eFormAttributes.containerXmlns() != null && eFormAttributes.containerXmlns().contains("xmldatacontainer")) {
            if (container == null) container = ASiCContainerType.ASiC_E;

            if (packaging == null) packaging = SignaturePackaging.ENVELOPING;
            if (!AutogramMimeType.isXML(extractedDocumentMimeType) && !AutogramMimeType.isXDC(extractedDocumentMimeType))
                throw new SigningParametersException(WRONG_MIME_TYPE);
        } else {
            eFormAttributes = new EFormAttributes(null, null, null, null, null, null, false);
        }

        var isXdcEform = eFormAttributes.containerXmlns() != null
                && eFormAttributes.containerXmlns().contains("xmldatacontainer");

        if ((AutogramMimeType.isXDC(extractedDocumentMimeType) || AutogramMimeType.isXML(extractedDocumentMimeType)) && isXdcEform) {
            XDCValidator.validateXml(
                    eFormAttributes.schema(), eFormAttributes.transformation(), extractedDocument,
                    propertiesCanonicalization, digestAlgorithm, eFormAttributes.embedUsedSchemas());
        }

        if (!AutogramMimeType.isXDC(extractedDocumentMimeType)) {
            // if the document is not an XML resulting in XML Datacontainer, ignore all eForm attributes (mainly transformation)
            if (eFormAttributes.containerXmlns() == null || !eFormAttributes.containerXmlns().contains("xmldatacontainer")) {
                if (eFormAttributes.transformation() != null)
                    throw new SigningParametersException(XSLT_NO_XDC);

                eFormAttributes = new EFormAttributes(null, null, null, null, null, null, false);
            }
        }

        if (!plainXmlEnabled && (AutogramMimeType.isXML(extractedDocumentMimeType) || AutogramMimeType.isXDC(extractedDocumentMimeType)) && (eFormAttributes.transformation() == null))
            throw new UnknownEformException();

        return new SigningParameters(
                level, digestAlgorithm, container, packaging, en319132, infoCanonicalization, propertiesCanonicalization,
                keyInfoCanonicalization, eFormAttributes, checkPDFACompliance, preferredPreviewWidth, tspSource);
    }

    public static SigningParameters buildForPDF(DSSDocument document, boolean checkPDFACompliance, boolean signAsEn319132, TSPSource tspSource) throws AutogramException {
        return buildParameters(
                (tspSource == null) ? SignatureLevel.PAdES_BASELINE_B : SignatureLevel.PAdES_BASELINE_T, DigestAlgorithm.SHA256,
                null, null, signAsEn319132, null, null, null, null, false,
                null, checkPDFACompliance, 640, document, tspSource, true);
    }

    public static SigningParameters buildForASiCWithXAdES(DSSDocument document, boolean checkPDFACompliance, boolean signAsEn319132, TSPSource tspSource, boolean plainXmlEnabled) throws AutogramException {
        return buildParameters(
                (tspSource == null) ? SignatureLevel.XAdES_BASELINE_B : SignatureLevel.XAdES_BASELINE_T, DigestAlgorithm.SHA256,
                ASiCContainerType.ASiC_E, SignaturePackaging.ENVELOPING, signAsEn319132, null, null, null,  null, true,
                EFormUtils.getFsFormIdFromFilename(document.getName()), checkPDFACompliance, 640, document, tspSource, plainXmlEnabled);
    }

    public static SigningParameters buildForASiCWithCAdES(DSSDocument document, boolean checkPDFACompliance, boolean signAsEn319132, TSPSource tspSource, boolean plainXmlEnabled) throws AutogramException {
        return buildParameters(
                (tspSource == null) ? SignatureLevel.CAdES_BASELINE_B : SignatureLevel.CAdES_BASELINE_T, DigestAlgorithm.SHA256,
                ASiCContainerType.ASiC_E, SignaturePackaging.ENVELOPING, signAsEn319132, null, null, null, null, true,
                EFormUtils.getFsFormIdFromFilename(document.getName()), checkPDFACompliance, 640, document, tspSource, plainXmlEnabled);
    }

    /// An XMLDataContainer signed alone into a new ASiC-E, as is: no eForm is resolved, fetched or
    /// validated (the XDC already references its form), and the data object keeps the bare XDC MIME.
    public static SigningParameters buildForPlainRecordXdc(DSSDocument document, SignatureLevel level,
            TSPSource tspSource) throws AutogramException {
        if (document == null || !AutogramMimeType.isXDC(document.getMimeType()))
            throw new SigningParametersException(WRONG_MIME_TYPE);
        if (level != SignatureLevel.XAdES_BASELINE_T && level != SignatureLevel.XAdES_BASELINE_B)
            throw new SigningParametersException("Nesprávny typ podpisu", "Záznam sa podpisuje ako XAdES v ASiC-E");

        var parameters = buildParameters(level, DigestAlgorithm.SHA256, ASiCContainerType.ASiC_E,
                SignaturePackaging.ENVELOPING, false, null, null, null, null, false, null, false, 640, document,
                level == SignatureLevel.XAdES_BASELINE_T ? tspSource : null, true);
        parameters.plainRecordXdc = true;
        return parameters;
    }

    public static SigningParameters buildForExistingASiC(DSSDocument document, SignatureLevel level,
            boolean checkPDFACompliance, boolean signAsEn319132, TSPSource tspSource) throws AutogramException {
        if (document == null)
            throw new SigningParametersException("Dokument je prázdny", "Dokument poskytnutý na podpis je prázdny");
        if (!AutogramMimeType.isAsice(document.getMimeType()))
            throw new SigningParametersException(WRONG_MIME_TYPE);
        if (level != SignatureLevel.XAdES_BASELINE_T && level != SignatureLevel.CAdES_BASELINE_T)
            throw new SigningParametersException("Nesprávny typ podpisu", "Existujúci ASiC vyžaduje XAdES alebo CAdES Baseline T");

        var parameters = new SigningParameters(level, DigestAlgorithm.SHA256, ASiCContainerType.ASiC_E,
                SignaturePackaging.ENVELOPING, signAsEn319132, null, null, null,
                new EFormAttributes(null, null, null, null, null, null, false), checkPDFACompliance, 640, tspSource);
        parameters.extendsExistingContainer = true;
        return parameters;
    }

        public ASiCWithXAdESSignatureParameters getASiCWithXAdESSignatureParameters() {
        var parameters = new ASiCWithXAdESSignatureParameters();

        parameters.aSiC().setContainerType(getContainer());
        parameters.setSignatureLevel(getLevel());
        parameters.setDigestAlgorithm(getDigestAlgorithm());
        parameters.setSigningCertificateDigestMethod(getDigestAlgorithm());
        parameters.setSignedInfoCanonicalizationMethod(getInfoCanonicalization());
        parameters.setSignedPropertiesCanonicalizationMethod(getPropertiesCanonicalization());
        parameters.setKeyInfoCanonicalizationMethod(getKeyInfoCanonicalization());
        parameters.setEn319132(isEn319132());
        parameters.setAddX509SubjectName(true);

        return parameters;
    }

    public XAdESSignatureParameters getXAdESSignatureParameters() {
        var parameters = new XAdESSignatureParameters();

        parameters.setSignatureLevel(getLevel());
        parameters.setDigestAlgorithm(getDigestAlgorithm());
        parameters.setEn319132(isEn319132());
        parameters.setSignedInfoCanonicalizationMethod(getInfoCanonicalization());
        parameters.setSignedPropertiesCanonicalizationMethod(getPropertiesCanonicalization());
        parameters.setSignaturePackaging(getSignaturePackaging());
        parameters.setKeyInfoCanonicalizationMethod(getKeyInfoCanonicalization());
        parameters.setAddX509SubjectName(true);

        return parameters;
    }

    public CAdESSignatureParameters getCAdESSignatureParameters() {
        var parameters = new CAdESSignatureParameters();

        parameters.setSignatureLevel(getLevel());
        parameters.setDigestAlgorithm(getDigestAlgorithm());
        parameters.setSignaturePackaging(SignaturePackaging.ENVELOPING);
        parameters.setEn319122(isEn319132());

        return parameters;
    }

    public PAdESSignatureParameters getPAdESSignatureParameters() {
        var parameters = new PAdESSignatureParameters();

        parameters.setSignatureLevel(getLevel());
        parameters.setDigestAlgorithm(getDigestAlgorithm());
        parameters.setEn319122(isEn319132());
        if (visiblePadesAppearance != null) {
            var field = new SignatureFieldParameters();
            field.setPage(visiblePadesAppearance.page());
            field.setOriginX(visiblePadesAppearance.originX());
            field.setOriginY(visiblePadesAppearance.originY());
            field.setWidth(visiblePadesAppearance.width());
            field.setHeight(visiblePadesAppearance.height());
            field.setRotation(VisualSignatureRotation.NONE);

            var image = new SignatureImageParameters();
            image.setImage(new InMemoryDocument(visiblePadesAppearance.pngBytes(), "visible-signature.png", MimeTypeEnum.PNG));
            image.setFieldParameters(field);
            image.setImageScaling(ImageScaling.STRETCH);
            parameters.setImageParameters(image);
            parameters.bLevel().setSigningDate(Date.from(visiblePadesAppearance.signingTime()));
        }

        return parameters;
    }

    public void setVisiblePadesAppearance(byte[] pngBytes, int page, float originX, float originY, float width,
            float height, Instant signingTime) {
        if (getLevel() != SignatureLevel.PAdES_BASELINE_T) {
            throw new IllegalArgumentException("Visible appearance requires PAdES Baseline T");
        }
        visiblePadesAppearance = new VisiblePadesAppearance(pngBytes, page, originX, originY, width, height, signingTime);
    }

    private record VisiblePadesAppearance(byte[] pngBytes, int page, float originX, float originY, float width,
            float height, Instant signingTime) {
        private VisiblePadesAppearance {
            pngBytes = pngBytes.clone();
        }

        @Override
        public byte[] pngBytes() {
            return pngBytes.clone();
        }
    }

    public ASiCWithCAdESSignatureParameters getASiCWithCAdESSignatureParameters() {
        var parameters = new ASiCWithCAdESSignatureParameters();

        parameters.setSignatureLevel(getLevel());
        parameters.setDigestAlgorithm(getDigestAlgorithm());
        parameters.setEn319122(isEn319132());
        parameters.aSiC().setContainerType(getContainer());

        return parameters;
    }

    public SignatureForm getSignatureType() {
        return level.getSignatureForm();
    }

    public ASiCContainerType getContainer() {
        return container;
    }

    public String getContainerXmlns() {
        return eFormAttributes.containerXmlns();
    }

    public String getSchema() {
        return eFormAttributes.schema();
    }

    public String getTransformation() {
        return eFormAttributes.transformation();
    }

    public SignatureLevel getLevel() {
        return level != null ? level : SignatureLevel.XAdES_BASELINE_B;
    }

    public SignaturePackaging getSignaturePackaging() {
        return packaging != null ? packaging : SignaturePackaging.ENVELOPED;
    }

    public DigestAlgorithm getDigestAlgorithm() {
        return digestAlgorithm != null ? digestAlgorithm : DigestAlgorithm.SHA256;
    }

    public Boolean isEn319132() {
        return en319132;
    }

    public String getInfoCanonicalization() {
        return infoCanonicalization != null ? infoCanonicalization : CanonicalizationMethod.INCLUSIVE;
    }

    public String getPropertiesCanonicalization() {
        return propertiesCanonicalization != null ? propertiesCanonicalization : CanonicalizationMethod.INCLUSIVE;
    }

    public String getKeyInfoCanonicalization() {
        return keyInfoCanonicalization != null ? keyInfoCanonicalization : CanonicalizationMethod.INCLUSIVE;
    }

    public String getIdentifier() {
        return eFormAttributes.identifier();
    }

    public boolean getCheckPDFACompliance() {
        return checkPDFACompliance;
    }

    public int getVisualizationWidth() {
        return (visualizationWidth > 0) ? visualizationWidth : 768;
    }

    public String getXsltDestinationType() {
        return eFormAttributes.xsltParams().destinationType();
    }

    public String getXsdIdentifier() {
        return eFormAttributes.xsdIdentifier();
    }

    /// True only for parameters built by `buildForPlainRecordXdc`.
    public boolean isPlainRecordXdc() {
        return plainRecordXdc;
    }

    public boolean shouldCreateXdc() {
        return eFormAttributes.containerXmlns() != null && eFormAttributes.containerXmlns().contains("xmldatacontainer");
    }

    public XsltParams getXsltParams() {
        return eFormAttributes.xsltParams();
    }

    public TSPSource getTspSource() {
        return tspSource;
    }

    /// A qualified timestamp included in the signed data (§ 23 ods. 1 písm. b) zákona
    /// č. 305/2013 Z. z.): an AllDataObjectsTimeStamp for XAdES in a new ASiC-E, a document
    /// timestamp revision before the signature for PAdES. Independent of the signature
    /// timestamp, so a Baseline B signature can carry one too. Never for CAdES, an existing
    /// container being extended or a record XDC.
    public void setContentTimestampSource(TSPSource source) throws SigningParametersException {
        if (source != null) {
            var supported = switch (getSignatureType()) {
                case PAdES -> true;
                case XAdES -> getContainer() == ASiCContainerType.ASiC_E && !plainRecordXdc
                        && !extendsExistingContainer;
                default -> false;
            };
            if (!supported)
                throw new SigningParametersException("Časová pečiatka údajov nie je podporovaná",
                        "Časová pečiatka údajov sa pridáva iba k novému podpisu PAdES alebo XAdES v ASiC-E");
        }
        contentTimestampSource = source;
    }

    public TSPSource getContentTimestampSource() {
        return contentTimestampSource;
    }

    public boolean shouldEmbedSchemas() {
        return eFormAttributes.embedUsedSchemas();
    }
}
