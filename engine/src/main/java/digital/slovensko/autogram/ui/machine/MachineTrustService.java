package digital.slovensko.autogram.ui.machine;

import digital.slovensko.autogram.core.SignatureValidator;
import digital.slovensko.autogram.core.TrustedListCacheLoader;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;
import java.util.function.LongSupplier;
import java.util.function.Supplier;

/**
 * Loads the EU trusted lists before a visible signature or a trusted validation.
 *
 * <p>The national lists download in parallel, each capped by {@link TrustedListCacheLoader}
 * and all of them by {@link #DOWNLOAD_BUDGET}, after which every unfinished download falls
 * back to its cached copy, so the load finishes inside {@link #LOAD_TIMEOUT} with whatever
 * did arrive. It fails only when no configured list is available at all; a visible
 * signature whose own timestamp needs a missing list is refused after signing, naming
 * that country.
 */
public final class MachineTrustService {
    private static final Duration LOAD_TIMEOUT = Duration.ofSeconds(60);
    /** Downloads stop here; the rest of the load timeout parses, validates and synchronizes. */
    private static final Duration DOWNLOAD_BUDGET = Duration.ofSeconds(45);
    private static final Duration POLL_INTERVAL = Duration.ofMillis(50);

    private final Supplier<ExecutorService> executorFactory;
    private final Consumer<ExecutorService> initializer;
    private final BooleanSupplier trustedListsLoaded;
    private final Duration loadTimeout;
    private final Duration pollInterval;
    private final LongSupplier nanoTime;
    private final Sleeper sleeper;

    public MachineTrustService() {
        this(new MachineSettings().getTrustedList());
    }

    private MachineTrustService(List<String> countries) {
        this(() -> trustedListExecutor(countries.size()),
                executor -> SignatureValidator.getInstance().initialize(executor, countries,
                        TrustedListCacheLoader.standard(Instant.now().plus(DOWNLOAD_BUDGET))),
                () -> SignatureValidator.getInstance().hasAvailableTrustedList(),
                LOAD_TIMEOUT,
                POLL_INTERVAL,
                System::nanoTime,
                TimeUnit.NANOSECONDS::sleep);
    }

    MachineTrustService(Supplier<ExecutorService> executorFactory, Consumer<ExecutorService> initializer,
            BooleanSupplier trustedListsLoaded, Duration loadTimeout, Duration pollInterval) {
        this(executorFactory, initializer, trustedListsLoaded, loadTimeout, pollInterval, System::nanoTime,
                TimeUnit.NANOSECONDS::sleep);
    }

    MachineTrustService(Supplier<ExecutorService> executorFactory, Consumer<ExecutorService> initializer,
            BooleanSupplier trustedListsLoaded, Duration loadTimeout, Duration pollInterval, LongSupplier nanoTime,
            Sleeper sleeper) {
        this.executorFactory = executorFactory;
        this.initializer = initializer;
        this.trustedListsLoaded = trustedListsLoaded;
        this.loadTimeout = loadTimeout;
        this.pollInterval = pollInterval;
        this.nanoTime = nanoTime;
        this.sleeper = sleeper;
    }

    /**
     * DSS runs the LOTL and then every national list as tasks on this executor while the
     * loading task itself waits on them, so it needs a thread for that wait, one for the
     * LOTL and one per country; with fewer the lists download one after another.
     */
    static ExecutorService trustedListExecutor(int countries) {
        var counter = new AtomicInteger();
        return Executors.newFixedThreadPool(countries + 2, runnable -> {
            var thread = new Thread(runnable, "trusted-list-load-" + counter.incrementAndGet());
            thread.setDaemon(true);
            return thread;
        });
    }

    public void initialize() {
        var executor = executorFactory.get();
        var deadline = nanoTime.getAsLong() + loadTimeout.toNanos();
        Future<?> initialization = null;
        try {
            initialization = executor.submit(() -> initializer.accept(executor));
            waitForTrustedLists(initialization, deadline);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw unavailable(exception);
        } catch (ExecutionException | RuntimeException exception) {
            throw unavailable(exception);
        } finally {
            closeExecutor(executor, initialization, deadline);
        }
    }

    private void waitForTrustedLists(Future<?> initialization, long deadline) throws InterruptedException, ExecutionException {
        while (true) {
            var remainingNanos = remainingNanos(deadline);
            if (remainingNanos <= 0) {
                throw unavailable(null);
            }
            if (initialization.isDone()) {
                initialization.get();
                var trustedListsLoaded = areTrustedListsLoaded();
                if (remainingNanos(deadline) <= 0) {
                    throw unavailable(null);
                }
                if (trustedListsLoaded) {
                    return;
                }
            }
            remainingNanos = remainingNanos(deadline);
            if (remainingNanos <= 0) {
                throw unavailable(null);
            }
            var sleepNanos = Math.min(remainingNanos, pollInterval.toNanos());
            if (sleepNanos > 0) {
                sleeper.sleep(sleepNanos);
            }
        }
    }

    private void closeExecutor(ExecutorService executor, Future<?> initialization, long deadline) {
        if (initialization != null && !initialization.isDone()) {
            initialization.cancel(true);
        }
        executor.shutdownNow();
        var interrupted = Thread.interrupted();
        try {
            if (!executor.awaitTermination(remainingNanos(deadline), TimeUnit.NANOSECONDS)) {
                throw unavailable(null);
            }
        } catch (InterruptedException exception) {
            interrupted = true;
            throw unavailable(exception);
        } finally {
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
        }
    }

    private long remainingNanos(long deadline) {
        return Math.max(0, deadline - nanoTime.getAsLong());
    }

    private static MachineProtocolException unavailable(Throwable cause) {
        return cause == null
                ? new MachineProtocolException("TRUSTED_LIST_UNAVAILABLE")
                : new MachineProtocolException("TRUSTED_LIST_UNAVAILABLE", cause);
    }

    private boolean areTrustedListsLoaded() {
        try {
            return trustedListsLoaded.getAsBoolean();
        } catch (NullPointerException exception) {
            return false;
        }
    }

    @FunctionalInterface
    interface Sleeper {
        void sleep(long nanos) throws InterruptedException;
    }
}
