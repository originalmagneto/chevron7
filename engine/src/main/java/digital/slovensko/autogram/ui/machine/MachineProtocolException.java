package digital.slovensko.autogram.ui.machine;

public final class MachineProtocolException extends RuntimeException {
    private final String country;

    public MachineProtocolException(String message) {
        this(message, (String) null);
    }

    public MachineProtocolException(String message, Throwable cause) {
        super(message, cause);
        this.country = null;
    }

    /** A failure tied to one country, such as a national trusted list that did not load. */
    public MachineProtocolException(String message, String country) {
        super(message);
        this.country = country;
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
}
