package digital.slovensko.autogram.ui.machine.v2;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import digital.slovensko.autogram.ui.machine.EFormRequest;
import digital.slovensko.autogram.ui.machine.MachineProtocolException;

import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

public final class MachineV2RequestValidator {
    private static final java.util.Set<String> EFORM_FIELDS = java.util.Set.of(
            "containerXmlns", "schema", "transformation", "identifier", "schemaIdentifier",
            "transformationIdentifier", "transformationLanguage", "transformationMediaDestinationTypeDescription",
            "transformationTargetEnvironment", "embedUsedSchemas", "autoLoadEform", "fsFormId", "packaging");

    private MachineV2RequestValidator() {
    }

    public static ValidatedSignRequest validateSign(JsonObject payload) {
        if (payload == null || (payload.size() != 6 && payload.size() != 7) || !string(payload, "driver") || !string(payload, "certificateSerial")
                || !string(payload, "pin") || !string(payload, "signatureLevel") || !payload.has("timestamp")
                || !payload.get("timestamp").isJsonObject() || !payload.has("files") || !payload.get("files").isJsonArray()
                || (payload.size() == 7 && !payload.has("eform"))) {
            throw invalid();
        }
        var signatureLevel = payload.get("signatureLevel").getAsString();
        validateTimestamp(payload.getAsJsonObject("timestamp"), signatureLevel);
        var files = new ArrayList<ValidatedSignFile>();
        for (var value : payload.getAsJsonArray("files")) {
            if (!value.isJsonObject()) {
                throw invalid();
            }
            var file = value.getAsJsonObject();
            if ((file.size() != 3 && file.size() != 4) || !string(file, "id") || !string(file, "source")
                    || !string(file, "target")) {
                throw invalid();
            }
            VisibleSignatureAppearance.Snapshot appearance = null;
            if (file.has("visibleAppearance")) {
                if (!signatureLevel.startsWith("PAdES_BASELINE_") || !isPdf(strictPath(file.get("source").getAsString()))) {
                    throw invalid();
                }
                appearance = visibleAppearance(file.get("visibleAppearance")).snapshot();
            }
            files.add(new ValidatedSignFile(file.get("id").getAsString(), file.get("source").getAsString(),
                    file.get("target").getAsString(), appearance));
        }
        if (files.isEmpty()) {
            throw invalid();
        }
        return new ValidatedSignRequest(payload.get("driver").getAsString(), payload.get("certificateSerial").getAsString(),
                payload.get("pin").getAsString().toCharArray(), signatureLevel,
                timestamp(payload.getAsJsonObject("timestamp")), List.copyOf(files),
                payload.has("eform") ? eform(payload.get("eform")) : null);
    }

    private static EFormRequest eform(JsonElement value) {
        if (value == null || !value.isJsonObject()) {
            throw invalid();
        }
        var eform = value.getAsJsonObject();
        for (var field : eform.keySet()) {
            if (!EFORM_FIELDS.contains(field)) {
                throw invalid();
            }
        }
        return new EFormRequest(
                optionalString(eform, "containerXmlns"),
                optionalString(eform, "schema"),
                optionalString(eform, "transformation"),
                optionalString(eform, "identifier"),
                optionalString(eform, "schemaIdentifier"),
                optionalString(eform, "transformationIdentifier"),
                optionalString(eform, "transformationLanguage"),
                optionalString(eform, "transformationMediaDestinationTypeDescription"),
                optionalString(eform, "transformationTargetEnvironment"),
                optionalBoolean(eform, "embedUsedSchemas"),
                optionalBoolean(eform, "autoLoadEform"),
                optionalString(eform, "fsFormId"),
                optionalString(eform, "packaging"));
    }

    private static String optionalString(JsonObject object, String field) {
        if (!object.has(field) || object.get(field).isJsonNull()) {
            return null;
        }
        if (!string(object, field)) {
            throw invalid();
        }
        return object.get(field).getAsString();
    }

    private static boolean optionalBoolean(JsonObject object, String field) {
        if (!object.has(field) || object.get(field).isJsonNull()) {
            return false;
        }
        var value = object.get(field);
        if (!value.isJsonPrimitive() || !value.getAsJsonPrimitive().isBoolean()) {
            throw invalid();
        }
        return value.getAsBoolean();
    }

    private static VisibleSignatureAppearance visibleAppearance(JsonElement value) {
        if (value == null || !value.isJsonObject()) {
            throw invalid();
        }
        var appearance = value.getAsJsonObject();
        if (appearance.size() != 7 || !string(appearance, "renderedPngPath") || !integer(appearance, "page")
                || !number(appearance, "originX") || !number(appearance, "originY") || !number(appearance, "width")
                || !number(appearance, "height") || !string(appearance, "signingTime")) {
            throw invalid();
        }
        try {
            return new VisibleSignatureAppearance(appearance.get("renderedPngPath").getAsString(),
                    appearance.get("page").getAsInt(), appearance.get("originX").getAsFloat(),
                    appearance.get("originY").getAsFloat(), appearance.get("width").getAsFloat(),
                    appearance.get("height").getAsFloat(), Instant.parse(appearance.get("signingTime").getAsString()));
        } catch (RuntimeException exception) {
            throw invalid(exception);
        }
    }

    private static Timestamp timestamp(JsonObject value) {
        var servers = new ArrayList<String>();
        for (var server : value.getAsJsonArray("servers")) {
            servers.add(server.getAsString());
        }
        return new Timestamp(List.copyOf(servers), authentication(value));
    }

    private static void validateTimestamp(JsonObject value, String signatureLevel) {
        if ((value.size() != 2 && value.size() != 3) || !value.has("required") || !value.get("required").isJsonPrimitive()
                || !value.has("servers") || !value.get("servers").isJsonArray()) {
            throw invalid();
        }
        // Baseline B carries no timestamp, so it names no authority.
        if (!signatureLevel.endsWith("_T")) {
            if (value.get("required").getAsBoolean()
                    || !value.getAsJsonArray("servers").isEmpty()) {
                throw invalid();
            }
            return;
        }
        if (!value.get("required").getAsBoolean() || value.getAsJsonArray("servers").isEmpty()) {
            throw invalid();
        }
        for (var server : value.getAsJsonArray("servers")) {
            if (!server.isJsonPrimitive() || !server.getAsJsonPrimitive().isString() || server.getAsString().isBlank()) {
                throw invalid();
            }
        }
        if (value.has("authentication")) {
            authentication(value);
        }
    }

    private static Authentication authentication(JsonObject timestamp) {
        if (!timestamp.has("authentication")) {
            return null;
        }
        var authentication = timestamp.get("authentication");
        if (!authentication.isJsonObject()) {
            throw invalid();
        }
        var value = authentication.getAsJsonObject();
        if (!string(value, "type")) {
            throw invalid();
        }
        return switch (value.get("type").getAsString()) {
            case "basic" -> {
                if (value.size() != 3 || !string(value, "username") || !string(value, "password")) {
                    throw invalid();
                }
                yield new Authentication("basic", value.get("username").getAsString(),
                        value.get("password").getAsString().toCharArray());
            }
            case "bearer" -> {
                if (value.size() != 2 || !string(value, "token")) {
                    throw invalid();
                }
                yield new Authentication("bearer", null, value.get("token").getAsString().toCharArray());
            }
            default -> throw invalid();
        };
    }

    private static boolean isPdf(Path path) {
        try {
            if (!java.nio.file.Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)
                    || !path.toRealPath(LinkOption.NOFOLLOW_LINKS).equals(path)) {
                return false;
            }
            var header = ByteBuffer.allocate(5);
            try (var channel = FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
                return channel.read(header) == 5 && java.util.Arrays.equals(header.array(), "%PDF-".getBytes(java.nio.charset.StandardCharsets.ISO_8859_1));
            }
        } catch (Exception exception) {
            return false;
        }
    }

    private static Path strictPath(String value) {
        try {
            var path = Path.of(value);
            if (!path.isAbsolute() || !path.equals(path.normalize()) || path.getNameCount() == 0) {
                throw invalid();
            }
            return path;
        } catch (RuntimeException exception) {
            if (exception instanceof MachineProtocolException protocolException) {
                throw protocolException;
            }
            throw invalid(exception);
        }
    }

    private static boolean string(JsonObject object, String field) {
        return object.has(field) && object.get(field).isJsonPrimitive() && object.get(field).getAsJsonPrimitive().isString()
                && !object.get(field).getAsString().isBlank();
    }

    private static boolean integer(JsonObject object, String field) {
        return object.has(field) && object.get(field).isJsonPrimitive() && object.get(field).getAsJsonPrimitive().isNumber()
                && object.get(field).getAsBigDecimal().stripTrailingZeros().scale() <= 0;
    }

    private static boolean number(JsonObject object, String field) {
        return object.has(field) && object.get(field).isJsonPrimitive() && object.get(field).getAsJsonPrimitive().isNumber();
    }

    private static MachineProtocolException invalid() {
        return new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
    }

    private static MachineProtocolException invalid(Throwable cause) {
        return new MachineProtocolException("PROTOCOL_INVALID_REQUEST", cause);
    }

    public record ValidatedSignRequest(String driver, String certificateSerial, char[] pin, String signatureLevel,
            Timestamp timestamp, List<ValidatedSignFile> files, EFormRequest eform) {
        public ValidatedSignRequest {
            pin = pin.clone();
        }

        @Override
        public char[] pin() {
            return pin.clone();
        }

        public void clearPin() {
            java.util.Arrays.fill(pin, '\0');
            if (timestamp.authentication() != null) {
                timestamp.authentication().clear();
            }
        }
    }

    public record ValidatedSignFile(String id, String source, String target, VisibleSignatureAppearance.Snapshot appearance) {
    }

    public record Timestamp(List<String> servers, Authentication authentication) {
    }

    public record Authentication(String type, String username, char[] secret) {
        public Authentication {
            secret = secret.clone();
        }

        @Override
        public char[] secret() {
            return secret.clone();
        }

        void clear() {
            java.util.Arrays.fill(secret, '\0');
        }
    }
}
