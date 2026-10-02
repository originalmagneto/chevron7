package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.DSSDocument;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.service.http.commons.CommonsDataLoader;
import eu.europa.esig.dss.spi.DSSUtils;
import eu.europa.esig.dss.spi.client.http.DSSCacheFileLoader;
import eu.europa.esig.dss.spi.exception.DSSExternalResourceException;
import eu.europa.esig.dss.xml.utils.DomUtils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * Loads the EU list of trusted lists and the national lists for DSS's TLValidationJob.
 *
 * <p>DSS's own FileCacheDataLoader waits as long as a server keeps the connection open,
 * forgets the cached copy as soon as a download fails, and keeps its files in the
 * temporary directory. One dead national server (tsl.belgium.be, 2026-10-02) then kept
 * every visible signature from loading the lists at all. This loader caps every download
 * in wall-clock time (the HTTP timeouts only measure inactivity, so a server trickling a
 * large list never trips them), also gives up at a deadline shared by the whole load,
 * keeps the last good copy of each list in a persistent directory, and falls back to that
 * copy within {@link #MAX_FALLBACK_AGE} when its server is down. A copy is replaced only
 * by XML, so an error page never overwrites it.
 */
public final class TrustedListCacheLoader implements DSSCacheFileLoader {
    /** The directory the app names for the cache; without it the temporary directory is used. */
    public static final String CACHE_DIRECTORY_ENVIRONMENT = "AUTOGRAM_TRUSTED_LIST_CACHE";
    /** A cached copy younger than this is used without asking its server. */
    public static final Duration FRESH_FOR = Duration.ofHours(6);
    /** The oldest copy used when its server cannot be reached. */
    public static final Duration MAX_FALLBACK_AGE = Duration.ofDays(7);
    /** The longest one download may take, from connecting to the last byte. */
    public static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(30);
    static final int CONNECT_TIMEOUT_MILLIS = 10_000;
    static final int READ_TIMEOUT_MILLIS = 30_000;
    private static final String TEMPORARY_DIRECTORY_NAME = "autogram-trusted-lists";
    private static final Logger logger = LoggerFactory.getLogger(TrustedListCacheLoader.class);

    @FunctionalInterface
    public interface Fetcher {
        byte[] fetch(String url) throws Exception;
    }

    private final Path cacheDirectory;
    private final transient Fetcher fetcher;
    private final Clock clock;
    private final Duration freshFor;
    private final Duration maxFallbackAge;
    private final Duration requestTimeout;
    private final Instant deadline;
    private final transient ExecutorService downloads = Executors.newCachedThreadPool(runnable -> {
        var thread = new Thread(runnable, "trusted-list-download");
        thread.setDaemon(true);
        return thread;
    });

    /**
     * @param deadline when the whole load gives up; every download still running then
     *                 falls back to its cached copy. Null means only the per-request cap.
     */
    public TrustedListCacheLoader(Path cacheDirectory, Fetcher fetcher, Clock clock, Duration freshFor,
            Duration maxFallbackAge, Duration requestTimeout, Instant deadline) {
        this.cacheDirectory = cacheDirectory;
        this.fetcher = fetcher;
        this.clock = clock;
        this.freshFor = freshFor;
        this.maxFallbackAge = maxFallbackAge;
        this.requestTimeout = requestTimeout;
        this.deadline = deadline;
    }

    /** The production loader: HTTP with connect and read timeouts, the system clock, the app's cache. */
    public static TrustedListCacheLoader standard(Instant deadline) {
        return new TrustedListCacheLoader(cacheDirectory(System.getenv(), System.getProperty("java.io.tmpdir")),
                httpFetcher(), Clock.systemUTC(), FRESH_FOR, MAX_FALLBACK_AGE, REQUEST_TIMEOUT, deadline);
    }

    static Path cacheDirectory(Map<String, String> environment, String temporaryDirectory) {
        var configured = environment.get(CACHE_DIRECTORY_ENVIRONMENT);
        if (configured != null && !configured.isBlank()) {
            return Path.of(configured);
        }
        return Path.of(temporaryDirectory, TEMPORARY_DIRECTORY_NAME);
    }

    static Fetcher httpFetcher() {
        var trustStore = tlsTrustStore();
        var loader = new CommonsDataLoader() {
            @Override
            protected KeyStore getSSLTrustStore() {
                return trustStore;
            }
        };
        loader.setTimeoutConnection(CONNECT_TIMEOUT_MILLIS);
        loader.setTimeoutConnectionRequest(CONNECT_TIMEOUT_MILLIS);
        loader.setTimeoutSocket(READ_TIMEOUT_MILLIS);
        loader.setTimeoutResponse(READ_TIMEOUT_MILLIS);
        loader.setRedirectsEnabled(true);
        return loader::get;
    }

    /**
     * The roots the downloads trust: the JDK's and, on macOS, the system's. Several
     * national list servers chain to roots only the system knows (www.nccert.pl to
     * Certum Trusted Root CA, nmhh.hu to Microsec e-Szigno Root CA 2009), and a list's
     * content is verified by its own XML signature anyway, so TLS here needs no stricter
     * trust than the browser's.
     */
    static KeyStore tlsTrustStore() {
        return tlsTrustStore(javaRoots(), macRoots());
    }

    static KeyStore tlsTrustStore(KeyStore... sources) {
        try {
            var merged = KeyStore.getInstance("PKCS12");
            merged.load(null, null);
            var index = 0;
            for (var source : sources) {
                if (source == null) {
                    continue;
                }
                for (var aliases = source.aliases(); aliases.hasMoreElements();) {
                    var alias = aliases.nextElement();
                    if (source.isCertificateEntry(alias) && source.getCertificate(alias) != null) {
                        merged.setCertificateEntry("root-" + index++, source.getCertificate(alias));
                    }
                }
            }
            return merged;
        } catch (GeneralSecurityException | IOException exception) {
            throw new IllegalStateException("Cannot build the trust store for trusted list downloads", exception);
        }
    }

    private static KeyStore javaRoots() {
        var cacerts = Path.of(System.getProperty("java.home"), "lib", "security", "cacerts");
        try (var input = Files.newInputStream(cacerts)) {
            var store = KeyStore.getInstance(KeyStore.getDefaultType());
            store.load(input, null);
            return store;
        } catch (GeneralSecurityException | IOException exception) {
            logger.warn("Cannot read the Java root certificates: {}", exception.getMessage());
            return null;
        }
    }

    private static KeyStore macRoots() {
        try {
            var store = KeyStore.getInstance("KeychainStore-ROOT");
            store.load(null, null);
            return store;
        } catch (GeneralSecurityException | IOException exception) {
            // Not macOS, or a JDK without the system root keystore.
            return null;
        }
    }

    @Override
    public DSSDocument getDocument(String url) {
        return getDocument(url, false);
    }

    @Override
    public DSSDocument getDocument(String url, boolean refresh) {
        var file = cacheFile(url);
        var cached = readCached(file);
        if (!refresh && cached != null && age(file).compareTo(freshFor) < 0) {
            return document(cached, url);
        }
        Exception failure;
        try {
            return document(download(url, file), url);
        } catch (Exception exception) {
            failure = exception;
        }
        if (cached != null && age(file).compareTo(maxFallbackAge) <= 0) {
            logger.warn("Using the cached copy of {} ({} old): {}", url, age(file), failure.getMessage());
            return document(cached, url);
        }
        throw new DSSExternalResourceException(String.format("Cannot retrieve the trusted list [%s]: %s", url,
                failure.getMessage()));
    }

    @Override
    public DSSDocument getDocumentFromCache(String url) {
        var cached = readCached(cacheFile(url));
        return cached == null ? null : document(cached, url);
    }

    @Override
    public boolean remove(String url) {
        try {
            return Files.deleteIfExists(cacheFile(url));
        } catch (IOException exception) {
            logger.warn("Cannot remove the cached copy of {}: {}", url, exception.getMessage());
            return false;
        }
    }

    Path cacheFile(String url) {
        return cacheDirectory.resolve(DSSUtils.getNormalizedString(url));
    }

    /**
     * Runs the download on its own daemon thread so the caller can stop waiting: blocking
     * HTTP ignores interrupts. A download that finishes after the caller gave up still
     * stores its copy, which the next load then finds fresh.
     */
    private byte[] download(String url, Path file) throws Exception {
        var wait = remainingWait();
        if (wait.isZero()) {
            throw new TimeoutException("the trusted list load ran out of time");
        }
        var task = downloads.submit(() -> {
            var bytes = fetcher.fetch(url);
            if (bytes == null || bytes.length == 0 || !DomUtils.isDOM(bytes)) {
                throw new IOException("the server did not return XML");
            }
            store(file, bytes);
            return bytes;
        });
        try {
            return task.get(wait.toNanos(), TimeUnit.NANOSECONDS);
        } catch (TimeoutException exception) {
            throw new TimeoutException("no complete answer within " + wait.toMillis() + " ms");
        } catch (ExecutionException exception) {
            throw exception.getCause() instanceof Exception cause ? cause : exception;
        } catch (InterruptedException exception) {
            task.cancel(true);
            Thread.currentThread().interrupt();
            throw exception;
        }
    }

    private Duration remainingWait() {
        if (deadline == null) {
            return requestTimeout;
        }
        var untilDeadline = Duration.between(clock.instant(), deadline);
        if (untilDeadline.isNegative() || untilDeadline.isZero()) {
            return Duration.ZERO;
        }
        return untilDeadline.compareTo(requestTimeout) < 0 ? untilDeadline : requestTimeout;
    }

    /** Writes next to the old copy and moves over it, so a reader never sees half a list. */
    private void store(Path file, byte[] bytes) {
        try {
            Files.createDirectories(file.getParent());
            var temporary = Files.createTempFile(file.getParent(), file.getFileName().toString(), ".part");
            try {
                Files.write(temporary, bytes);
                Files.move(temporary, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } finally {
                Files.deleteIfExists(temporary);
            }
        } catch (IOException exception) {
            // The list itself downloaded; only the next run loses the copy.
            logger.warn("Cannot store the trusted list in {}: {}", file.getParent(), exception.getMessage());
        }
    }

    private static byte[] readCached(Path file) {
        try {
            return Files.readAllBytes(file);
        } catch (NoSuchFileException exception) {
            return null;
        } catch (IOException exception) {
            logger.warn("Cannot read the cached trusted list {}: {}", file, exception.getMessage());
            return null;
        }
    }

    private Duration age(Path file) {
        try {
            var age = Duration.between(Files.getLastModifiedTime(file).toInstant(), clock.instant());
            return age.isNegative() ? Duration.ZERO : age;
        } catch (IOException exception) {
            return Duration.ofDays(36_500);
        }
    }

    private static DSSDocument document(byte[] bytes, String url) {
        return new InMemoryDocument(bytes, DSSUtils.getNormalizedString(url));
    }
}
