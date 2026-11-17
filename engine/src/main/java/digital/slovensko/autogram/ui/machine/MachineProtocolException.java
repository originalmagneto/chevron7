package digital.slovensko.autogram.ui.machine;

import java.util.List;

public final class MachineProtocolException extends RuntimeException {
    private final String country;
    private final List<String> details;

    public MachineProtocolException(String message) {
        this(message, (String) null);
    }

    public MachineProtocolException(String message, Throwable cause) {
        super(message, cause);
        this.country = null;
        this.details = List.of();
    }

    /** A failure tied to one country, such as a national trusted list that did not load. */
    public MachineProtocolException(String message, String country) {
        super(message);
        this.country = country;
        this.details = List.of();
    }

    private MachineProtocolException(String message, List<String> details) {
        super(message);
        this.country = null;
        this.details = List.copyOf(details);
    }

    /**
     * A failure the caller can explain only with the reasons behind it, such as the veraPDF
     * rules a document breaks (PDFA_INVALID). The reasons describe the document, never a path
     * or a secret.
     */
    static MachineProtocolException withDetails(String code, List<String> details) {
        return new MachineProtocolException(code, details == null ? List.of() : details);
    }

    /**
     * Output validators report a failure as its code, or as {@code CODE:CC} when it is
     * tied to a country (TRUSTED_LIST_UNAVAILABLE:BE).
     */
    static MachineProtocolException fromFailure(String failure) {
        var separator = failure.indexOf(':');
        return separator < 0 ? new MachineProtocolException(failure)
                : new MachineProtocolException(failure.substring(0, separator), failure.substring(separator + 1));
    }

    public String country() {
        return country;
    }

    public List<String> details() {
        return details;
    }
}
