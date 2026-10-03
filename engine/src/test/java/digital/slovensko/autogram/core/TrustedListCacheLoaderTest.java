package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.DSSException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class TrustedListCacheLoaderTest {
    private static final String URL = "https://tsl.example.test/tsl-be.xml";
    private static final Instant NOW = Instant.parse("2026-10-02T12:00:00Z");
    private static final Clock CLOCK = Clock.fixed(NOW, ZoneOffset.UTC);

    @TempDir
    Path cache;

    @Test
    void usesAFreshCachedCopyWithoutAskingTheServer() throws Exception {
        cached(URL, "<tl>cached</tl>", Duration.ofHours(1));
        var loader = loader(url -> { throw new AssertionError("a fresh copy needs no download"); });

        assertEquals("<tl>cached</tl>", text(loader.getDocument(URL)));
    }

    @Test
    void downloadsAStaleCopyAgainAndKeepsTheNewOne() throws Exception {
        cached(URL, "<tl>old</tl>", Duration.ofHours(7));
        var loader = loader(url -> xml("<tl>new</tl>"));

        assertEquals("<tl>new</tl>", text(loader.getDocument(URL)));
        assertEquals("<tl>new</tl>", Files.readString(loader.cacheFile(URL)));
    }

    @Test
    void fallsBackToTheLastGoodCopyWhenTheServerFails() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(2));
        var loader = loader(url -> { throw new IOException("connection refused"); });

        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL)));
    }

    @Test
    void refusesALastGoodCopyOlderThanTheMaximumAge() throws Exception {
        cached(URL, "<tl>too old</tl>", Duration.ofDays(8));
        var loader = loader(url -> { throw new IOException("connection refused"); });

        assertThrows(DSSException.class, () -> loader.getDocument(URL));
    }

    @Test
    void refusesWhenTheServerFailsAndNothingIsCached() {
        var loader = loader(url -> { throw new IOException("connection refused"); });

        assertThrows(DSSException.class, () -> loader.getDocument(URL));
    }

    @Test
    void aHangingServerGivesUpAtTheRequestTimeoutAndUsesTheLastGoodCopy() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(1));
        var never = new CountDownLatch(1);
        var loader = new TrustedListCacheLoader(cache, url -> {
            never.await();
            return xml("<tl>never</tl>");
        }, CLOCK, TrustedListCacheLoader.FRESH_FOR, TrustedListCacheLoader.MAX_FALLBACK_AGE,
                Duration.ofMillis(200), null);

        var started = System.nanoTime();
        var document = loader.getDocument(URL);

        assertEquals("<tl>last good</tl>", text(document));
        assertTrue(Duration.ofNanos(System.nanoTime() - started).compareTo(Duration.ofSeconds(2)) < 0);
    }

    @Test
    void theOverallDeadlineCutsAnUnfinishedDownloadShort() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(1));
        var loader = new TrustedListCacheLoader(cache, url -> {
            Thread.sleep(10_000);
            return xml("<tl>slow</tl>");
        }, CLOCK, TrustedListCacheLoader.FRESH_FOR, TrustedListCacheLoader.MAX_FALLBACK_AGE,
                Duration.ofSeconds(30), NOW.plusMillis(200));

        var started = System.nanoTime();
        var document = loader.getDocument(URL);

        assertEquals("<tl>last good</tl>", text(document));
        assertTrue(Duration.ofNanos(System.nanoTime() - started).compareTo(Duration.ofSeconds(2)) < 0);
    }

    @Test
    void anythingButXmlNeverReplacesTheLastGoodCopy() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(1));
        var loader = loader(url -> "502 Bad Gateway".getBytes(StandardCharsets.UTF_8));

        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL)));
        assertEquals("<tl>last good</tl>", Files.readString(loader.cacheFile(URL)));
    }

    @Test
    void aForcedRefreshDownloadsEvenAFreshCopy() throws Exception {
        cached(URL, "<tl>cached</tl>", Duration.ofMinutes(5));
        var downloads = new AtomicInteger();
        var loader = loader(url -> {
            downloads.incrementAndGet();
            return xml("<tl>refreshed</tl>");
        });

        assertEquals("<tl>refreshed</tl>", text(loader.getDocument(URL, true)));
        assertEquals(1, downloads.get());
    }

    @Test
    void readsAndRemovesTheCachedCopy() throws Exception {
        var loader = loader(url -> { throw new IOException("offline"); });
        assertNull(loader.getDocumentFromCache(URL));

        cached(URL, "<tl>cached</tl>", Duration.ofDays(30));

        assertEquals("<tl>cached</tl>", text(loader.getDocumentFromCache(URL)));
        assertTrue(loader.remove(URL));
        assertNull(loader.getDocumentFromCache(URL));
    }

    @Test
    void theCacheDirectoryComesFromTheEnvironmentAndFallsBackToTheTemporaryDirectory() {
        assertEquals(Path.of("/Users/test/Library/Caches/App/Trusted Lists"),
                TrustedListCacheLoader.cacheDirectory(Map.of(TrustedListCacheLoader.CACHE_DIRECTORY_ENVIRONMENT,
                        "/Users/test/Library/Caches/App/Trusted Lists"), "/tmp/x"));
        assertEquals(Path.of("/tmp/x", "autogram-trusted-lists"),
                TrustedListCacheLoader.cacheDirectory(Map.of(TrustedListCacheLoader.CACHE_DIRECTORY_ENVIRONMENT, " "),
                        "/tmp/x"));
        assertEquals(Path.of("/tmp/x", "autogram-trusted-lists"), TrustedListCacheLoader.cacheDirectory(Map.of(), "/tmp/x"));
    }

    @Test
    void createsAMissingCacheDirectoryWhenItStoresAList() throws Exception {
        var nested = cache.resolve("Caches/App/Trusted Lists");
        var loader = new TrustedListCacheLoader(nested, url -> xml("<tl>new</tl>"), CLOCK,
                TrustedListCacheLoader.FRESH_FOR, TrustedListCacheLoader.MAX_FALLBACK_AGE, Duration.ofSeconds(5), null);

        assertEquals("<tl>new</tl>", text(loader.getDocument(URL)));
        assertTrue(Files.isRegularFile(loader.cacheFile(URL)));
    }

    /// www.nccert.pl (PL) and nmhh.hu (HU) chain to Certum Trusted Root CA and Microsec
    /// e-Szigno Root CA 2009, which macOS trusts and the JDK's cacerts does not: with the
    /// JDK roots alone both lists failed with "PKIX path building failed" (2026-10-02).
    @Test
    void downloadsTrustTheMacRootsBesideTheJavaOnes() throws Exception {
        org.junit.jupiter.api.Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        var subjects = new java.util.ArrayList<String>();
        var store = TrustedListCacheLoader.tlsTrustStore();
        for (var aliases = store.aliases(); aliases.hasMoreElements();) {
            var certificate = (java.security.cert.X509Certificate) store.getCertificate(aliases.nextElement());
            subjects.add(certificate.getSubjectX500Principal().getName());
        }

        assertTrue(subjects.stream().anyMatch(subject -> subject.contains("CN=Certum Trusted Root CA")), "Certum");
        assertTrue(subjects.stream().anyMatch(subject -> subject.contains("CN=Microsec e-Szigno Root CA 2009")),
                "Microsec");
        assertTrue(subjects.stream().anyMatch(subject -> subject.contains("CN=DigiCert Global Root G2")), "JDK roots");
    }

    @Test
    void anUnreadableRootSourceLeavesTheOthers() throws Exception {
        var roots = java.security.KeyStore.getInstance("PKCS12");
        roots.load(null, null);
        var certificate = (java.security.cert.X509Certificate) java.security.cert.CertificateFactory
                .getInstance("X.509").generateCertificate(TrustedListCacheLoaderTest.class.getResourceAsStream(
                        "/digital/slovensko/autogram/core/tl-test-root.pem"));
        roots.setCertificateEntry("root", certificate);

        var merged = TrustedListCacheLoader.tlsTrustStore(roots, null);

        assertEquals(1, merged.size());
        assertTrue(merged.isCertificateEntry(merged.aliases().nextElement()));
    }

    /// While tsl.belgium.be was down, every visible signature of a long-lived session waited
    /// for it again (about 14 s warm, 34 s cold); a URL that just failed is now skipped.
    @Test
    void aFailedDownloadIsNotRetriedDuringTheCooldown() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(2));
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);
        var downloads = new AtomicInteger();
        var loader = loader(url -> {
            downloads.incrementAndGet();
            throw new IOException("connection refused");
        }, clock, cooldown, Duration.ofSeconds(5));

        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL)));
        clock.advance(Duration.ofMinutes(4));
        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL)));
        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL, true)));

        assertEquals(1, downloads.get());
        assertTrue(cooldown.isCoolingDown(URL));
    }

    @Test
    void theServerIsAskedAgainOnceTheCooldownEnds() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(2));
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);
        var downloads = new AtomicInteger();
        var loader = loader(url -> {
            if (downloads.incrementAndGet() == 1) {
                throw new IOException("connection refused");
            }
            return xml("<tl>new</tl>");
        }, clock, cooldown, Duration.ofSeconds(5));

        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL)));
        clock.advance(TrustedListCooldown.COOLDOWN);

        assertEquals("<tl>new</tl>", text(loader.getDocument(URL)));
        assertEquals(2, downloads.get());
        assertFalse(cooldown.isCoolingDown(URL));
    }

    /// Skipping with nothing to fall back on would leave the list missing (for the LOTL, every
    /// visible signature failing) for minutes after the network returns, so the server is asked.
    @Test
    void withNothingCachedTheServerIsAskedDespiteTheCooldown() throws Exception {
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var downloads = new AtomicInteger();
        var loader = loader(url -> {
            if (downloads.incrementAndGet() == 1) {
                throw new IOException("connection refused");
            }
            return xml("<tl>back online</tl>");
        }, clock, new TrustedListCooldown(clock), Duration.ofSeconds(5));

        assertThrows(DSSException.class, () -> loader.getDocument(URL));
        clock.advance(Duration.ofMinutes(1));
        assertEquals("<tl>back online</tl>", text(loader.getDocument(URL)));
        assertEquals(2, downloads.get());
    }

    @Test
    void aCopyOlderThanTheFallbackAgeDoesNotTriggerTheSkip() throws Exception {
        cached(URL, "<tl>too old</tl>", Duration.ofDays(30));
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var downloads = new AtomicInteger();
        var loader = loader(url -> {
            downloads.incrementAndGet();
            throw new IOException("connection refused");
        }, clock, new TrustedListCooldown(clock), Duration.ofSeconds(5));

        assertThrows(DSSException.class, () -> loader.getDocument(URL));
        assertThrows(DSSException.class, () -> loader.getDocument(URL));
        assertEquals(2, downloads.get());
    }

    @Test
    void anAnswerThatIsNotXmlStartsTheCooldown() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(1));
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);
        var loader = loader(url -> "502 Bad Gateway".getBytes(StandardCharsets.UTF_8), clock, cooldown,
                Duration.ofSeconds(5));

        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL)));
        assertTrue(cooldown.isCoolingDown(URL));
    }

    @Test
    void aHangingServerStartsTheCooldown() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(1));
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);
        var never = new CountDownLatch(1);
        var loader = loader(url -> {
            never.await();
            return xml("<tl>never</tl>");
        }, clock, cooldown, Duration.ofMillis(200));

        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL)));
        assertTrue(cooldown.isCoolingDown(URL));
    }

    @Test
    void aDownloadFinishingAfterTheCallerGaveUpClearsTheCooldown() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(1));
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);
        var release = new CountDownLatch(1);
        var loader = loader(url -> {
            release.await();
            return xml("<tl>late</tl>");
        }, clock, cooldown, Duration.ofMillis(200));

        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL)));
        assertTrue(cooldown.isCoolingDown(URL));
        release.countDown();

        var giveUp = System.nanoTime() + Duration.ofSeconds(5).toNanos();
        while (cooldown.isCoolingDown(URL) && System.nanoTime() < giveUp) {
            Thread.onSpinWait();
        }
        assertFalse(cooldown.isCoolingDown(URL));
        assertEquals("<tl>late</tl>", Files.readString(loader.cacheFile(URL)));
    }

    /// MachineTrustService shuts its pool down once enough lists are in, which interrupts a
    /// caller still waiting for a slow list (tsl.digital.gob.es, about 115 s). The download
    /// must go on and store its copy, or that list never reaches the cache.
    @Test
    void aDownloadWhoseCallerIsInterruptedStillStoresItsCopy() throws Exception {
        var started = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        var loader = loader(url -> {
            started.countDown();
            release.await();
            return xml("<tl>slow</tl>");
        }, CLOCK, new TrustedListCooldown(CLOCK), Duration.ofSeconds(30));
        var caller = new Thread(() -> {
            try {
                loader.getDocument(URL);
            } catch (RuntimeException expected) {
                // Interrupted: no list for this load.
            }
        });

        caller.start();
        started.await();
        caller.interrupt();
        caller.join(5_000);
        release.countDown();

        var file = loader.cacheFile(URL);
        var giveUp = System.nanoTime() + Duration.ofSeconds(5).toNanos();
        while (!Files.exists(file) && System.nanoTime() < giveUp) {
            Thread.onSpinWait();
        }
        assertFalse(caller.isAlive());
        assertEquals("<tl>slow</tl>", Files.readString(file));
    }

    @Test
    void runningOutOfTheSharedDeadlineBeforeAskingStartsNoCooldown() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(1));
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);
        var loader = new TrustedListCacheLoader(cache, url -> { throw new AssertionError("no time left to ask"); },
                clock, TrustedListCacheLoader.FRESH_FOR, TrustedListCacheLoader.MAX_FALLBACK_AGE,
                Duration.ofSeconds(5), NOW, cooldown);

        assertEquals("<tl>last good</tl>", text(loader.getDocument(URL)));
        assertFalse(cooldown.isCoolingDown(URL));
    }

    /// Every load builds a new loader, so the cool-down must outlive it.
    @Test
    void aLaterLoaderSharingTheCooldownSkipsAUrlAnEarlierOneFoundFailing() throws Exception {
        cached(URL, "<tl>last good</tl>", Duration.ofDays(1));
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);
        var first = loader(url -> { throw new IOException("connection refused"); }, clock, cooldown,
                Duration.ofSeconds(5));
        assertEquals("<tl>last good</tl>", text(first.getDocument(URL)));

        var second = loader(url -> { throw new AssertionError("the URL is cooling down"); }, clock, cooldown,
                Duration.ofSeconds(5));

        assertEquals("<tl>last good</tl>", text(second.getDocument(URL)));
    }

    @Test
    void theCooldownLeavesOtherListsAlone() throws Exception {
        var other = "https://tsl.example.test/tsl-cz.xml";
        var clock = new TrustedListCooldownTest.MutableClock(NOW);
        var cooldown = new TrustedListCooldown(clock);
        cooldown.recordFailure(URL);
        var loader = loader(url -> xml("<tl>cz</tl>"), clock, cooldown, Duration.ofSeconds(5));

        assertEquals("<tl>cz</tl>", text(loader.getDocument(other)));
    }

    private TrustedListCacheLoader loader(TrustedListCacheLoader.Fetcher fetcher, Clock clock,
            TrustedListCooldown cooldown, Duration requestTimeout) {
        return new TrustedListCacheLoader(cache, fetcher, clock, TrustedListCacheLoader.FRESH_FOR,
                TrustedListCacheLoader.MAX_FALLBACK_AGE, requestTimeout, null, cooldown);
    }

    private TrustedListCacheLoader loader(TrustedListCacheLoader.Fetcher fetcher) {
        return new TrustedListCacheLoader(cache, fetcher, CLOCK, TrustedListCacheLoader.FRESH_FOR,
                TrustedListCacheLoader.MAX_FALLBACK_AGE, Duration.ofSeconds(5), null);
    }

    private void cached(String url, String content, Duration age) throws IOException {
        var file = loader(ignored -> { throw new AssertionError(); }).cacheFile(url);
        Files.createDirectories(file.getParent());
        Files.writeString(file, content);
        Files.setLastModifiedTime(file, FileTime.from(NOW.minus(age)));
    }

    private static byte[] xml(String content) {
        return content.getBytes(StandardCharsets.UTF_8);
    }

    private static String text(DSSDocument document) throws IOException {
        try (var stream = document.openStream()) {
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
