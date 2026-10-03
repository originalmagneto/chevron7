package digital.slovensko.autogram.core;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Remembers trusted list URLs whose download just failed, so the next loads skip the
 * network for {@link #COOLDOWN} and go straight to the last good copy.
 *
 * <p>Every trusted list load builds a new {@link TrustedListCacheLoader}, so the production
 * instance ({@link #shared()}) lives for the whole engine process: while one national server
 * is down (tsl.belgium.be, 2026-10-02), a long-lived session would otherwise wait for that
 * server again on every visible signature. The downloads run in parallel, so the state is a
 * concurrent map; the clock is injectable for tests.
 */
public final class TrustedListCooldown {
    /** How long a URL whose download failed is not asked again. */
    public static final Duration COOLDOWN = Duration.ofMinutes(5);

    private static final TrustedListCooldown SHARED = new TrustedListCooldown(Clock.systemUTC(), COOLDOWN);

    private final ConcurrentHashMap<String, Instant> failures = new ConcurrentHashMap<>();
    private final Clock clock;
    private final Duration cooldown;

    public TrustedListCooldown(Clock clock) {
        this(clock, COOLDOWN);
    }

    public TrustedListCooldown(Clock clock, Duration cooldown) {
        this.clock = clock;
        this.cooldown = cooldown;
    }

    /** The cool-down every load in this process shares. */
    public static TrustedListCooldown shared() {
        return SHARED;
    }

    /** How much longer the URL is skipped, or empty when it may be downloaded. */
    public Optional<Duration> remaining(String url) {
        var failedAt = failures.get(url);
        if (failedAt == null) {
            return Optional.empty();
        }
        var remaining = Duration.between(clock.instant(), failedAt.plus(cooldown));
        if (remaining.isNegative() || remaining.isZero()) {
            // Only this exact entry: a newer failure recorded meanwhile stays.
            failures.remove(url, failedAt);
            return Optional.empty();
        }
        return Optional.of(remaining);
    }

    public boolean isCoolingDown(String url) {
        return remaining(url).isPresent();
    }

    public void recordFailure(String url) {
        failures.put(url, clock.instant());
    }

    public void recordSuccess(String url) {
        failures.remove(url);
    }
}
