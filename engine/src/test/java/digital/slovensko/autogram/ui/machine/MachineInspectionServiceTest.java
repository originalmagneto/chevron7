package digital.slovensko.autogram.ui.machine;

import digital.slovensko.autogram.core.UserSettings;
import eu.europa.esig.dss.enumerations.Indication;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.enumerations.SignatureQualification;
import eu.europa.esig.dss.enumerations.SubIndication;
import eu.europa.esig.dss.enumerations.TimestampQualification;
import eu.europa.esig.dss.jaxb.object.Message;
import eu.europa.esig.dss.simplereport.SimpleReport;
import eu.europa.esig.dss.simplereport.jaxb.XmlTimestamp;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.concurrent.AbstractExecutorService;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MachineInspectionServiceTest {
    @Test
    void inspectsAsicDocumentsAndSignatureCoverage() {
        var source = Path.of(MachineInspectionServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_pdf_xades.asice").getFile());

        var payload = MachineInspectionService.withValidatorReportReader(validator -> {
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            return validator.validateDocument().getSimpleReport();
        }).inspect(source);

        var documents = payload.getAsJsonArray("documents");
        var signatures = payload.getAsJsonArray("signatures");
        assertEquals(List.of("sample.pdf"), documents.asList().stream()
                .map(document -> document.getAsJsonObject().get("name").getAsString())
                .toList());
        assertEquals(1, signatures.size());
        assertEquals(List.of("sample.pdf"), signatures.get(0).getAsJsonObject().getAsJsonArray("documents").asList()
                .stream().map(document -> document.getAsString()).toList());
    }

    @Test
    void extractsEmbeddedDocumentFromAsic() throws Exception {
        var sample = Path.of(MachineInspectionServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_pdf_xades.asice").getFile());
        var expectedPdf = Files.readAllBytes(Path.of(MachineInspectionServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));

        var service = new MachineInspectionService();
        var embedded = service.extractEmbeddedDocument(sample, "sample.pdf");

        assertEquals("sample.pdf", embedded.name());
        assertEquals("application/pdf", embedded.mediaType());
        assertArrayEquals(expectedPdf, embedded.content());
        assertThrows(MachineProtocolException.class,
                () -> service.extractEmbeddedDocument(sample, "missing.pdf"));
    }

    @Test
    void mapsDssSubIndicationAndFirstNonblankValidationReason() {
        var expectedSubIndication = SubIndication.NO_CERTIFICATE_CHAIN_FOUND;
        var expectedSafeReason = "Certificate chain could not be built";
        var report = reportWithOneQualifiedTimestamp();
        when(report.isValid("sig-1")).thenReturn(false);
        when(report.getIndication("sig-1")).thenReturn(Indication.INDETERMINATE);
        when(report.getSubIndication("sig-1")).thenReturn(expectedSubIndication);
        when(report.getAdESValidationErrors("sig-1")).thenReturn(List.of(
                new Message("blank", "   "),
                new Message("chain", expectedSafeReason)));

        var signature = new MachineInspectionService(path -> report).inspect(Path.of("signed.pdf"))
                .getAsJsonArray("signatures").get(0).getAsJsonObject();

        assertEquals("INDETERMINATE", signature.get("indication").getAsString());
        assertEquals(expectedSubIndication.name(), signature.get("subIndication").getAsString());
        assertEquals(expectedSafeReason, signature.get("validationReason").getAsString());
    }

    @Test
    void dispatchesEachBatchEntryWithOpaqueIdAndRedactsSourceAndTargetPaths() throws Exception {
        var report = reportWithOneQualifiedTimestamp();
        var inspectedSources = new java.util.ArrayList<Path>();
        var calls = new java.util.ArrayList<String>();
        var inspectionService = new MachineInspectionService(path -> {
            calls.add("inspect:" + path.getFileName());
            inspectedSources.add(path);
            if (path.toString().contains("broken")) {
                throw new IllegalArgumentException("unreadable source");
            }
            return report;
        });
        var stdout = new java.io.StringWriter();
        var source = "/sensitive/source.pdf";
        var target = "/sensitive/target.pdf";
        var brokenSource = "/sensitive/broken.pdf";
        var brokenTarget = "/sensitive/broken-target.pdf";
        var input = "{\"protocolVersion\":1,\"requestId\":\"request-1\",\"operation\":\"INSPECT\",\"payload\":{\"files\":["
                + "{\"id\":\"opaque-1\",\"source\":\"" + source + "\",\"target\":\"" + target + "\"},"
                + "{\"id\":\"opaque-2\",\"source\":\"" + brokenSource + "\",\"target\":\"" + brokenTarget + "\"}]}}";
        var trustInitialized = new AtomicBoolean();

        var code = MachineCliApp.start(commandLine("INSPECT"), new java.io.StringReader(input), new java.io.PrintWriter(stdout),
                new java.io.PrintWriter(new java.io.StringWriter()), new MachineDriverService(), inspectionService,
                () -> {
                    calls.add("trust");
                    trustInitialized.set(true);
                });

        var events = java.util.Arrays.stream(stdout.toString().strip().split("\\n"))
                .map(com.google.gson.JsonParser::parseString)
                .map(element -> element.getAsJsonObject())
                .toList();
        assertEquals(0, code);
        assertFalse(trustInitialized.get());
        assertEquals(List.of("session.started", "inspection.completed", "file.failed", "session.completed"),
                events.stream().map(event -> event.get("type").getAsString()).toList());
        assertEquals("opaque-1", events.get(1).get("fileId").getAsString());
        assertTrue(events.get(1).getAsJsonObject("payload").getAsJsonArray("signatures").get(0).getAsJsonObject()
                .get("qualifiedTimestampValid").getAsBoolean());
        assertEquals("opaque-2", events.get(2).get("fileId").getAsString());
        assertEquals("INSPECTION_FAILED", events.get(2).getAsJsonObject("payload").get("code").getAsString());
        assertEquals(List.of(Path.of(source), Path.of(brokenSource)), inspectedSources);
        assertEquals(List.of("inspect:source.pdf", "inspect:broken.pdf"), calls);
        assertFalse(stdout.toString().contains(source));
        assertFalse(stdout.toString().contains(target));
        assertFalse(stdout.toString().contains(brokenSource));
        assertFalse(stdout.toString().contains(brokenTarget));
    }

    @Test
    void inspectsWithoutInitializingTrustedLists() throws Exception {
        var inspectionCalled = new AtomicBoolean();
        var inspectionService = new MachineInspectionService(path -> {
            inspectionCalled.set(true);
            return reportWithOneQualifiedTimestamp();
        });
        var stdout = new java.io.StringWriter();
        var input = "{\"protocolVersion\":1,\"requestId\":\"request-1\",\"operation\":\"INSPECT\",\"payload\":{\"files\":[{\"id\":\"opaque-1\",\"source\":\"/selected/signed.pdf\",\"target\":\"/selected/target.pdf\"}]}}";

        var code = MachineCliApp.start(commandLine("INSPECT"), new java.io.StringReader(input), new java.io.PrintWriter(stdout),
                new java.io.PrintWriter(new java.io.StringWriter()), new MachineDriverService(), inspectionService,
                () -> { throw new MachineProtocolException("TRUSTED_LIST_UNAVAILABLE"); });

        var events = java.util.Arrays.stream(stdout.toString().strip().split("\\n"))
                .map(com.google.gson.JsonParser::parseString)
                .map(element -> element.getAsJsonObject())
                .toList();
        assertEquals(0, code);
        assertTrue(inspectionCalled.get());
        assertEquals(List.of("session.started", "inspection.completed", "session.completed"),
                events.stream().map(event -> event.get("type").getAsString()).toList());
    }

    @Test
    void mapsSignatureAndTimestampQualificationsToSeparateFields() {
        var report = reportWithOneQualifiedTimestamp();
        var payload = new MachineInspectionService(path -> report).inspect(Path.of("signed.pdf"));

        var signature = payload.getAsJsonArray("signatures").get(0).getAsJsonObject();
        assertEquals("PAdES_BASELINE_T", signature.get("format").getAsString());
        assertEquals("Jane Signer", signature.get("signerDisplayName").getAsString());
        assertEquals("QESIG", signature.get("signerCertificateQualification").getAsString());
        assertEquals("2026-08-06T10:15:30Z", signature.get("signingTime").getAsString());
        assertTrue(signature.get("valid").getAsBoolean());
        assertEquals("TOTAL_PASSED", signature.get("indication").getAsString());
        assertTrue(signature.get("qualifiedTimestampValid").getAsBoolean());

        var timestamp = signature.getAsJsonArray("timestamps").get(0).getAsJsonObject();
        assertEquals("2026-08-06T10:16:30Z", timestamp.get("productionTime").getAsString());
        assertEquals("Qualified TSA", timestamp.get("producer").getAsString());
        assertTrue(timestamp.get("valid").getAsBoolean());
        assertEquals("QTSA", timestamp.get("qualification").getAsString());
    }

    @Test
    void readsSignatureStructureFromSampleSignedPdfWithoutDssValidation() {
        var sample = Path.of(MachineInspectionServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_signed.pdf").getFile());

        var signatures = MachineInspectionService.readStructuralSignatureCount(sample);

        assertTrue(signatures > 0);
    }

    @Test
    void returnsLocalCryptographicMetadataForSampleSignedPdf() {
        var sample = Path.of(MachineInspectionServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_signed.pdf").getFile());

        var signature = new MachineInspectionService().inspect(sample).getAsJsonArray("signatures").get(0).getAsJsonObject();

        assertTrue(signature.has("id"));
        assertTrue(signature.has("format"));
        assertTrue(signature.has("signerDisplayName"));
        assertTrue(signature.has("signingTime"));
        assertEquals(signature.get("valid").getAsBoolean(), signature.get("cryptographicIntegrity").getAsBoolean());
        assertEquals("INDETERMINATE", signature.get("indication").isJsonNull()
                ? null : signature.get("indication").getAsString());
        assertFalse(signature.get("qualifiedTimestampValid").getAsBoolean());
        assertTrue(signature.get("signerCertificateQualification").isJsonNull());
        assertTrue(signature.get("timestamps").isJsonArray());
    }

    @Test
    void trustedInspectionKeepsStructuralCryptographicIntegritySeparateFromTrustValidity() {
        var trusted = com.google.gson.JsonParser.parseString("""
                {"signatures":[{"id":"signature-1","valid":false,"timestamps":[{"id":"timestamp-1","valid":false}]}]}
                """).getAsJsonObject();
        var structural = com.google.gson.JsonParser.parseString("""
                {"signatures":[{"id":"signature-1","cryptographicIntegrity":true,"timestamps":[{"id":"timestamp-1","cryptographicIntegrity":true}]}]}
                """).getAsJsonObject();

        var signature = MachineInspectionService.mergeCryptographicIntegrity(trusted, structural)
                .getAsJsonArray("signatures").get(0).getAsJsonObject();

        assertFalse(signature.get("valid").getAsBoolean());
        assertTrue(signature.get("cryptographicIntegrity").getAsBoolean());
        var mappedTimestamp = signature.getAsJsonArray("timestamps").get(0).getAsJsonObject();
        assertFalse(mappedTimestamp.get("valid").getAsBoolean());
        assertTrue(mappedTimestamp.get("cryptographicIntegrity").getAsBoolean());
    }

    @Test
    void returnsDocumentsAndSignaturesForAsicWithoutTrustedLists() {
        var sample = Path.of(MachineInspectionServiceTest.class
                .getResource("/digital/slovensko/autogram/general_agenda.asice").getFile());

        var payload = new MachineInspectionService().inspect(sample);

        assertFalse(payload.getAsJsonArray("documents").isEmpty());
        assertFalse(payload.getAsJsonArray("signatures").isEmpty());
    }

    /// The pre-sign signature census runs on a helper that may never have warmed the trusted
    /// lists: it must report no signatures instead of throwing on a null verifier.
    @Test
    void trustedInspectionOfAnUnsignedPdfNeedsNoTrustedLists() throws Exception {
        var unsigned = Files.readAllBytes(Path.of(MachineInspectionServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));

        var payload = MachineInspectionService.forTrustedValidation().inspect(unsigned);

        assertTrue(payload.getAsJsonArray("signatures").isEmpty());
    }

    @Test
    void rejectsBatchEntryWithoutTargetBeforeTrustInitialization() throws Exception {
        var trustInitialized = new AtomicBoolean();
        var stdout = new java.io.StringWriter();
        var source = "/sensitive/source.pdf";
        var input = "{\"protocolVersion\":1,\"requestId\":\"request-1\",\"operation\":\"INSPECT\",\"payload\":{\"files\":[{\"id\":\"opaque-1\",\"source\":\""
                + source + "\"}]}}";

        var code = MachineCliApp.start(commandLine("INSPECT"), new java.io.StringReader(input), new java.io.PrintWriter(stdout),
                new java.io.PrintWriter(new java.io.StringWriter()), new MachineDriverService(),
                new MachineInspectionService(path -> reportWithOneQualifiedTimestamp()), () -> trustInitialized.set(true));

        assertEquals(64, code);
        assertFalse(trustInitialized.get());
        assertTrue(stdout.toString().contains("PROTOCOL_INVALID_REQUEST"));
        assertFalse(stdout.toString().contains(source));
    }

    @Test
    void rejectsMalformedLaterBatchEntryBeforeTrustOrInspection() throws Exception {
        var trustInitialized = new AtomicBoolean();
        var inspectionCalled = new AtomicBoolean();
        var stdout = new java.io.StringWriter();
        var input = "{\"protocolVersion\":1,\"requestId\":\"request-1\",\"operation\":\"INSPECT\",\"payload\":{\"files\":["
                + "{\"id\":\"opaque-1\",\"source\":\"/selected/one.pdf\",\"target\":\"/selected/one-target.pdf\"},"
                + "{\"id\":\"opaque-2\",\"source\":\"/selected/two.pdf\"}]}}";

        var code = MachineCliApp.start(commandLine("INSPECT"), new java.io.StringReader(input), new java.io.PrintWriter(stdout),
                new java.io.PrintWriter(new java.io.StringWriter()), new MachineDriverService(),
                new MachineInspectionService(path -> {
                    inspectionCalled.set(true);
                    return reportWithOneQualifiedTimestamp();
                }), () -> trustInitialized.set(true));

        assertEquals(64, code);
        assertFalse(trustInitialized.get());
        assertFalse(inspectionCalled.get());
        assertTrue(stdout.toString().contains("PROTOCOL_INVALID_REQUEST"));
    }

    @Test
    void continuesWithValidSecondFileAfterFirstInspectionFailure() throws Exception {
        var stdout = new java.io.StringWriter();
        var input = "{\"protocolVersion\":1,\"requestId\":\"request-1\",\"operation\":\"INSPECT\",\"payload\":{\"files\":["
                + "{\"id\":\"opaque-failed\",\"source\":\"/selected/broken.pdf\",\"target\":\"/selected/broken-target.pdf\"},"
                + "{\"id\":\"opaque-valid\",\"source\":\"/selected/valid.pdf\",\"target\":\"/selected/valid-target.pdf\"}]}}";
        var inspectionService = new MachineInspectionService(path -> {
            if (path.getFileName().toString().equals("broken.pdf")) {
                throw new IllegalArgumentException("unreadable");
            }
            return reportWithOneQualifiedTimestamp();
        });

        var code = MachineCliApp.start(commandLine("INSPECT"), new java.io.StringReader(input), new java.io.PrintWriter(stdout),
                new java.io.PrintWriter(new java.io.StringWriter()), new MachineDriverService(), inspectionService, () -> {
                });

        var events = java.util.Arrays.stream(stdout.toString().strip().split("\\n"))
                .map(com.google.gson.JsonParser::parseString)
                .map(element -> element.getAsJsonObject())
                .toList();
        assertEquals(0, code);
        assertEquals(List.of("session.started", "file.failed", "inspection.completed", "session.completed"),
                events.stream().map(event -> event.get("type").getAsString()).toList());
        assertEquals("opaque-failed", events.get(1).get("fileId").getAsString());
        assertEquals("opaque-valid", events.get(2).get("fileId").getAsString());
    }

    /// Machine mode no longer follows the GUI's stored list: the Java preferences are shared
    /// with the upstream Autogram app, whose "SK,CZ,AT,PL,HU,BE,NL,LT" dropped Spain.
    @Test
    void productionMachineSettingsUseTheirOwnTrustedListConfiguration() {
        var machineSettings = new MachineSettings();

        assertEquals(UserSettings.defaultTrustedList(), machineSettings.getTrustedList());
        assertFalse(machineSettings.getTrustedList().isEmpty());
    }

    @Test
    void failsClosedAndClosesDedicatedExecutorWhenTrustedListsNeverLoad() {
        var executor = new ImmediateExecutorService();
        var initialized = new AtomicBoolean();
        var trust = new MachineTrustService(
                () -> executor,
                ignored -> initialized.set(true),
                () -> false,
                Duration.ZERO,
                Duration.ZERO);

        var failure = assertThrows(MachineProtocolException.class, trust::initialize);

        assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
        assertTrue(initialized.get());
        assertTrue(executor.isShutdown());
    }

    @Test
    void waitsForInitializationBeforeReadingTrustedListState() {
        var executor = new NeverRunsExecutorService();
        var trustedListStateRead = new AtomicBoolean();
        var trust = new MachineTrustService(
                () -> executor,
                ignored -> {
                },
                () -> {
                    trustedListStateRead.set(true);
                    return false;
                },
                Duration.ZERO,
                Duration.ZERO);

        var failure = assertThrows(MachineProtocolException.class, trust::initialize);

        assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
        assertFalse(trustedListStateRead.get());
        assertTrue(executor.isShutdown());
    }

    @Test
    void closesDedicatedExecutorAfterTrustedListsLoad() {
        var executor = new RecordingExecutorService(true, true);
        var initialized = new AtomicBoolean();
        var trust = trust(
                () -> executor,
                ignored -> initialized.set(true),
                initialized::get,
                Duration.ofNanos(10),
                nanos -> {
                });

        trust.initialize();

        assertTrue(executor.isShutdown());
        assertEquals(10, executor.awaitedNanos);
    }

    @Test
    void closesDedicatedExecutorAfterInitializationFailure() {
        var executor = new RecordingExecutorService(true, true);
        var trust = trust(
                () -> executor,
                ignored -> { throw new IllegalStateException("initialization failed"); },
                () -> false,
                Duration.ofNanos(10),
                nanos -> {
                });

        var failure = assertThrows(MachineProtocolException.class, trust::initialize);

        assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
        assertTrue(executor.isShutdown());
        assertEquals(10, executor.awaitedNanos);
    }

    @Test
    void failsClosedWhenExecutorDoesNotTerminateWithinRemainingDeadline() {
        var executor = new RecordingExecutorService(true, false);
        var initialized = new AtomicBoolean();
        var trust = trust(
                () -> executor,
                ignored -> initialized.set(true),
                initialized::get,
                Duration.ofNanos(10),
                nanos -> {
                });

        var failure = assertThrows(MachineProtocolException.class, trust::initialize);

        assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
        assertTrue(executor.isShutdown());
        assertEquals(10, executor.awaitedNanos);
    }

    @Test
    void timesOutPendingInitializationThenAwaitsOnlyRemainingDeadline() {
        var executor = new RecordingExecutorService(false, true);
        var now = new AtomicLong();
        var trust = trust(
                () -> executor,
                ignored -> {
                },
                () -> false,
                Duration.ofNanos(10),
                nanos -> now.addAndGet(nanos),
                now);

        var failure = assertThrows(MachineProtocolException.class, trust::initialize);

        assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
        assertTrue(executor.isShutdown());
        assertEquals(0, executor.awaitedNanos);
    }

    @Test
    void cancelsUnfinishedInitializationBeforeClosingExecutor() {
        var executor = new RecordingExecutorService(false, true);
        var now = new AtomicLong();
        var trust = trust(
                () -> executor,
                ignored -> {
                },
                () -> false,
                Duration.ofNanos(10),
                nanos -> now.addAndGet(nanos),
                now);

        var failure = assertThrows(MachineProtocolException.class, trust::initialize);

        assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
        assertTrue(executor.submittedTask.isCancelled());
        assertTrue(executor.isShutdown());
    }

    @Test
    void awaitsOnlyDeadlineTimeRemainingAfterSuccessfulTrustLoad() {
        var executor = new RecordingExecutorService(true, true);
        var initialized = new AtomicBoolean();
        var now = new AtomicLong();
        var trust = trust(
                () -> executor,
                ignored -> initialized.set(true),
                () -> {
                    now.addAndGet(4);
                    return initialized.get();
                },
                Duration.ofNanos(10),
                nanos -> {
                },
                now);

        trust.initialize();

        assertEquals(6, executor.awaitedNanos);
    }

    @Test
    void failsClosedWhenTrustStateLoadsAfterTheDeadline() {
        var executor = new RecordingExecutorService(true, true);
        var initialized = new AtomicBoolean();
        var now = new AtomicLong();
        var trustChecks = new AtomicInteger();
        var trust = trust(
                () -> executor,
                ignored -> initialized.set(true),
                () -> initialized.get() && trustChecks.getAndIncrement() > 0,
                Duration.ofNanos(10),
                nanos -> now.set(11),
                now);

        var failure = assertThrows(MachineProtocolException.class, trust::initialize);

        assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
        assertEquals(0, executor.awaitedNanos);
    }

    @Test
    void failsClosedWhenTrustSupplierReturnsTrueAfterAdvancingPastDeadline() {
        var executor = new RecordingExecutorService(true, true);
        var initialized = new AtomicBoolean();
        var now = new AtomicLong();
        var trust = trust(
                () -> executor,
                ignored -> initialized.set(true),
                () -> {
                    now.set(11);
                    return initialized.get();
                },
                Duration.ofNanos(10),
                nanos -> {
                },
                now);

        var failure = assertThrows(MachineProtocolException.class, trust::initialize);

        assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
    }

    @Test
    void doesNotSleepWhenTrustSupplierReturnsFalseAfterAdvancingPastDeadline() {
        var executor = new RecordingExecutorService(true, true);
        var initialized = new AtomicBoolean();
        var now = new AtomicLong();
        var sleeps = new java.util.ArrayList<Long>();
        var trust = trust(
                () -> executor,
                ignored -> initialized.set(true),
                () -> {
                    now.set(11);
                    return false;
                },
                Duration.ofNanos(10),
                sleeps::add,
                now);

        var failure = assertThrows(MachineProtocolException.class, trust::initialize);

        assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
        assertTrue(sleeps.isEmpty());
    }

    @Test
    void invokesShutdownNowInsteadOfGracefulShutdown() {
        var executor = new RecordingExecutorService(true, true);
        var initialized = new AtomicBoolean();
        var trust = trust(
                () -> executor,
                ignored -> initialized.set(true),
                initialized::get,
                Duration.ofNanos(10),
                nanos -> {
                });

        trust.initialize();

        assertTrue(executor.shutdownNowCalled);
        assertFalse(executor.shutdownCalled);
    }

    @Test
    void interruptsBlockingInitializerAndAwaitsRealExecutorTermination() throws Exception {
        var executor = new RecordingSingleThreadExecutor();
        var workerStarted = new CountDownLatch(1);
        var workerInterrupted = new CountDownLatch(1);
        var trust = new MachineTrustService(
                () -> executor,
                ignored -> {
                    workerStarted.countDown();
                    try {
                        new CountDownLatch(1).await();
                    } catch (InterruptedException exception) {
                        workerInterrupted.countDown();
                        Thread.currentThread().interrupt();
                    }
                },
                () -> false,
                Duration.ofSeconds(5),
                Duration.ofMillis(1),
                System::nanoTime,
                nanos -> {
                    if (!workerStarted.await(1, TimeUnit.SECONDS)) {
                        throw new AssertionError("initializer did not start");
                    }
                    throw new InterruptedException("stop");
                });

        try {
            var failure = assertThrows(MachineProtocolException.class, trust::initialize);

            assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
            assertTrue(Thread.currentThread().isInterrupted());
            Thread.interrupted();
            assertTrue(workerStarted.await(1, TimeUnit.SECONDS));
            assertTrue(workerInterrupted.await(1, TimeUnit.SECONDS));
            assertTrue(executor.awaitTerminationCalled.get());
            assertTrue(executor.isTerminated());
        } finally {
            Thread.interrupted();
            executor.shutdownNow();
        }
    }

    @Test
    void restoresInterruptFlagWhenAwaitTerminationIsInterrupted() {
        var executor = new InterruptingAwaitExecutorService();
        var initialized = new AtomicBoolean();
        var trust = trust(
                () -> executor,
                ignored -> initialized.set(true),
                initialized::get,
                Duration.ofNanos(10),
                nanos -> {
                });

        try {
            var failure = assertThrows(MachineProtocolException.class, trust::initialize);

            assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
            assertTrue(executor.shutdownNowCalled);
            assertTrue(Thread.currentThread().isInterrupted());
        } finally {
            Thread.interrupted();
        }
    }

    @Test
    void preservesInterruptionWhileClosingDedicatedExecutor() {
        var executor = new RecordingExecutorService(false, true);
        var trust = trust(
                () -> executor,
                ignored -> {
                },
                () -> false,
                Duration.ofNanos(10),
                nanos -> { throw new InterruptedException("stop"); });

        try {
            var failure = assertThrows(MachineProtocolException.class, trust::initialize);

            assertEquals("TRUSTED_LIST_UNAVAILABLE", failure.getMessage());
            assertTrue(Thread.currentThread().isInterrupted());
            assertTrue(executor.isShutdown());
            assertEquals(10, executor.awaitedNanos);
        } finally {
            Thread.interrupted();
        }
    }

    @Test
    void waitsForValidatorInitializationBeforeCheckingTrustedLists() {
        var executor = new ImmediateExecutorService();
        var initialized = new AtomicBoolean();
        var checks = new AtomicInteger();
        var trust = new MachineTrustService(
                () -> executor,
                ignored -> initialized.set(true),
                () -> {
                    if (checks.getAndIncrement() == 0) {
                        throw new NullPointerException("validator is not initialized yet");
                    }
                    return initialized.get();
                },
                Duration.ofSeconds(1),
                Duration.ofMillis(1));

        trust.initialize();

        assertTrue(executor.isShutdown());
    }

    private static SimpleReport reportWithOneQualifiedTimestamp() {
        var report = mock(SimpleReport.class);
        var timestamp = new XmlTimestamp();
        timestamp.setId("ts-1");
        var signingTime = Date.from(Instant.parse("2026-08-06T10:15:30Z"));
        var productionTime = Date.from(Instant.parse("2026-08-06T10:16:30Z"));
        when(report.getSignatureIdList()).thenReturn(List.of("sig-1"));
        when(report.getSignatureFormat("sig-1")).thenReturn(SignatureLevel.PAdES_BASELINE_T);
        when(report.getSignedBy("sig-1")).thenReturn("Jane Signer");
        when(report.getSignatureQualification("sig-1")).thenReturn(SignatureQualification.QESIG);
        when(report.getSigningTime("sig-1")).thenReturn(signingTime);
        when(report.isValid("sig-1")).thenReturn(true);
        when(report.getIndication("sig-1")).thenReturn(Indication.TOTAL_PASSED);
        when(report.getSignatureTimestamps("sig-1")).thenReturn(List.of(timestamp));
        when(report.getProductionTime("ts-1")).thenReturn(productionTime);
        when(report.getProducedBy("ts-1")).thenReturn("Qualified TSA");
        when(report.isValid("ts-1")).thenReturn(true);
        when(report.getTimestampQualification("ts-1")).thenReturn(TimestampQualification.QTSA);
        return report;
    }

    private static org.apache.commons.cli.CommandLine commandLine(String operation) throws Exception {
        var options = new org.apache.commons.cli.Options()
                .addOption(null, "machine-readable", false, "")
                .addOption(null, "protocol-version", true, "")
                .addOption(null, "operation", true, "");
        return new org.apache.commons.cli.DefaultParser().parse(options,
                new String[] { "--machine-readable", "--protocol-version", "1", "--operation", operation });
    }

    private static MachineTrustService trust(java.util.function.Supplier<ExecutorService> executorFactory,
            java.util.function.Consumer<ExecutorService> initializer, java.util.function.BooleanSupplier trustedListsLoaded,
            Duration timeout, MachineTrustService.Sleeper sleeper) {
        return trust(executorFactory, initializer, trustedListsLoaded, timeout, sleeper, new AtomicLong());
    }

    private static MachineTrustService trust(java.util.function.Supplier<ExecutorService> executorFactory,
            java.util.function.Consumer<ExecutorService> initializer, java.util.function.BooleanSupplier trustedListsLoaded,
            Duration timeout, MachineTrustService.Sleeper sleeper, AtomicLong now) {
        return new MachineTrustService(executorFactory, initializer, trustedListsLoaded, timeout, Duration.ofNanos(1),
                now::get, sleeper);
    }

    private static final class ImmediateExecutorService extends AbstractExecutorService {
        private boolean shutdown;

        @Override
        public void shutdown() {
            shutdown = true;
        }

        @Override
        public List<Runnable> shutdownNow() {
            shutdown = true;
            return List.of();
        }

        @Override
        public boolean isShutdown() {
            return shutdown;
        }

        @Override
        public boolean isTerminated() {
            return shutdown;
        }

        @Override
        public boolean awaitTermination(long timeout, TimeUnit unit) {
            return shutdown;
        }

        @Override
        public void execute(Runnable command) {
            command.run();
        }
    }

    private static final class NeverRunsExecutorService extends AbstractExecutorService {
        private boolean shutdown;

        @Override
        public void shutdown() {
            shutdown = true;
        }

        @Override
        public List<Runnable> shutdownNow() {
            shutdown = true;
            return List.of();
        }

        @Override
        public boolean isShutdown() {
            return shutdown;
        }

        @Override
        public boolean isTerminated() {
            return shutdown;
        }

        @Override
        public boolean awaitTermination(long timeout, TimeUnit unit) {
            return shutdown;
        }

        @Override
        public void execute(Runnable command) {
        }
    }

    private static class RecordingExecutorService extends AbstractExecutorService {
        private final boolean runTasks;
        private final boolean terminates;
        private boolean shutdownCalled;
        protected boolean shutdownNowCalled;
        private long awaitedNanos = -1;
        private Future<?> submittedTask;

        protected RecordingExecutorService(boolean runTasks, boolean terminates) {
            this.runTasks = runTasks;
            this.terminates = terminates;
        }

        @Override
        public void shutdown() {
            shutdownCalled = true;
        }

        @Override
        public List<Runnable> shutdownNow() {
            shutdownNowCalled = true;
            return List.of();
        }

        @Override
        public boolean isShutdown() {
            return shutdownCalled || shutdownNowCalled;
        }

        @Override
        public boolean isTerminated() {
            return isShutdown() && terminates;
        }

        @Override
        public boolean awaitTermination(long timeout, TimeUnit unit) throws InterruptedException {
            awaitedNanos = unit.toNanos(timeout);
            return terminates;
        }

        @Override
        public void execute(Runnable command) {
            if (command instanceof Future<?> future) {
                submittedTask = future;
            }
            if (runTasks) {
                command.run();
            }
        }
    }

    private static final class RecordingSingleThreadExecutor extends ThreadPoolExecutor {
        private final AtomicBoolean awaitTerminationCalled = new AtomicBoolean();

        private RecordingSingleThreadExecutor() {
            super(1, 1, 0, TimeUnit.MILLISECONDS, new LinkedBlockingQueue<>());
        }

        @Override
        public boolean awaitTermination(long timeout, TimeUnit unit) throws InterruptedException {
            awaitTerminationCalled.set(true);
            return super.awaitTermination(timeout, unit);
        }
    }

    private static final class InterruptingAwaitExecutorService extends RecordingExecutorService {
        private InterruptingAwaitExecutorService() {
            super(true, true);
        }

        @Override
        public boolean awaitTermination(long timeout, TimeUnit unit) throws InterruptedException {
            throw new InterruptedException("stop");
        }
    }
}
