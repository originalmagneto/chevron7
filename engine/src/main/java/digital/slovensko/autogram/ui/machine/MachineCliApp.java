package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParseException;
import com.google.gson.JsonParser;
import org.apache.commons.cli.CommandLine;

import java.io.IOException;
import java.io.PrintWriter;
import java.io.Reader;
import java.io.StringReader;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class MachineCliApp {
    private MachineCliApp() {
    }

    public static int start(CommandLine commandLine, Reader input, PrintWriter output, PrintWriter error) {
        return start(commandLine, input, output, error, new MachineDriverService(), new MachineInspectionService(),
                new MachineTrustService()::initialize);
    }

    static int start(CommandLine commandLine, Reader input, PrintWriter output, PrintWriter error,
            MachineDriverService driverService) {
        return start(commandLine, input, output, error, driverService, new MachineInspectionService(),
                new MachineTrustService()::initialize);
    }

    static int start(CommandLine commandLine, Reader input, PrintWriter output, PrintWriter error,
            MachineDriverService driverService, MachineInspectionService inspectionService, Runnable trustInitializer) {
        return start(commandLine, input, output, error, driverService, inspectionService, trustInitializer,
                MachineSigningService::new);
    }

    static int start(CommandLine commandLine, Reader input, PrintWriter output, PrintWriter error,
            MachineDriverService driverService, MachineInspectionService inspectionService, Runnable trustInitializer,
            SigningServiceFactory signingServiceFactory) {
        var writer = new MachineEventWriter(output);
        var errorMapper = new MachineErrorMapper();
        try {
            MachineRequestValidator.validateCommandLine(commandLine);
        } catch (MachineProtocolException exception) {
            return fail(writer, "unknown", errorMapper, exception);
        }

        String rawRequest;
        try {
            rawRequest = readRequest(input);
        } catch (IOException exception) {
            return fail(writer, "unknown", errorMapper, new MachineProtocolException("PROTOCOL_INVALID_REQUEST", exception));
        }

        try {
            var request = new MachineProtocolCodec().decodeRequest(new StringReader(rawRequest));
            MachineRequestValidator.validate(commandLine, request);
            return dispatch(writer, request, driverService, inspectionService, trustInitializer, signingServiceFactory);
        } catch (MachineProtocolException exception) {
            var mappedException = hasUnsupportedProtocolVersion(rawRequest)
                    ? new MachineProtocolException("PROTOCOL_UNSUPPORTED_VERSION", exception)
                    : exception;
            return fail(writer, requestId(rawRequest), errorMapper, mappedException);
        } catch (Exception exception) {
            return fail(writer, requestId(rawRequest), errorMapper, exception);
        }
    }

    private static int dispatch(MachineEventWriter writer, MachineRequest request, MachineDriverService driverService,
            MachineInspectionService inspectionService, Runnable trustInitializer, SigningServiceFactory signingServiceFactory) {
        return switch (request.operation()) {
            case CAPABILITIES -> dispatchCapabilities(writer, request, driverService);
            case DRIVERS -> dispatchDrivers(writer, request, driverService);
            case CERTIFICATES -> dispatchCertificates(writer, request, driverService);
            case INSPECT -> dispatchInspection(writer, request, inspectionService);
            case SIGN -> dispatchSigning(writer, request, inspectionService, trustInitializer, signingServiceFactory);
        };
    }

    private static int dispatchCapabilities(MachineEventWriter writer, MachineRequest request, MachineDriverService driverService) {
        requireEmptyPayload(request.payload());
        writer.write("session.started", request.requestId(), null, new JsonObject());
        return complete(writer, request.requestId(), driverService.capabilities());
    }

    private static int dispatchDrivers(MachineEventWriter writer, MachineRequest request, MachineDriverService driverService) {
        requireEmptyPayload(request.payload());
        var payload = driverService.drivers();
        writer.write("session.started", request.requestId(), null, new JsonObject());
        writer.write("driver.detected", request.requestId(), null, payload);
        return complete(writer, request.requestId(), new JsonObject());
    }

    private static int dispatchCertificates(MachineEventWriter writer, MachineRequest request, MachineDriverService driverService) {
        var driver = requiredString(request.payload(), "driver");
        var pin = requiredString(request.payload(), "pin").toCharArray();
        try {
            writer.write("session.started", request.requestId(), null, new JsonObject());
            var payload = driverService.certificates(driver, pin);
            writer.write("certificates.available", request.requestId(), null, payload);
            return complete(writer, request.requestId(), new JsonObject());
        } finally {
            java.util.Arrays.fill(pin, '\0');
        }
    }

    private static int dispatchInspection(MachineEventWriter writer, MachineRequest request,
            MachineInspectionService inspectionService) {
        var inspection = requiredInspectionRequest(request.payload());
        writer.write("session.started", request.requestId(), null, new JsonObject());
        for (var file : inspection.files()) {
            inspectFile(writer, request.requestId(), inspectionService, file);
        }
        return complete(writer, request.requestId(), new JsonObject());
    }

    private static int dispatchSigning(MachineEventWriter writer, MachineRequest request,
            MachineInspectionService inspectionService, Runnable trustInitializer, SigningServiceFactory signingServiceFactory) {
        var signRequest = requiredSignRequest(request.payload());
        try {
            MachineRequestValidator.validateSign(signRequest);
            var failureCode = signingServiceFactory.create(writer, inspectionService, trustInitializer)
                    .sign(request.requestId(), signRequest);
            return failureCode == null ? MachineErrorMapper.COMPLETED
                    : new MachineErrorMapper().exitCode(new MachineProtocolException(failureCode));
        } finally {
            Arrays.fill(signRequest.pin(), '\0');
        }
    }

    private static void inspectFile(MachineEventWriter writer, String requestId, MachineInspectionService inspectionService,
            MachineFile file) {
        try {
            var source = java.nio.file.Path.of(file.source());
            writer.write("inspection.completed", requestId, file.id(), inspectionService.inspect(source));
        } catch (Exception exception) {
            var payload = new JsonObject();
            payload.addProperty("code", "INSPECTION_FAILED");
            writer.write("file.failed", requestId, file.id(), payload);
        }
    }

    private static int complete(MachineEventWriter writer, String requestId, JsonObject payload) {
        writer.writeTerminal("session.completed", requestId, payload);
        return MachineErrorMapper.COMPLETED;
    }

    private static void requireEmptyPayload(JsonObject payload) {
        if (!payload.isEmpty()) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
    }

    private static String requiredString(JsonObject payload, String field) {
        if (payload.size() != 2
                || !payload.has(field)
                || !payload.has("driver")
                || !payload.has("pin")
                || !isNonBlankString(payload.get(field))) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
        return payload.get(field).getAsString();
    }

    private static InspectRequest requiredInspectionRequest(JsonObject payload) {
        if (payload.size() != 1 || !payload.has("files") || !payload.get("files").isJsonArray()
                || payload.getAsJsonArray("files").isEmpty()) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
        var files = new ArrayList<MachineFile>();
        for (var element : payload.getAsJsonArray("files")) {
            if (!element.isJsonObject()) {
                throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
            }
            var file = element.getAsJsonObject();
            if (file.size() != 3 || !file.has("id") || !file.has("source") || !file.has("target")
                    || !isNonBlankString(file.get("id")) || !isNonBlankString(file.get("source"))
                    || !isNonBlankString(file.get("target"))) {
                throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
            }
            var source = file.get("source").getAsString();
            var target = file.get("target").getAsString();
            try {
                java.nio.file.Path.of(source);
                java.nio.file.Path.of(target);
            } catch (java.nio.file.InvalidPathException exception) {
                throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST", exception);
            }
            files.add(new MachineFile(file.get("id").getAsString(), source, target));
        }
        return new InspectRequest(List.copyOf(files));
    }

    static SignRequest requiredSignRequest(JsonObject payload) {
        if (payload.size() != 6 || !payload.has("driver") || !payload.has("certificateSerial") || !payload.has("pin")
                || !payload.has("signatureLevel") || !payload.has("timestamp") || !payload.has("files")
                || !isNonBlankString(payload.get("driver")) || !isNonBlankString(payload.get("certificateSerial"))
                || !isNonBlankString(payload.get("pin")) || !isNonBlankString(payload.get("signatureLevel"))
                || !payload.get("timestamp").isJsonObject()) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
        var pin = payload.get("pin").getAsString().toCharArray();
        QualifiedTimestampRequest timestamp = null;
        try {
            timestamp = requiredTimestamp(payload.getAsJsonObject("timestamp"));
            var files = requiredSignFiles(payload.get("files"));
            return new SignRequest(payload.get("driver").getAsString(), payload.get("certificateSerial").getAsString(),
                    pin, payload.get("signatureLevel").getAsString(), timestamp, files);
        } catch (Throwable exception) {
            Arrays.fill(pin, '\0');
            if (timestamp != null) {
                timestamp.clearAuthentication();
            }
            throw exception;
        }
    }

    private static List<MachineFile> requiredSignFiles(JsonElement filesElement) {
        if (filesElement == null || !filesElement.isJsonArray() || filesElement.getAsJsonArray().isEmpty()) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
        var files = new ArrayList<MachineFile>();
        for (var element : filesElement.getAsJsonArray()) {
            if (!element.isJsonObject()) {
                throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
            }
            var file = element.getAsJsonObject();
            var hasAttachments = file.has("attachments");
            if (file.size() != (hasAttachments ? 4 : 3) || !file.has("id") || !file.has("source") || !file.has("target")
                    || !isNonBlankString(file.get("id")) || !isNonBlankString(file.get("source"))
                    || !isNonBlankString(file.get("target"))) {
                throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
            }
            var attachments = new ArrayList<String>();
            if (hasAttachments) {
                var value = file.get("attachments");
                if (!value.isJsonArray() || value.getAsJsonArray().isEmpty() || value.getAsJsonArray().size() > 8) {
                    throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
                }
                for (var attachment : value.getAsJsonArray()) {
                    if (!isNonBlankString(attachment)) {
                        throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
                    }
                    attachments.add(attachment.getAsString());
                }
            }
            var source = file.get("source").getAsString();
            var target = file.get("target").getAsString();
            try {
                java.nio.file.Path.of(source);
                java.nio.file.Path.of(target);
                for (var attachment : attachments) {
                    java.nio.file.Path.of(attachment);
                }
            } catch (java.nio.file.InvalidPathException exception) {
                throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST", exception);
            }
            files.add(new MachineFile(file.get("id").getAsString(), source, target, null, attachments));
        }
        return List.copyOf(files);
    }

    private static QualifiedTimestampRequest requiredTimestamp(JsonObject timestamp) {
        var optionalFields = (timestamp.has("authentication") ? 1 : 0) + (timestamp.has("content") ? 1 : 0);
        if (timestamp.size() != 2 + optionalFields || !timestamp.has("required") || !timestamp.has("servers")
                || !timestamp.get("required").isJsonPrimitive()
                || !timestamp.getAsJsonPrimitive("required").isBoolean()
                || !timestamp.get("servers").isJsonArray()
                || timestamp.has("content") && (!timestamp.get("content").isJsonPrimitive()
                        || !timestamp.getAsJsonPrimitive("content").isBoolean())) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
        var servers = new ArrayList<String>();
        for (var server : timestamp.getAsJsonArray("servers")) {
            if (!isNonBlankString(server)) {
                throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
            }
            servers.add(server.getAsString());
        }
        var authentication = timestamp.has("authentication")
                ? requiredTimestampAuthentication(timestamp.get("authentication")) : null;
        return new QualifiedTimestampRequest(timestamp.get("required").getAsBoolean(), List.copyOf(servers), authentication,
                timestamp.has("content") && timestamp.get("content").getAsBoolean());
    }

    private static TimestampAuthentication requiredTimestampAuthentication(JsonElement value) {
        if (value == null || !value.isJsonObject()) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
        var authentication = value.getAsJsonObject();
        if (!isNonBlankString(authentication.get("type"))) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        }
        return switch (authentication.get("type").getAsString()) {
            case "basic" -> {
                if (authentication.size() != 3 || !isNonBlankString(authentication.get("username"))
                        || !isNonBlankString(authentication.get("password"))) {
                    throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
                }
                yield new TimestampAuthentication("basic", authentication.get("username").getAsString(),
                        authentication.get("password").getAsString().toCharArray());
            }
            case "bearer" -> {
                if (authentication.size() != 2 || !isNonBlankString(authentication.get("token"))) {
                    throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
                }
                yield new TimestampAuthentication("bearer", null, authentication.get("token").getAsString().toCharArray());
            }
            default -> throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
        };
    }

    private static boolean isNonBlankString(JsonElement element) {
        return element != null
                && element.isJsonPrimitive()
                && element.getAsJsonPrimitive().isString()
                && !element.getAsString().isBlank();
    }

    private static String readRequest(Reader input) throws IOException {
        var request = new StringBuilder();
        var buffer = new char[4096];
        int count;
        while ((count = input.read(buffer)) != -1) {
            request.append(buffer, 0, count);
        }
        return request.toString();
    }

    private static int fail(MachineEventWriter writer, String sessionId, MachineErrorMapper errorMapper,
            Throwable exception) {
        var error = errorMapper.map(exception);
        writer.writeTerminal("session.failed", sessionId, error.toPayload());
        return errorMapper.exitCode(exception);
    }

    private static boolean hasUnsupportedProtocolVersion(String rawRequest) {
        try {
            JsonElement element = JsonParser.parseString(rawRequest);
            if (!element.isJsonObject()) {
                return false;
            }
            var version = element.getAsJsonObject().get("protocolVersion");
            return version != null
                    && version.isJsonPrimitive()
                    && version.getAsJsonPrimitive().isNumber()
                    && version.getAsBigDecimal().compareTo(java.math.BigDecimal.valueOf(MachineProtocolCodec.VERSION)) != 0;
        } catch (JsonParseException exception) {
            return false;
        }
    }

    private static String requestId(String rawRequest) {
        try {
            JsonElement element = JsonParser.parseString(rawRequest);
            if (!element.isJsonObject()) {
                return "unknown";
            }
            var requestId = element.getAsJsonObject().get("requestId");
            return requestId != null && requestId.isJsonPrimitive() && requestId.getAsJsonPrimitive().isString()
                    ? requestId.getAsString()
                    : "unknown";
        } catch (JsonParseException exception) {
            return "unknown";
        }
    }

    @FunctionalInterface
    interface SigningServiceFactory {
        MachineSigningService create(MachineEventWriter writer, MachineInspectionService inspectionService,
                Runnable trustInitializer);
    }
}
