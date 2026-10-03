package digital.slovensko.autogram.ui.machine;

import org.apache.commons.cli.CommandLine;

import java.io.IOException;
import java.net.URI;
import java.net.URISyntaxException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

public final class MachineRequestValidator {
    private static final Set<String> SUPPORTED_SIGNATURE_LEVELS = Set.of(
            "PAdES_BASELINE_T", "XAdES_BASELINE_T", "PAdES_BASELINE_B", "XAdES_BASELINE_B");
    /// Extensions of ASiC containers. With attachments DSS builds a new container, so an existing
    /// one would end up nested inside it instead of being extended.
    private static final Set<String> CONTAINER_EXTENSIONS = Set.of(".asice", ".asics", ".sce", ".scs");
    /// Entry names the container itself uses.
    private static final Set<String> RESERVED_ENTRY_NAMES = Set.of("mimetype", "meta-inf");

    private MachineRequestValidator() {
    }

    public static void validate(CommandLine commandLine, MachineRequest request) {
        validateCommandLine(commandLine);
        if (request.operation() == null) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
        if (parseOperation(commandLine.getOptionValue("operation")) != request.operation()) {
            throw new MachineProtocolException("OPERATION_MISMATCH");
        }
    }

    public static void validateCommandLine(CommandLine commandLine) {
        if (!commandLine.hasOption("machine-readable")
                || !commandLine.hasOption("protocol-version")
                || !commandLine.hasOption("operation")) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
        if (!Integer.toString(MachineProtocolCodec.VERSION).equals(commandLine.getOptionValue("protocol-version"))) {
            throw new MachineProtocolException("PROTOCOL_UNSUPPORTED_VERSION");
        }
    }

    public static ValidatedSignRequest validateSign(SignRequest request) {
        if (request == null || isBlank(request.driver()) || isBlank(request.certificateSerial())
                || request.pin() == null || request.pin().length == 0 || request.files() == null || request.files().isEmpty()) {
            throw invalidRequest();
        }
        // Baseline B is a signature without a timestamp: the person chose to sign without
        // one, or a state portal asked for it (eForms, XAdES around a PDF).
        if (!SUPPORTED_SIGNATURE_LEVELS.contains(request.signatureLevel())) {
            throw new MachineProtocolException("SIGNATURE_LEVEL_REQUIRED");
        }
        if (request.signatureLevel().endsWith("_T")) {
            validateTimestamp(request.timestamp());
        }
        var hasAttachments = request.files().stream().anyMatch(file -> file != null && !file.attachments().isEmpty());
        if (hasAttachments && (request.eform() != null || !request.signatureLevel().startsWith("XAdES_"))) {
            throw invalidRequest();
        }
        return new ValidatedSignRequest(request, validateFiles(request.files()));
    }

    private static void validateTimestamp(QualifiedTimestampRequest timestamp) {
        if (timestamp == null || !timestamp.required()) {
            throw new MachineProtocolException("TIMESTAMP_REQUIRED");
        }
        if (timestamp.servers() == null || timestamp.servers().isEmpty()
                || timestamp.servers().stream().anyMatch(server -> !isSupportedTsaUrl(server))) {
            throw new MachineProtocolException("TSA_REQUIRED");
        }
    }

    private static List<ValidatedMachineFile> validateFiles(List<MachineFile> files) {
        Set<String> targets = new HashSet<>();
        var validated = new ArrayList<ValidatedMachineFile>();
        for (var file : files) {
            if (file == null || isBlank(file.id()) || isBlank(file.source()) || isBlank(file.target())) {
                throw invalidRequest();
            }
            var source = canonicalSource(file.source());
            var target = canonicalTarget(file.target());
            if (source.equals(target) || Files.exists(target, LinkOption.NOFOLLOW_LINKS)
                    || !targets.add(normalizeTarget(target))) {
                throw invalidRequest();
            }
            validated.add(new ValidatedMachineFile(file, source, target, validateAttachments(source, file.attachments())));
        }
        return List.copyOf(validated);
    }

    /// Each attachment becomes a data object of one new ASiC-E next to the source, as a ZIP entry
    /// named after its file. So no document may be a container itself, and the entry names must
    /// be distinct (compared the way the target names are) and not the container's own.
    private static List<Path> validateAttachments(Path source, List<String> values) {
        if (values.isEmpty()) {
            return List.of();
        }
        var entryNames = new HashSet<String>();
        requireDataObjectEntry(source, entryNames);
        var attachments = new ArrayList<Path>();
        for (var value : values) {
            var attachment = canonicalSource(value);
            requireDataObjectEntry(attachment, entryNames);
            attachments.add(attachment);
        }
        return List.copyOf(attachments);
    }

    private static void requireDataObjectEntry(Path document, Set<String> entryNames) {
        var name = normalizeTarget(document.getFileName());
        if (RESERVED_ENTRY_NAMES.contains(name) || CONTAINER_EXTENSIONS.stream().anyMatch(name::endsWith)
                || !entryNames.add(name)) {
            throw invalidRequest();
        }
    }

    private static Path canonicalSource(String value) {
        var path = strictAbsolutePath(value);
        try {
            var canonical = path.toRealPath(LinkOption.NOFOLLOW_LINKS);
            if (!Files.isRegularFile(canonical, LinkOption.NOFOLLOW_LINKS) || !canonical.equals(path)) {
                throw invalidRequest();
            }
            return canonical;
        } catch (IOException exception) {
            throw invalidRequest();
        }
    }

    private static Path canonicalTarget(String value) {
        var path = strictAbsolutePath(value);
        try {
            var parent = path.getParent();
            if (parent == null || !parent.toRealPath().equals(parent)) {
                throw invalidRequest();
            }
            return path;
        } catch (IOException exception) {
            throw invalidRequest();
        }
    }

    private static Path strictAbsolutePath(String value) {
        try {
            var path = Path.of(value);
            if (!path.isAbsolute() || !path.equals(path.normalize()) || path.getNameCount() == 0) {
                throw invalidRequest();
            }
            return path;
        } catch (RuntimeException exception) {
            if (exception instanceof MachineProtocolException protocolException) {
                throw protocolException;
            }
            throw invalidRequest();
        }
    }

    private static String normalizeTarget(Path target) {
        return Normalizer.normalize(target.toString(), Normalizer.Form.NFC).toLowerCase(Locale.ROOT);
    }

    private static boolean isSupportedTsaUrl(String value) {
        if (isBlank(value)) {
            return false;
        }
        try {
            var uri = new URI(value);
            return ("http".equalsIgnoreCase(uri.getScheme()) || "https".equalsIgnoreCase(uri.getScheme()))
                    && uri.getHost() != null;
        } catch (URISyntaxException exception) {
            return false;
        }
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private static MachineProtocolException invalidRequest() {
        return new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
    }

    private static MachineOperation parseOperation(String operation) {
        try {
            return MachineOperation.valueOf(operation.toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException exception) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST", exception);
        }
    }
}

record ValidatedSignRequest(SignRequest request, List<ValidatedMachineFile> files) {
}

record ValidatedMachineFile(MachineFile file, Path source, Path target, List<Path> attachments) {
    ValidatedMachineFile(MachineFile file, Path source, Path target) {
        this(file, source, target, List.of());
    }
}
