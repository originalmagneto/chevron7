package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonObject;
import digital.slovensko.autogram.core.DefaultDriverDetector;
import digital.slovensko.autogram.core.DriverDetector;
import digital.slovensko.autogram.core.PasswordManager;
import digital.slovensko.autogram.core.SigningJob;
import digital.slovensko.autogram.core.SigningKey;
import digital.slovensko.autogram.core.SigningParameters;
import digital.slovensko.autogram.core.errors.PINIncorrectException;
import digital.slovensko.autogram.drivers.TokenDriver;
import digital.slovensko.autogram.ui.machine.v2.MachineV2RequestValidator;
import digital.slovensko.autogram.ui.machine.v2.VisibleSignatureAppearance;
import digital.slovensko.autogram.ui.cli.CliKeySelector;
import digital.slovensko.autogram.util.DSSUtils;
import eu.europa.esig.dss.asic.cades.validation.ASiCContainerWithCAdESValidator;
import eu.europa.esig.dss.asic.xades.validation.ASiCContainerWithXAdESValidator;
import eu.europa.esig.dss.enumerations.MimeTypeEnum;
import eu.europa.esig.dss.enumerations.ASiCContainerType;
import eu.europa.esig.dss.enumerations.DigestAlgorithm;
import eu.europa.esig.dss.enumerations.SignatureForm;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.enumerations.SignaturePackaging;
import eu.europa.esig.dss.enumerations.MimeType;
import digital.slovensko.autogram.core.AutogramMimeType;
import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.token.AbstractKeyStoreTokenConnection;
import eu.europa.esig.dss.token.DSSPrivateKeyEntry;
import eu.europa.esig.dss.service.http.commons.HostConnection;
import eu.europa.esig.dss.service.http.commons.TimestampDataLoader;
import eu.europa.esig.dss.service.http.commons.UserCredentials;
import org.apache.hc.client5.http.impl.classic.HttpClientBuilder;
import org.apache.hc.core5.http.message.BasicHeader;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.net.URI;
import java.util.Arrays;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.Map;
import java.util.LinkedHashMap;
import java.util.function.BiFunction;
import java.util.function.Function;

public final class MachineSigningService {
    /**
     * Certificate serial meaning "the signing key on this token". The eID signing slot
     * holds one qualified key, and reading its certificates first would cost the
     * person an extra BOK entry.
     */
    public static final String SIGNING_KEY_ON_TOKEN = "*";

    private final MachineEventWriter writer;
    private final Function<SignRequest, SigningSession> sessionFactory;
    private final OutputValidator outputValidator;
    private final Runnable trustInitializer;
    private final MachineSigningFileSystem fileSystem;

    public MachineSigningService(MachineEventWriter writer, MachineInspectionService inspectionService,
            Runnable trustInitializer) {
        this(writer, new DefaultSessionFactory(), new PdfOutputValidator(inspectionService), trustInitializer,
                MacNativeFileSystem.createForCurrentPlatform());
    }

    MachineSigningService(MachineEventWriter writer, Function<SignRequest, SigningSession> sessionFactory,
            OutputValidator outputValidator) {
        this(writer, sessionFactory, outputValidator, () -> { }, MacNativeFileSystem.createForCurrentPlatform());
    }

    MachineSigningService(MachineEventWriter writer, Function<SignRequest, SigningSession> sessionFactory,
            OutputValidator outputValidator, Runnable trustInitializer) {
        this(writer, sessionFactory, outputValidator, trustInitializer, MacNativeFileSystem.createForCurrentPlatform());
    }

    MachineSigningService(MachineEventWriter writer, Function<SignRequest, SigningSession> sessionFactory,
            OutputValidator outputValidator, Runnable trustInitializer, MachineSigningFileSystem fileSystem) {
        this.writer = Objects.requireNonNull(writer);
        this.sessionFactory = Objects.requireNonNull(sessionFactory);
        this.outputValidator = Objects.requireNonNull(outputValidator);
        this.trustInitializer = Objects.requireNonNull(trustInitializer);
        this.fileSystem = Objects.requireNonNull(fileSystem);
    }

    public String sign(String requestId, SignRequest request) {
        writer.write("session.started", requestId, null, new JsonObject());
        String sessionFailureCode = null;
        List<PreparedFile> preparedFiles = List.of();
        int processedFiles = 0;
        var requestFiles = request != null && request.files() != null ? request.files() : List.<MachineFile>of();
        var requestPin = request != null ? request.pin() : null;
        try {
            var validatedRequest = MachineRequestValidator.validateSign(request);
            // A state-portal eForm travels as plain XML; without its attributes such a
            // source stays refused below, so ordinary file signing never changes shape.
            preparedFiles = prepare(requestId, validatedRequest.files(), validatedRequest.request().eform() != null);
            if (preparedFiles.stream().anyMatch(PreparedFile::hasVisibleAppearance)) {
                trustInitializer.run();
            }
            for (var prepared : preparedFiles) {
                prepared.setPreviousSignatureIds(previousSignatureIds(prepared));
            }
            try (var session = sessionFactory.apply(request)) {
                for (; processedFiles < preparedFiles.size(); processedFiles++) {
                    signFile(requestId, session, preparedFiles.get(processedFiles), validatedRequest.request().signatureLevel());
                }
            }
        } catch (Throwable exception) {
            sessionFailureCode = failureCode(exception, "SIGNING_UNAVAILABLE");
            int firstUnprocessed = Math.min(processedFiles, requestFiles.size());
            failUnprocessedFiles(requestId, requestFiles.subList(firstUnprocessed, requestFiles.size()), sessionFailureCode);
        } finally {
            if (!closePreparedFiles(preparedFiles)) {
                sessionFailureCode = "OUTPUT_CLEANUP_FAILED";
            }
            if (requestPin != null) {
                Arrays.fill(requestPin, '\0');
            }
        }

        if (sessionFailureCode != null) {
            var error = new MachineErrorMapper().map(new MachineProtocolException(sessionFailureCode));
            writer.writeTerminal("session.failed", requestId, error.toPayload());
        } else {
            writer.writeTerminal("session.completed", requestId, new JsonObject());
        }
        return sessionFailureCode;
    }

    public String signV2(String requestId, JsonObject payload) {
        var request = MachineV2RequestValidator.validateSign(payload);
        var pin = request.pin();
        try {
            var files = request.files().stream().map(file -> new MachineFile(file.id(), file.source(), file.target(),
                    file.appearance())).toList();
            var authentication = request.timestamp().authentication();
            return sign(requestId, new SignRequest(request.driver(), request.certificateSerial(), pin,
                    request.signatureLevel(), new QualifiedTimestampRequest(true, request.timestamp().servers(),
                    authentication == null ? null : new TimestampAuthentication(authentication.type(), authentication.username(),
                            authentication.secret())), files, request.eform()));
        } finally {
            Arrays.fill(pin, '\0');
            request.clearPin();
        }
    }

    private List<PreparedFile> prepare(String requestId, List<ValidatedMachineFile> files, boolean eformXmlAllowed) {
        var prepared = new ArrayList<PreparedFile>();
        try {
            for (var file : files) {
                progress(requestId, file.file(), "preparing");
                prepared.add(PreparedFile.prepare(file, fileSystem, eformXmlAllowed));
            }
            return List.copyOf(prepared);
        } catch (Throwable exception) {
            if (!closePreparedFiles(prepared)) {
                throw new MachineProtocolException("OUTPUT_CLEANUP_FAILED", exception);
            }
            throw rethrow(exception);
        }
    }

    private void signFile(String requestId, SigningSession session, PreparedFile prepared, String requestedLevel) {
        var file = prepared.file();
        writer.write("file.signingStarted", requestId, file.id(), new JsonObject());
        try {
            var completed = new boolean[] { false };
            var previousSignatureIds = prepared.previousSignatureIds();
            progress(requestId, file, "signing");
            session.sign(prepared.signingInput(), () -> completed[0] = true);
            if (!completed[0]) {
                throw new MachineProtocolException("OUTPUT_VALIDATION_FAILED");
            }
            progress(requestId, file, "validating");
            var signedContent = prepared.readSignedContent();
            var validationFailure = wrapsSignedSource(prepared, previousSignatureIds, signedContent)
                    ? wrappedSourceValidationFailure(signedContent, prepared.sourceContent(),
                            prepared.hasVisibleAppearance(), requestedLevel)
                    : outputValidationFailure(signedContent, previousSignatureIds,
                            prepared.hasVisibleAppearance(), requestedLevel);
            if (validationFailure != null) {
                throw new MachineProtocolException(validationFailure);
            }
            progress(requestId, file, "saving");
            prepared.publish();
            writer.write("file.completed", requestId, file.id(), new JsonObject());
        } catch (Throwable exception) {
            var code = failureCode(exception, "SIGNING_FAILED");
            if (!prepared.cleanup()) {
                code = "OUTPUT_CLEANUP_FAILED";
            }
            writer.write("file.failed", requestId, file.id(), failure(code));
        }
    }

    private void progress(String requestId, MachineFile file, String phase) {
        var payload = new JsonObject();
        payload.addProperty("phase", phase);
        writer.write("file.progress", requestId, file.id(), payload);
    }

    private void failUnprocessedFiles(String requestId, List<MachineFile> files, String code) {
        for (var file : files) {
            var fileId = file == null ? null : file.id();
            writer.write("file.signingStarted", requestId, fileId, new JsonObject());
            writer.write("file.failed", requestId, fileId, failure(code));
        }
    }

    private Set<String> signatureIds(byte[] content) {
        try {
            return outputValidator.signatureIds(content);
        } catch (Throwable exception) {
            throw new MachineProtocolException("OUTPUT_VALIDATION_FAILED", exception);
        }
    }

    private Set<String> previousSignatureIds(PreparedFile prepared) {
        if (isPlainSource(prepared.file().source(), prepared.sourceContent())) {
            // Plain text and images carry no DSS signatures, and DSS validation
            // knows PDF/XML/ASiC/CMS only: inspecting them would fail the
            // preflight, so their previous set is empty by construction. The
            // prepare gate above already confirmed the plain source.
            return Set.of();
        }
        return signatureIds(prepared.sourceContent());
    }

    private static boolean isPlainSource(String source, byte[] content) {
        return hasPlainExtension(source) || isPngImage(source, content);
    }

    private String outputValidationFailure(byte[] content, Set<String> previousSignatureIds,
            boolean visibleAppearance, String requestedLevel) {
        try {
            return outputValidator.validationFailure(content, previousSignatureIds, visibleAppearance, requestedLevel);
        } catch (Throwable exception) {
            throw new MachineProtocolException("OUTPUT_VALIDATION_FAILED", exception);
        }
    }

    /// A signed source that is not a container (a PDF with PAdES signatures) wrapped into a
    /// new ASiC container. The container lists only its own signatures, never those inside
    /// its data objects, so the source's signatures cannot be found among them; they
    /// survive only if the container carries the source unchanged.
    private static boolean wrapsSignedSource(PreparedFile prepared, Set<String> previousSignatureIds,
            byte[] signedContent) {
        return !previousSignatureIds.isEmpty() && !isZip(prepared.sourceContent()) && isZip(signedContent);
    }

    private String wrappedSourceValidationFailure(byte[] content, byte[] source, boolean visibleAppearance,
            String requestedLevel) {
        try {
            return outputValidator.wrappedSourceValidationFailure(content, source, visibleAppearance, requestedLevel);
        } catch (Throwable exception) {
            throw new MachineProtocolException("OUTPUT_VALIDATION_FAILED", exception);
        }
    }

    private static String failureCode(Throwable exception, String fallback) {
        var tokenCode = MachineErrorMapper.tokenFailureCode(exception);
        if (tokenCode != null) {
            return tokenCode;
        }
        for (var cause = exception; cause != null && cause.getCause() != cause; cause = cause.getCause()) {
            if (cause instanceof MachineProtocolException protocolException) {
                return switch (protocolException.getMessage()) {
                    case "OUTPUT_CLEANUP_FAILED", "OUTPUT_VALIDATION_FAILED", "TIMESTAMP_QUALIFICATION_FAILED",
                            "TIMESTAMP_FAILED", "OUTPUT_PUBLISH_UNSUPPORTED", "OUTPUT_TARGET_EXISTS", "MACHINE_PLATFORM_UNSUPPORTED",
                            "TRUSTED_LIST_UNAVAILABLE" -> protocolException.getMessage();
                    default -> fallback;
                };
            }
        }
        return fallback;
    }

    private static MachineProtocolException rethrow(Throwable exception) {
        if (exception instanceof RuntimeException runtimeException) {
            throw runtimeException;
        }
        if (exception instanceof Error error) {
            throw error;
        }
        return new MachineProtocolException("SIGNING_UNAVAILABLE", exception);
    }

    private static JsonObject failure(String code) {
        var payload = new JsonObject();
        payload.addProperty("code", code);
        return payload;
    }

    private static boolean closePreparedFiles(List<PreparedFile> preparedFiles) {
        var cleaned = true;
        for (var prepared : preparedFiles) {
            try {
                cleaned &= prepared.cleanup();
            } catch (Throwable exception) {
                cleaned = false;
            }
        }
        return cleaned;
    }

    private static final class PreparedFile {
        private final MachineFile file;
        private final Path target;
        private final MachineSigningFileSystem.RetainedFile source;
        private final MachineSigningFileSystem.RetainedFile staging;
        private final MachineSigningFileSystem.Workspace workspace;
        private final byte[] sourceContent;
        private final List<AttachmentContent> attachments;
        private Set<String> previousSignatureIds;
        private boolean cleaned;

        private PreparedFile(MachineFile file, Path target, MachineSigningFileSystem.RetainedFile source,
                MachineSigningFileSystem.RetainedFile staging, MachineSigningFileSystem.Workspace workspace,
                byte[] sourceContent, List<AttachmentContent> attachments) {
            this.file = file;
            this.target = target;
            this.source = source;
            this.staging = staging;
            this.workspace = workspace;
            this.sourceContent = sourceContent;
            this.attachments = attachments;
        }

        private static PreparedFile prepare(ValidatedMachineFile validated, MachineSigningFileSystem fileSystem,
                boolean eformXmlAllowed)
                throws IOException {
            var file = validated.file();
            MachineSigningFileSystem.RetainedFile source = null;
            MachineSigningFileSystem.Workspace workspace = null;
            try {
                source = fileSystem.openSource(validated.source());
                var sourceContent = source.readAll();
                if (!isSupportedSource(file.source(), sourceContent, eformXmlAllowed)) {
                    throw new IOException("Source is not a supported document");
                }
                var attachments = new ArrayList<AttachmentContent>();
                for (var path : validated.attachments()) {
                    try (var retained = fileSystem.openSource(path)) {
                        var content = retained.readAll();
                        if (isZip(content)) {
                            throw new IOException("An attachment may not be a container");
                        }
                        attachments.add(new AttachmentContent(path.getFileName().toString(), content));
                    }
                }
                if (!attachments.isEmpty() && !hasPdfHeader(sourceContent)) {
                    throw new IOException("Attachments are signed next to a PDF, never into an existing container");
                }
                workspace = fileSystem.createWorkspace(validated.target().getParent());
                var staging = workspace.createStagingFile();
                return new PreparedFile(file, validated.target(), source, staging, workspace, sourceContent,
                        List.copyOf(attachments));
            } catch (Throwable exception) {
                boolean cleaned = true;
                if (workspace != null) {
                    try {
                        cleaned &= workspace.cleanup();
                    } catch (Throwable cleanupFailure) {
                        cleaned = false;
                    }
                }
                if (source != null) {
                    try {
                        source.close();
                    } catch (Throwable cleanupFailure) {
                        cleaned = false;
                    }
                }
                if (!cleaned) {
                    throw new MachineProtocolException("OUTPUT_CLEANUP_FAILED", exception);
                }
                throw rethrow(exception);
            }
        }

        private MachineFile file() {
            return file;
        }

        private void setPreviousSignatureIds(Set<String> value) {
            previousSignatureIds = Set.copyOf(value);
        }

        private Set<String> previousSignatureIds() {
            if (previousSignatureIds == null) {
                throw new MachineProtocolException("OUTPUT_VALIDATION_FAILED");
            }
            return previousSignatureIds;
        }

        private boolean hasVisibleAppearance() {
            return file.visibleAppearance() != null;
        }

        private SigningInput signingInput() {
            return new SigningInput(file, sourceContent.clone(), source, staging, attachments);
        }

        private byte[] sourceContent() {
            return sourceContent.clone();
        }

        private byte[] readSignedContent() throws IOException {
            return staging.readAll();
        }

        private void publish() throws IOException {
            workspace.publish(staging, target.getFileName().toString());
        }

        private boolean cleanup() {
            if (cleaned) {
                return true;
            }
            boolean success = true;
            try {
                source.close();
            } catch (Throwable exception) {
                success = false;
            }
            try {
                success &= workspace.cleanup();
            } catch (Throwable exception) {
                success = false;
            }
            cleaned = success;
            return success;
        }
    }

    /// A further document signed with the source as its own data object of one ASiC-E.
    public record AttachmentContent(String name, byte[] content) {
        public AttachmentContent {
            content = content.clone();
        }
    }

    record SigningInput(MachineFile file, byte[] sourceContent, MachineSigningFileSystem.RetainedFile source,
            MachineSigningFileSystem.RetainedFile staging, List<AttachmentContent> attachments) {
        SigningInput {
            sourceContent = sourceContent.clone();
            attachments = List.copyOf(attachments);
        }

        SigningInput(MachineFile file, byte[] sourceContent, MachineSigningFileSystem.RetainedFile source,
                MachineSigningFileSystem.RetainedFile staging) {
            this(file, sourceContent, source, staging, List.of());
        }

        void writeSignedContent(byte[] content) throws IOException {
            staging.replaceContent(content);
        }
    }

    private static boolean hasPdfHeader(byte[] content) {
        return content.length >= 5 && "%PDF-".equals(new String(content, 0, 5, StandardCharsets.ISO_8859_1));
    }

    private static boolean hasPngHeader(byte[] content) {
        return content.length >= 8 && (content[0] & 0xFF) == 0x89 && content[1] == 0x50
                && content[2] == 0x4E && content[3] == 0x47 && content[4] == 0x0D
                && content[5] == 0x0A && content[6] == 0x1A && content[7] == 0x0A;
    }

    private static boolean hasPlainExtension(String source) {
        return source.toLowerCase(java.util.Locale.ROOT).endsWith(".txt");
    }

    private static boolean isPngImage(String source, byte[] content) {
        return source.toLowerCase(java.util.Locale.ROOT).endsWith(".png") && hasPngHeader(content);
    }

    private static final String XDC_NAMESPACE = "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1";

    /// An `.xdcf` whose root element is an XMLDataContainer: the EZZK conversion record, signed alone.
    static boolean isRecordXdc(String source, byte[] content) {
        if (!source.toLowerCase(java.util.Locale.ROOT).endsWith(".xdcf")) {
            return false;
        }
        try {
            var factory = javax.xml.parsers.DocumentBuilderFactory.newInstance();
            factory.setNamespaceAware(true);
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            factory.setXIncludeAware(false);
            factory.setExpandEntityReferences(false);
            var root = factory.newDocumentBuilder().parse(new java.io.ByteArrayInputStream(content)).getDocumentElement();
            return "XMLDataContainer".equals(root.getLocalName()) && XDC_NAMESPACE.equals(root.getNamespaceURI());
        } catch (Exception exception) {
            return false;
        }
    }

    static boolean isSupportedSource(String source, byte[] content, boolean eformXmlAllowed) {
        return hasPdfHeader(content) || isAsic(source, content) || isRecordXdc(source, content)
                || (eformXmlAllowed && isXmlForm(source, content))
                || hasPlainExtension(source) || isPngImage(source, content);
    }

    /// A state-portal eForm: plain XML the engine wraps into an XMLDataContainer from the
    /// request's schema and transformation when it signs. Only with eForm attributes, so a
    /// mislabeled or broken file still fails here rather than deep in the XDC build.
    private static boolean isXmlForm(String source, byte[] content) {
        if (!source.toLowerCase(java.util.Locale.ROOT).endsWith(".xml")) {
            return false;
        }
        try {
            var factory = javax.xml.parsers.DocumentBuilderFactory.newInstance();
            factory.setNamespaceAware(true);
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            factory.setXIncludeAware(false);
            factory.setExpandEntityReferences(false);
            factory.newDocumentBuilder().parse(new java.io.ByteArrayInputStream(content));
            return true;
        } catch (Exception exception) {
            return false;
        }
    }

    static MimeType detectMimeType(String filename, byte[] content) {
        if (isAsic(filename, content)) {
            return MimeTypeEnum.ASICE;
        }
        var lower = filename.toLowerCase(java.util.Locale.ROOT);
        if (lower.endsWith(".xdcf")) {
            return AutogramMimeType.XML_DATACONTAINER_WITH_CHARSET;
        }
        if (lower.endsWith(".xml")) {
            return MimeTypeEnum.XML;
        }
        if (lower.endsWith(".txt")) {
            return MimeTypeEnum.TEXT;
        }
        if (lower.endsWith(".png")) {
            return MimeTypeEnum.PNG;
        }
        return MimeTypeEnum.PDF;
    }

    private static ASiCContainerType containerTypeFor(SignatureLevel level) {
        return level != null && level.getSignatureForm() == SignatureForm.XAdES ? ASiCContainerType.ASiC_E : null;
    }

    private static SignaturePackaging packagingOf(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        try {
            return SignaturePackaging.valueOf(value);
        } catch (IllegalArgumentException exception) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST", exception);
        }
    }

    private static boolean isZip(byte[] content) {
        return content.length >= 4 && content[0] == 'P' && content[1] == 'K' && content[2] == 3 && content[3] == 4;
    }

    private static boolean isAsic(String name, byte[] content) {
        return name.toLowerCase(java.util.Locale.ROOT).endsWith(".asice")
                && content.length >= 4 && content[0] == 'P' && content[1] == 'K'
                && content[2] == 3 && content[3] == 4;
    }

    private static byte[] readAll(FileChannel input) throws IOException {
        var content = new ByteArrayOutputStream();
        var buffer = java.nio.ByteBuffer.allocate(8192);
        while (input.read(buffer) != -1) {
            buffer.flip();
            content.write(buffer.array(), 0, buffer.remaining());
            buffer.clear();
        }
        return content.toByteArray();
    }

    interface SigningSession extends AutoCloseable {
        void sign(SigningInput input, Runnable completed) throws Exception;

        @Override
        void close();
    }

    @FunctionalInterface
    interface OutputValidator {
        boolean isValid(byte[] content) throws Exception;

        default boolean isValid(byte[] content, Set<String> previousSignatureIds) throws Exception {
            return isValid(content);
        }

        default Set<String> signatureIds(byte[] content) throws Exception {
            return Set.of();
        }

        default String validationFailure(byte[] content, Set<String> previousSignatureIds) throws Exception {
            return isValid(content, previousSignatureIds) ? null : "OUTPUT_VALIDATION_FAILED";
        }

        default String validationFailure(byte[] content, Set<String> previousSignatureIds,
                boolean visibleAppearance) throws Exception {
            return validationFailure(content, previousSignatureIds);
        }

        default String validationFailure(byte[] content, Set<String> previousSignatureIds,
                boolean visibleAppearance, String requestedLevel) throws Exception {
            return validationFailure(content, previousSignatureIds, visibleAppearance);
        }

        /// A signed source wrapped into a new container must come back byte-identical as the
        /// container's signed data object. A validator that cannot prove that refuses.
        default String wrappedSourceValidationFailure(byte[] content, byte[] source, boolean visibleAppearance,
                String requestedLevel) throws Exception {
            return "OUTPUT_VALIDATION_FAILED";
        }
    }

    static final class DefaultSessionFactory implements Function<SignRequest, SigningSession> {
        private final MachineSettings settings;
        private final DriverDetector driverDetector;
        private final BiFunction<MachineSecretUI, MachineSettings, PasswordManager> passwordManagerFactory;

        DefaultSessionFactory() {
            this(new MachineSettings(true));
        }

        DefaultSessionFactory(MachineSettings settings) {
            this(new DefaultDriverDetector(settings), settings, PasswordManager::new);
        }

        DefaultSessionFactory(DriverDetector driverDetector, MachineSettings settings,
                BiFunction<MachineSecretUI, MachineSettings, PasswordManager> passwordManagerFactory) {
            this.driverDetector = driverDetector;
            this.settings = settings;
            this.passwordManagerFactory = passwordManagerFactory;
        }

        @Override
        public SigningSession apply(SignRequest request) {
            var timestampDataLoader = MachineTimestampDataLoader.create(request.timestamp());
            try {
                settings.setSignatureLevel(SignatureLevel.valueOf(request.signatureLevel()));
                settings.setEform(request.eform());
                // Baseline-B carries no timestamp, so no TSA is configured for it.
                if (request.signatureLevel().endsWith("_T")) {
                    settings.setTsaServer(String.join(",", request.timestamp().servers()), timestampDataLoader);
                    settings.setTsaEnabled(true);
                } else {
                    settings.setTsaEnabled(false);
                }
                var driver = driverDetector.getAvailableDrivers().stream()
                        .filter(candidate -> candidate.getShortname().equals(request.driver()))
                        .findFirst()
                        .orElseThrow(() -> new MachineProtocolException("DRIVER_NOT_FOUND"));
                return DefaultSigningSession.open(driver, request, settings, passwordManagerFactory, timestampDataLoader);
            } catch (Throwable exception) {
                timestampDataLoader.clearAuthentication();
                throw exception;
            } finally {
                request.timestamp().clearAuthentication();
            }
        }
    }

    static final class DefaultSigningSession implements SigningSession {
        private final MachineSecretUI secretUi;
        private final PasswordManager passwordManager;
        private final AbstractKeyStoreTokenConnection token;
        private final SigningKey key;
        private final MachineSettings settings;
        private final MachineTimestampDataLoader timestampDataLoader;

        private DefaultSigningSession(MachineSecretUI secretUi, PasswordManager passwordManager,
                AbstractKeyStoreTokenConnection token, SigningKey key, MachineSettings settings,
                MachineTimestampDataLoader timestampDataLoader) {
            this.secretUi = secretUi;
            this.passwordManager = passwordManager;
            this.token = token;
            this.key = key;
            this.settings = settings;
            this.timestampDataLoader = timestampDataLoader;
        }

        static DefaultSigningSession open(TokenDriver driver, SignRequest request, MachineSettings settings,
                BiFunction<MachineSecretUI, MachineSettings, PasswordManager> passwordManagerFactory) {
            return open(driver, request, settings, passwordManagerFactory, new MachineTimestampDataLoader());
        }

        static DefaultSigningSession open(TokenDriver driver, SignRequest request, MachineSettings settings,
                BiFunction<MachineSecretUI, MachineSettings, PasswordManager> passwordManagerFactory,
                MachineTimestampDataLoader timestampDataLoader) {
            var secretUi = new MachineSecretUI(request.pin());
            PasswordManager passwordManager = null;
            AbstractKeyStoreTokenConnection token = null;
            try {
                passwordManager = passwordManagerFactory.apply(secretUi, settings);
                token = driver.createToken(passwordManager, settings);
                var key = selectedKey(token.getKeys(), request.certificateSerial());
                return new DefaultSigningSession(secretUi, passwordManager, token, new SigningKey(token, key), settings,
                        timestampDataLoader);
            } catch (Throwable exception) {
                try {
                    if (token != null) {
                        token.close();
                    }
                } finally {
                    try {
                        if (passwordManager != null) {
                            passwordManager.reset();
                        }
                    } finally {
                        secretUi.close();
                        timestampDataLoader.clearAuthentication();
                    }
                }
                throw exception;
            }
        }

        @Override
        public void sign(SigningInput input, Runnable completed) throws Exception {
            var responder = new MachineFileResponder(input.staging(), completed);
            var job = signingJob(input.sourceContent(), input.file().source(), responder, settings,
                    input.file().visibleAppearance(), input.attachments());
            job.signWithKeyAndRespond(key);
        }

        static SigningJob signingJob(byte[] source, String name, MachineFileResponder responder, MachineSettings settings)
                throws Exception {
            return signingJob(source, name, responder, settings, null);
        }

        static SigningJob signingJob(byte[] source, String name, MachineFileResponder responder, MachineSettings settings,
                VisibleSignatureAppearance.Snapshot appearance) throws Exception {
            return signingJob(source, name, responder, settings, appearance, List.of());
        }

        static SigningJob signingJob(byte[] source, String name, MachineFileResponder responder, MachineSettings settings,
                VisibleSignatureAppearance.Snapshot appearance, List<AttachmentContent> attachments) throws Exception {
            var filename = Path.of(name).getFileName().toString();
            var document = new InMemoryDocument(source, filename, detectMimeType(filename, source));
            var parameters = signingParameters(document, settings);
            if (appearance != null) {
                var field = appearance.appearance();
                parameters.setVisiblePadesAppearance(appearance.pngBytes(), field.page(), field.originX(), field.originY(),
                        field.width(), field.height(), field.signingTime());
            }
            if (attachments.isEmpty()) {
                return SigningJob.buildFromRequest(document, parameters, responder);
            }
            if (parameters.getContainer() != ASiCContainerType.ASiC_E || parameters.getSignatureType() != SignatureForm.XAdES) {
                throw new IOException("Attachments need an ASiC-E XAdES signature");
            }
            // DSS extends an existing container only when it signs a single document; with
            // attachments it would nest the old container inside the new one. A record is signed alone.
            if (document.getMimeType().equals(MimeTypeEnum.ASICE) || isZip(source)
                    || AutogramMimeType.isXDC(document.getMimeType())) {
                throw new IOException("Attachments are signed next to a PDF, never into an existing container");
            }
            var extra = new ArrayList<DSSDocument>();
            for (var attachment : attachments) {
                if (isZip(attachment.content())) {
                    throw new IOException("An attachment may not be a container");
                }
                var mime = attachment.name().toLowerCase(java.util.Locale.ROOT).endsWith(".xdcf")
                        ? AutogramMimeType.XML_DATACONTAINER
                        : detectMimeType(attachment.name(), attachment.content());
                extra.add(new InMemoryDocument(attachment.content(), attachment.name(), mime));
            }
            return SigningJob.buildFromRequest(document, parameters, responder, extra);
        }

        private static SigningParameters signingParameters(InMemoryDocument document, MachineSettings settings) throws Exception {
            var eform = settings.getEform();
            if (eform != null) {
                // Same entry point the HTTP SignEndpoint uses, so XDCBuilder and the
                // eForm resolvers are reused rather than reimplemented here.
                return SigningParameters.buildParameters(
                        settings.getSignatureLevel(),
                        DigestAlgorithm.SHA256,
                        containerTypeFor(settings.getSignatureLevel()),
                        packagingOf(eform.packaging()),
                        false,
                        null,
                        null,
                        null,
                        eform.toAttributes(),
                        eform.autoLoadEform(),
                        eform.fsFormId(),
                        false,
                        0,
                        document,
                        settings.getTspSource(),
                        false);
            }
            if (document.getMimeType().equals(MimeTypeEnum.ASICE)) {
                var validator = DSSUtils.createDocumentValidator(document);
                if (validator instanceof ASiCContainerWithXAdESValidator) {
                    return SigningParameters.buildForExistingASiC(document, SignatureLevel.XAdES_BASELINE_T,
                            false, false, settings.getTspSource());
                }
                if (validator instanceof ASiCContainerWithCAdESValidator) {
                    return SigningParameters.buildForExistingASiC(document, SignatureLevel.CAdES_BASELINE_T,
                            false, false, settings.getTspSource());
                }
                throw new IOException("Unsupported ASiC signature format");
            }
            if (AutogramMimeType.isXDC(document.getMimeType())) {
                if (!isRecordXdc(document.getName(), document.getBytes())) {
                    throw new IOException("Only an XMLDataContainer is signed as a record");
                }
                var level = settings.getSignatureLevel();
                if (level != SignatureLevel.XAdES_BASELINE_T && level != SignatureLevel.XAdES_BASELINE_B) {
                    throw new IOException("A record is signed as XAdES in an ASiC-E");
                }
                // Local route: the XDC already references its form; nothing is fetched or re-wrapped.
                return SigningParameters.buildForPlainRecordXdc(document, level, settings.getTspSource());
            }
            var level = settings.getSignatureLevel();
            if (level == SignatureLevel.XAdES_BASELINE_T) {
                return SigningParameters.buildForASiCWithXAdES(document, false, false,
                        settings.getTspSource(), true);
            }
            if (level == SignatureLevel.XAdES_BASELINE_B) {
                // A portal's ASiC-E envelope around a PDF: the same container as
                // Baseline T, only without the timestamp the portal did not ask for.
                return SigningParameters.buildForASiCWithXAdES(document, false, false, null, true);
            }
            if (AutogramMimeType.isTxt(document.getMimeType()) || document.getMimeType().equals(MimeTypeEnum.PNG)) {
                throw new IOException("Plain text and images are signed as XAdES in an ASiC-E");
            }
            return SigningParameters.buildForPDF(document, false, false, settings.getTspSource());
        }
        @Override
        public void close() {
            try {
                token.close();
            } finally {
                try {
                    passwordManager.reset();
                } finally {
                    try {
                        secretUi.close();
                    } finally {
                        timestampDataLoader.clearAuthentication();
                    }
                }
            }
        }

        static DSSPrivateKeyEntry selectedKey(List<DSSPrivateKeyEntry> keys, String certificateSerial) {
            if (SIGNING_KEY_ON_TOKEN.equals(certificateSerial)) {
                return onlySigningKey(keys);
            }
            var matches = keys.stream().filter(key -> CliKeySelector.serial(key).equals(certificateSerial)).toList();
            if (matches.size() != 1) {
                throw new MachineProtocolException(matches.isEmpty() ? "CERTIFICATE_NOT_FOUND" : "CERTIFICATE_AMBIGUOUS");
            }
            return matches.getFirst();
        }
    }

    /// The only key on the token, or the only one allowed to make non-repudiation
    /// signatures. Never a guess between several signing keys.
    private static DSSPrivateKeyEntry onlySigningKey(List<DSSPrivateKeyEntry> keys) {
        if (keys.size() == 1) {
            return keys.getFirst();
        }
        var signing = keys.stream()
                .filter(key -> key.getCertificate() != null
                        && key.getCertificate().checkKeyUsage(eu.europa.esig.dss.enumerations.KeyUsageBit.NON_REPUDIATION))
                .toList();
        if (signing.size() != 1) {
            throw new MachineProtocolException(signing.isEmpty() ? "CERTIFICATE_NOT_FOUND" : "CERTIFICATE_AMBIGUOUS");
        }
        return signing.getFirst();
    }

    static final class MachineTimestampDataLoader extends TimestampDataLoader {
        private final Map<String, char[]> bearerTokens = new LinkedHashMap<>();
        private final List<char[]> configuredSecrets = new ArrayList<>();

        static MachineTimestampDataLoader create(QualifiedTimestampRequest request) {
            var dataLoader = new MachineTimestampDataLoader();
            var authentication = request.authentication();
            if (authentication == null) {
                return dataLoader;
            }
            for (var server : request.servers()) {
                var endpoint = URI.create(server);
                if ("basic".equals(authentication.type())) {
                    var password = authentication.secret().clone();
                    dataLoader.configuredSecrets.add(password);
                    dataLoader.addAuthentication(new HostConnection(endpoint.getScheme(), endpoint.getHost(), endpoint.getPort(),
                            null, null), new UserCredentials(authentication.username(), password));
                } else {
                    var token = authentication.secret().clone();
                    dataLoader.configuredSecrets.add(token);
                    dataLoader.bearerTokens.put(hostKey(endpoint), token);
                }
            }
            return dataLoader;
        }

        @Override
        protected synchronized HttpClientBuilder getHttpClientBuilder(String url) {
            var builder = super.getHttpClientBuilder(url);
            var token = bearerTokens.get(hostKey(URI.create(url)));
            if (token != null) {
                builder.setDefaultHeaders(List.of(new BasicHeader("Authorization", "Bearer " + String.valueOf(token))));
            }
            return builder;
        }

        void clearAuthentication() {
            for (var secret : configuredSecrets) {
                Arrays.fill(secret, '\0');
            }
            configuredSecrets.clear();
            bearerTokens.clear();
        }

        private static String hostKey(URI endpoint) {
            var port = endpoint.getPort() == -1 ? ("https".equalsIgnoreCase(endpoint.getScheme()) ? 443 : 80)
                    : endpoint.getPort();
            return endpoint.getScheme().toLowerCase(java.util.Locale.ROOT) + "://"
                    + endpoint.getHost().toLowerCase(java.util.Locale.ROOT) + ":" + port;
        }
    }

    static final class PdfOutputValidator implements OutputValidator {
        private final MachineInspectionService inspectionService;

        PdfOutputValidator(MachineInspectionService inspectionService) {
            this.inspectionService = inspectionService;
        }

        boolean isValid(Path target) throws IOException {
            return isValid(readPathNoFollow(target), Set.of());
        }

        Set<String> signatureIds(Path target) throws IOException {
            return signatureIds(readPathNoFollow(target));
        }

        @Override
        public Set<String> signatureIds(byte[] content) throws IOException {
            var signatures = inspectionService.inspect(content).getAsJsonArray("signatures");
            var ids = new HashSet<String>();
            for (var value : signatures) {
                var signature = value.getAsJsonObject();
                var id = string(signature, "id");
                if (id == null) {
                    throw new IOException("Signature has no identity");
                }
                ids.add(id);
            }
            return Set.copyOf(ids);
        }

        boolean isValid(Path target, Set<String> previousSignatureIds) throws IOException {
            return isValid(readPathNoFollow(target), previousSignatureIds);
        }

        @Override
        public boolean isValid(byte[] content, Set<String> previousSignatureIds) {
            return validationFailure(content, previousSignatureIds, false) == null;
        }

        @Override
        public String validationFailure(byte[] content, Set<String> previousSignatureIds) {
            return validationFailure(content, previousSignatureIds, false);
        }

        /**
         * Baseline B carries no timestamp, and only a portal asks for it, so such an
         * output is checked for exactly one new signature of the requested level with
         * intact cryptography. Everything else keeps the qualified Baseline T checks.
         */
        @Override
        public String validationFailure(byte[] content, Set<String> previousSignatureIds,
                boolean visibleAppearance, String requestedLevel) {
            if (visibleAppearance || requestedLevel == null || !requestedLevel.endsWith("_B")) {
                return validationFailure(content, previousSignatureIds, visibleAppearance);
            }
            if (!hasPdfHeaderAndEof(content) && !isAsic("output.asice", content)) {
                return "OUTPUT_VALIDATION_FAILED";
            }
            var signatures = inspectionService.inspect(content).getAsJsonArray("signatures");
            var signatureIds = signatures.asList().stream().map(value -> value.getAsJsonObject())
                    .map(signature -> string(signature, "id")).collect(java.util.stream.Collectors.toSet());
            if (!signatureIds.containsAll(previousSignatureIds)) {
                return "OUTPUT_VALIDATION_FAILED";
            }
            var added = signatures.asList().stream().map(value -> value.getAsJsonObject())
                    .filter(signature -> !previousSignatureIds.contains(string(signature, "id"))).toList();
            if (added.size() != 1 || !requestedLevel.equals(string(added.getFirst(), "format"))
                    || !hasCryptographicIntegrity(added.getFirst())) {
                return "OUTPUT_VALIDATION_FAILED";
            }
            return null;
        }

        @Override
        public String validationFailure(byte[] content, Set<String> previousSignatureIds,
                boolean visibleAppearance) {
            if (visibleAppearance ? !hasPdfHeaderAndEof(content)
                    : !hasPdfHeaderAndEof(content) && !isAsic("output.asice", content)) {
                return "OUTPUT_VALIDATION_FAILED";
            }
            var signatures = inspectionService.inspect(content).getAsJsonArray("signatures");
            var signatureIds = signatures.asList().stream().map(value -> value.getAsJsonObject())
                    .map(signature -> string(signature, "id")).collect(java.util.stream.Collectors.toSet());
            if (!signatureIds.containsAll(previousSignatureIds)) {
                return "OUTPUT_VALIDATION_FAILED";
            }
            var added = signatures.asList().stream().map(value -> value.getAsJsonObject())
                    .filter(signature -> !previousSignatureIds.contains(string(signature, "id"))).toList();
            if (added.size() != 1 || !isQualifiedBaselineT(string(added.getFirst(), "format"))
                    || !hasCryptographicIntegrity(added.getFirst()) || !hasCryptographicallyValidTimestamp(added.getFirst())) {
                return "OUTPUT_VALIDATION_FAILED";
            }
            if (visibleAppearance && !"PAdES_BASELINE_T".equals(string(added.getFirst(), "format"))) {
                return "OUTPUT_VALIDATION_FAILED";
            }
            return !visibleAppearance || hasQualifiedTimestamp(added.getFirst())
                    ? null : "TIMESTAMP_QUALIFICATION_FAILED";
        }

        /**
         * The container holds no signature of its own before this one, so exactly one new
         * signature is required as for any fresh container (Baseline B or qualified Baseline T
         * as requested), and that signature must cover the source byte-identical, which keeps
         * the source's own signatures intact.
         */
        @Override
        public String wrappedSourceValidationFailure(byte[] content, byte[] source, boolean visibleAppearance,
                String requestedLevel) {
            if (visibleAppearance || !isAsic("output.asice", content)) {
                return "OUTPUT_VALIDATION_FAILED";
            }
            var failure = validationFailure(content, Set.of(), false, requestedLevel);
            if (failure != null) {
                return failure;
            }
            return MachineInspectionService.signaturesCoverDocument(content, source) ? null : "OUTPUT_VALIDATION_FAILED";
        }

        @Override
        public boolean isValid(byte[] content) {
            return isValid(content, Set.of());
        }

        private static byte[] readPathNoFollow(Path target) throws IOException {
            try (var input = FileChannel.open(target, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
                return readAll(input);
            }
        }

        private static boolean hasPdfHeaderAndEof(byte[] bytes) {
            if (bytes.length < 10 || !hasPdfHeader(bytes)) {
                return false;
            }
            var content = new String(bytes, StandardCharsets.ISO_8859_1);
            return content.stripTrailing().endsWith("%%EOF");
        }

        private static boolean isQualifiedBaselineT(String format) {
            return "PAdES_BASELINE_T".equals(format) || "XAdES_BASELINE_T".equals(format)
                    || "CAdES_BASELINE_T".equals(format);
        }

        private static boolean hasCryptographicIntegrity(JsonObject value) {
            return booleanField(value, "cryptographicIntegrity", "valid");
        }

        private static boolean hasCryptographicallyValidTimestamp(JsonObject signature) {
            if (!signature.has("timestamps") || !signature.get("timestamps").isJsonArray()) {
                return false;
            }
            return signature.getAsJsonArray("timestamps").asList().stream()
                    .map(value -> value.getAsJsonObject())
                    .anyMatch(PdfOutputValidator::hasCryptographicIntegrity);
        }

        private static boolean hasQualifiedTimestamp(JsonObject signature) {
            return booleanField(signature, "qualifiedTimestampValid", "qualifiedTimestampValid");
        }

        private static boolean booleanField(JsonObject value, String preferredField, String fallbackField) {
            var field = value.has(preferredField) ? value.get(preferredField) : value.get(fallbackField);
            return field != null && field.isJsonPrimitive() && field.getAsJsonPrimitive().isBoolean()
                    && field.getAsBoolean();
        }

        private static String string(JsonObject value, String field) {
            return value.has(field) && !value.get(field).isJsonNull() ? value.get(field).getAsString() : null;
        }
    }
}

record SignRequest(
        String driver,
        String certificateSerial,
        char[] pin,
        String signatureLevel,
        QualifiedTimestampRequest timestamp,
        List<MachineFile> files,
        EFormRequest eform) {

    SignRequest(String driver, String certificateSerial, char[] pin, String signatureLevel,
            QualifiedTimestampRequest timestamp, List<MachineFile> files) {
        this(driver, certificateSerial, pin, signatureLevel, timestamp, files, null);
    }
}

record QualifiedTimestampRequest(boolean required, List<String> servers, TimestampAuthentication authentication) {
    QualifiedTimestampRequest(boolean required, List<String> servers) {
        this(required, servers, null);
    }

    void clearAuthentication() {
        if (authentication != null) {
            authentication.clear();
        }
    }
}

record TimestampAuthentication(String type, String username, char[] secret) {
    void clear() {
        Arrays.fill(secret, '\0');
    }
}
