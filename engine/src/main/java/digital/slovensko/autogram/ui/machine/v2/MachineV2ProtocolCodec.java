package digital.slovensko.autogram.ui.machine.v2;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParseException;
import com.google.gson.JsonParser;
import digital.slovensko.autogram.ui.machine.MachineProtocolException;

import java.util.Set;

public final class MachineV2ProtocolCodec {
    public static final int VERSION = 2;

    private static final Set<String> REQUEST_FIELDS = Set.of("protocolVersion", "requestId", "operation", "payload");
    private static final Set<String> EVENT_FIELDS = Set.of("protocolVersion", "requestId", "type", "emittedAt", "fileId", "payload");

    private final Gson gson = new GsonBuilder().disableHtmlEscaping().create();

    public MachineV2Request decodeRequest(String line) {
        try {
            var element = JsonParser.parseString(line);
            if (!element.isJsonObject()) {
                throw invalidRequest();
            }
            var request = element.getAsJsonObject();
            if (request.keySet().stream().anyMatch(field -> !REQUEST_FIELDS.contains(field))
                    || !isVersionTwo(request.get("protocolVersion"))
                    || !isNonBlankString(request.get("requestId"))
                    || !isString(request.get("operation"))
                    || !isObject(request.get("payload"))) {
                throw invalidRequest();
            }
            var operation = MachineV2Operation.parse(request.get("operation").getAsString());
            return new MachineV2Request(request.get("requestId").getAsString(), operation, request.getAsJsonObject("payload"));
        } catch (JsonParseException exception) {
            throw invalidRequest(exception);
        }
    }

    public String encodeEvent(MachineV2Event event) {
        if (event == null || event.protocolVersion() != VERSION || !isNonBlank(event.requestId())
                || !isNonBlank(event.type()) || event.payload() == null) {
            throw new MachineProtocolException("PROTOCOL_INVALID_EVENT");
        }
        var element = gson.toJsonTree(event);
        if (!element.isJsonObject() || element.getAsJsonObject().keySet().stream().anyMatch(field -> !EVENT_FIELDS.contains(field))) {
            throw new MachineProtocolException("PROTOCOL_INVALID_EVENT");
        }
        return gson.toJson(event);
    }

    static String requestId(String line) {
        try {
            JsonElement element = JsonParser.parseString(line);
            if (!element.isJsonObject()) {
                return "unknown";
            }
            var requestId = element.getAsJsonObject().get("requestId");
            return isNonBlankString(requestId) ? requestId.getAsString() : "unknown";
        } catch (JsonParseException exception) {
            return "unknown";
        }
    }

    private static MachineProtocolException invalidRequest() {
        return new MachineProtocolException("PROTOCOL_INVALID_REQUEST");
    }

    private static MachineProtocolException invalidRequest(Throwable cause) {
        return new MachineProtocolException("PROTOCOL_INVALID_REQUEST", cause);
    }

    private static boolean isVersionTwo(JsonElement value) {
        return value != null && value.isJsonPrimitive() && value.getAsJsonPrimitive().isNumber()
                && value.getAsBigDecimal().compareTo(java.math.BigDecimal.valueOf(VERSION)) == 0;
    }

    private static boolean isNonBlankString(JsonElement value) {
        return isString(value) && isNonBlank(value.getAsString());
    }

    private static boolean isString(JsonElement value) {
        return value != null && value.isJsonPrimitive() && value.getAsJsonPrimitive().isString();
    }

    private static boolean isObject(JsonElement value) {
        return value != null && value.isJsonObject();
    }

    private static boolean isNonBlank(String value) {
        return value != null && !value.isBlank();
    }
}

record MachineV2Request(String requestId, MachineV2Operation operation, JsonObject payload) {
}

record MachineV2Event(int protocolVersion, String requestId, String type, String emittedAt, String fileId,
        JsonObject payload) {
}

enum MachineV2Operation {
    CAPABILITIES,
    INSPECT,
    PREVIEW,
    CERTIFICATES,
    SIGN,
    TIMESTAMP,
    VALIDATE,
    EVIDENCE;

    static MachineV2Operation parse(String value) {
        try {
            return valueOf(value);
        } catch (IllegalArgumentException exception) {
            throw new MachineProtocolException("PROTOCOL_INVALID_REQUEST", exception);
        }
    }
}
