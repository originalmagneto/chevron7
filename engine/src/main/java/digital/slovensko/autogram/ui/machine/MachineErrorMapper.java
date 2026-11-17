package digital.slovensko.autogram.ui.machine;

import digital.slovensko.autogram.core.errors.FunctionCanceledException;
import digital.slovensko.autogram.core.errors.InitializationFailedException;
import digital.slovensko.autogram.core.errors.PINIncorrectException;
import digital.slovensko.autogram.core.errors.PINLockedException;
import digital.slovensko.autogram.core.errors.SlotIndexOutOfRangeException;
import digital.slovensko.autogram.core.errors.TokenNotRecognizedException;
import digital.slovensko.autogram.core.errors.TokenRemovedException;

import java.util.Set;

public final class MachineErrorMapper {
    static final int COMPLETED = 0;
    static final int REQUEST_ERROR = 64;
    static final int UNAVAILABLE = 69;
    static final int INTERNAL_FAILURE = 70;

    private static final Set<String> REQUEST_CODES = Set.of(
            "OPERATION_MISMATCH", "PROTOCOL_INVALID_EVENT", "PROTOCOL_INVALID_REQUEST",
            "PROTOCOL_UNSUPPORTED_VERSION", "SIGNATURE_LEVEL_REQUIRED", "TIMESTAMP_REQUIRED", "TSA_REQUIRED");
    private static final Set<String> UNAVAILABLE_CODES = Set.of(
            "DRIVER_NOT_FOUND", "DRIVER_UNAVAILABLE", "MACHINE_PLATFORM_UNSUPPORTED",
            "OUTPUT_PUBLISH_UNSUPPORTED", "SIGNING_UNAVAILABLE", "TRUSTED_LIST_UNAVAILABLE",
            "TOKEN_NOT_PRESENT", "TOKEN_NOT_RECOGNIZED");
    private static final Set<String> INTERNAL_CODES = Set.of(
            "OUTPUT_CLEANUP_FAILED", "OUTPUT_TARGET_EXISTS", "OUTPUT_VALIDATION_FAILED", "OUTPUT_WRITE_FAILED",
            "PDFA_INVALID", "SIGNING_FAILED");
    private static final Set<String> PIN_CODES = Set.of("PIN_INCORRECT", "PIN_LOCKED", "OPERATION_CANCELLED");

    public MachineError map(Throwable exception) {
        var tokenCode = tokenFailureCode(exception);
        if (tokenCode != null) {
            return tokenError(tokenCode);
        }
        if (exception instanceof MachineProtocolException protocolException) {
            return protocolError(protocolException.getMessage());
        }
        return internalError(exception);
    }

    public int exitCode(Throwable exception) {
        var code = map(exception).code();
        if (REQUEST_CODES.contains(code) || PIN_CODES.contains(code)) {
            return REQUEST_ERROR;
        }
        if (UNAVAILABLE_CODES.contains(code)) {
            return UNAVAILABLE;
        }
        return INTERNAL_FAILURE;
    }

    /**
     * Walks the cause chain for card and PIN failures raised by the PKCS#11 layer so callers
     * (the Finder Quick Action, the native app) can tell a missing card from an internal fault.
     * Returns null when no token-specific cause is present.
     */
    public static String tokenFailureCode(Throwable exception) {
        for (var cause = exception; cause != null && cause.getCause() != cause; cause = cause.getCause()) {
            if (cause instanceof PINIncorrectException || "CKR_PIN_INCORRECT".equals(cause.getMessage())) {
                return "PIN_INCORRECT";
            }
            if (cause instanceof PINLockedException || "CKR_PIN_LOCKED".equals(cause.getMessage())) {
                return "PIN_LOCKED";
            }
            if (cause instanceof InitializationFailedException || cause instanceof TokenRemovedException
                    || cause instanceof SlotIndexOutOfRangeException
                    || "CKR_TOKEN_NOT_PRESENT".equals(cause.getMessage())
                    || "CKR_SLOT_ID_INVALID".equals(cause.getMessage())) {
                return "TOKEN_NOT_PRESENT";
            }
            if (cause instanceof TokenNotRecognizedException || "CKR_TOKEN_NOT_RECOGNIZED".equals(cause.getMessage())) {
                return "TOKEN_NOT_RECOGNIZED";
            }
            if (cause instanceof FunctionCanceledException || "CKR_FUNCTION_CANCELED".equals(cause.getMessage())) {
                return "OPERATION_CANCELLED";
            }
        }
        return null;
    }

    private static MachineError tokenError(String code) {
        return switch (code) {
            case "PIN_INCORRECT" -> error(code, "machine.error.pinIncorrect", "The supplied PIN was not accepted.", true,
                    "Verify the PIN and retry the request.");
            case "PIN_LOCKED" -> error(code, "machine.error.pinLocked", "The card PIN is locked.", false,
                    "Unlock the PIN with the PUK using the card vendor tool, then retry.");
            case "TOKEN_NOT_PRESENT" -> error(code, "machine.error.tokenNotPresent",
                    "No card was found in the reader for the selected driver.", true,
                    "Insert the card into the reader, wait for the reader light, and retry.");
            case "TOKEN_NOT_RECOGNIZED" -> error(code, "machine.error.tokenNotRecognized",
                    "The card in the reader is not recognized by the selected driver.", true,
                    "Select the driver that matches the card (eID client or I.CA SecureStore) and retry.");
            case "OPERATION_CANCELLED" -> error(code, "machine.error.cancelled",
                    "The card operation was cancelled.", true, "Retry the request.");
            default -> throw new IllegalArgumentException(code);
        };
    }

    private static MachineError protocolError(String code) {
        if (REQUEST_CODES.contains(code)) {
            return error(code, "machine.error.request", "The machine request is invalid.", false,
                    "Correct the request and retry.");
        }
        if (UNAVAILABLE_CODES.contains(code)) {
            return error(code, "machine.error.unavailable", "A required local service is unavailable.", true,
                    "Connect the required token or service and retry.");
        }
        if (INTERNAL_CODES.contains(code)) {
            return error(code, "machine.error.internal", "The machine request could not be completed.", false,
                    "Retry later or inspect the local application logs.");
        }
        return error("INTERNAL_ERROR", "machine.error.internal", "The machine request could not be completed.", false,
                "Retry later or inspect the local application logs.");
    }

    /**
     * Unknown failures keep the generic code but name the exception classes along the cause chain.
     * Class names never carry PINs or paths, so the privacy contract of machine mode holds while a
     * user can still tell a PKCS#11 provider fault from, say, a PDF parsing failure.
     */
    private static MachineError internalError(Throwable exception) {
        var chain = new StringBuilder();
        for (var cause = exception; cause != null && cause.getCause() != cause; cause = cause.getCause()) {
            if (chain.length() > 0) {
                chain.append(" <- ");
            }
            chain.append(cause.getClass().getSimpleName());
        }
        var detail = chain.length() == 0 ? "" : " (" + chain + ")";
        return error("INTERNAL_ERROR", "machine.error.internal",
                "The machine request could not be completed" + detail + ".", false,
                "Retry later or inspect the local application logs.");
    }

    private static MachineError error(String code, String messageKey, String fallbackMessage, boolean retryable,
            String recovery) {
        return new MachineError(code, messageKey, fallbackMessage, retryable, recovery);
    }
}
