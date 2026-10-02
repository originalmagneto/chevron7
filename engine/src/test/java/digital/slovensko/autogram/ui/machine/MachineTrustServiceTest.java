package digital.slovensko.autogram.ui.machine;

import digital.slovensko.autogram.core.TrustedListCacheLoader;
import eu.europa.esig.dss.model.DSSException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/// Loads trusted lists the way DSS's TLValidationJob does (one LOTL task, then one task
/// per national list on the same executor, waiting on a latch), with fake servers and no
/// network: Belgium never answers, Spain trickles for longer than any budget, the rest
/// answer at once.
class MachineTrustServiceTest {
    private static final List<String> COUNTRIES = List.of("BE", "ES", "AT", "CZ", "HU", "NL", "PL", "SK");

    @TempDir
    Path cache;

    @Test
    void aDeadAndASlowServerDoNotKeepTheOtherListsOut() {
        var loaded = ConcurrentHashMap.<String>newKeySet();
        var never = new CountDownLatch(1);
        var loader = new TrustedListCacheLoader(cache, url -> {
            if (url.contains("/BE")) {
                never.await();
            }
            if (url.contains("/ES")) {
                Thread.sleep(20_000);
            }
            return "<tl/>".getBytes(StandardCharsets.UTF_8);
        }, Clock.systemUTC(), TrustedListCacheLoader.FRESH_FOR, TrustedListCacheLoader.MAX_FALLBACK_AGE,
                Duration.ofSeconds(1), Instant.now().plusMillis(1_500));
        var trust = new MachineTrustService(() -> MachineTrustService.trustedListExecutor(COUNTRIES.size()),
                executor -> loadLikeDss(executor, loader, loaded), () -> !loaded.isEmpty(),
                Duration.ofSeconds(6), Duration.ofMillis(10));

        var started = System.nanoTime();
        trust.initialize();

        assertEquals(Set.of("AT", "CZ", "HU", "NL", "PL", "SK"), loaded);
        assertTrue(Duration.ofNanos(System.nanoTime() - started).compareTo(Duration.ofSeconds(5)) < 0);
    }

    @Test
    void theExecutorRunsEveryNationalListAtOnceBesideTheLoadingThread() throws Exception {
        var executor = MachineTrustService.trustedListExecutor(COUNTRIES.size());
        try {
            var running = new CountDownLatch(COUNTRIES.size() + 2);
            var release = new CountDownLatch(1);
            for (var i = 0; i < COUNTRIES.size() + 2; i++) {
                executor.submit(() -> {
                    running.countDown();
                    release.await();
                    return null;
                });
            }

            assertTrue(running.await(2, java.util.concurrent.TimeUnit.SECONDS));
            release.countDown();
        } finally {
            executor.shutdownNow();
        }
    }

    private static void loadLikeDss(ExecutorService executor, TrustedListCacheLoader loader, Set<String> loaded) {
        try {
            var lotl = new CountDownLatch(1);
            executor.submit(() -> {
                try {
                    loader.getDocument("https://lotl.example.test/eu-lotl.xml");
                } finally {
                    lotl.countDown();
                }
            });
            lotl.await();
            var lists = new CountDownLatch(COUNTRIES.size());
            for (var country : COUNTRIES) {
                executor.submit(() -> {
                    try {
                        loader.getDocument("https://tl.example.test/" + country + ".xml");
                        loaded.add(country);
                    } catch (DSSException exception) {
                        // A list that failed stays out, exactly as DSS records a download error.
                    } finally {
                        lists.countDown();
                    }
                });
            }
            lists.await();
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
        }
    }
}
