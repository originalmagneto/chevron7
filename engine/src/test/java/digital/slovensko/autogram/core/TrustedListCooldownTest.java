package digital.slovensko.autogram.core;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

class TrustedListCooldownTest {
    private static final String URL = "https://tsl.example.test/tsl-be.xml";
    private static final Instant NOW = Instant.parse("2026-10-02T12:00:00Z");

    @Test
    void aFailedUrlCoolsDownForFiveMinutes() {
        var clock = new MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);

        cooldown.recordFailure(URL);

        assertEquals(Optional.of(Duration.ofMinutes(5)), cooldown.remaining(URL));
        clock.advance(Duration.ofMinutes(4).plusSeconds(59));
        assertEquals(Optional.of(Duration.ofSeconds(1)), cooldown.remaining(URL));
        clock.advance(Duration.ofSeconds(1));
        assertFalse(cooldown.isCoolingDown(URL));
    }

    @Test
    void aSuccessClearsTheEntry() {
        var cooldown = new TrustedListCooldown(new MutableClock(NOW));
        cooldown.recordFailure(URL);

        cooldown.recordSuccess(URL);

        assertFalse(cooldown.isCoolingDown(URL));
    }

    @Test
    void aNewerFailureStartsTheWindowAgain() {
        var clock = new MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);
        cooldown.recordFailure(URL);
        clock.advance(Duration.ofMinutes(4));

        cooldown.recordFailure(URL);
        clock.advance(Duration.ofMinutes(4));

        assertEquals(Optional.of(Duration.ofMinutes(1)), cooldown.remaining(URL));
    }

    @Test
    void eachUrlCoolsDownOnItsOwn() {
        var cooldown = new TrustedListCooldown(new MutableClock(NOW));

        cooldown.recordFailure(URL);

        assertTrue(cooldown.isCoolingDown(URL));
        assertFalse(cooldown.isCoolingDown("https://tsl.example.test/tsl-cz.xml"));
    }

    @Test
    void everyLoadInTheProcessSharesOneInstance() {
        assertSame(TrustedListCooldown.shared(), TrustedListCooldown.shared());
    }

    /** A clock the test moves forward by hand, so no test waits out the window. */
    static final class MutableClock extends Clock {
        private volatile Instant now;

        MutableClock(Instant now) {
            this.now = now;
        }

        void advance(Duration duration) {
            now = now.plus(duration);
        }

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return now;
        }
    }
}
