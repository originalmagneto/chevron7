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
