package digital.slovensko.autogram.ui.machine;

import com.google.gson.JsonParser;
import digital.slovensko.autogram.core.NeedAppearancesFixture;
import digital.slovensko.autogram.core.PasswordManager;
import digital.slovensko.autogram.core.SignedDocument;
import digital.slovensko.autogram.core.SigningKey;
import digital.slovensko.autogram.core.errors.PINIncorrectException;
import digital.slovensko.autogram.drivers.TokenDriver;
import digital.slovensko.autogram.ui.machine.v2.VisibleSignatureAppearance;
import eu.europa.esig.dss.enumerations.ASiCContainerType;
import eu.europa.esig.dss.enumerations.Indication;
import eu.europa.esig.dss.enumerations.SignatureForm;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.simplereport.SimpleReport;
import eu.europa.esig.dss.simplereport.jaxb.XmlTimestamp;
import eu.europa.esig.dss.token.AbstractKeyStoreTokenConnection;
import eu.europa.esig.dss.token.Pkcs12SignatureToken;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.KeyStore;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.ZipInputStream;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MachineSigningServiceTest {
    @TempDir
    Path temporaryDirectory;

    @Test
    void uncheckedCleanupFailureClearsPinAndEmitsNoDuplicateTerminalEvents() throws Exception {
        var writer = new RecordingWriter();
        var pin = "1234".toCharArray();
        var fileSystem = new TrackingFileSystem();
        fileSystem.cleanupFailure = new AssertionError("unchecked cleanup detail");
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((input, completed) -> {
            input.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
            completed.run();
        }), content -> true, () -> { }, fileSystem);

        service.sign("request-1", request(pin, file("one", "source.pdf", "cleanup-error.pdf")));

        assertTrue(Arrays.equals(new char[pin.length], pin));
        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.failed"),
                writer.lifecycleEventTypes());
        assertEquals("OUTPUT_CLEANUP_FAILED", writer.payloadCode(3));
        assertFalse(writer.serialized().contains("unchecked cleanup detail"));
    }

    @Test
    void continuesAfterOneFileFails() throws Exception {
        var writer = new RecordingWriter();
        var session = new FakeSession((file, completed) -> {
            if (file.file().id().equals("bad")) {
                throw new IllegalStateException("sensitive failure");
            }
            file.writeSignedContent("%PDF-1.7\ngood\n%%EOF".getBytes());
            completed.run();
        });
        var service = new MachineSigningService(writer.writer(), request -> session, path -> true);
        var pin = "1234".toCharArray();

        service.sign("request-1", request(pin, file("bad", "bad.pdf", "bad-signed.pdf"),
                file("good", "good.pdf", "good-signed.pdf")));

        assertEquals(List.of("session.started", "file.signingStarted", "file.failed", "file.signingStarted",
                "file.completed", "session.completed"), writer.lifecycleEventTypes());
        assertTrue(session.closed);
        assertTrue(Arrays.equals(new char[pin.length], pin));
        assertFalse(writer.serialized().contains("sensitive failure"));
    }

    /// A timestamp authority that refuses the request (no contract, wrong credentials, down)
    /// used to surface as SIGNING_FAILED, so the app could not say what went wrong.
    @Test
    void aRefusedTimestampIsReportedAsTimestampFailed() throws Exception {
        var writer = new RecordingWriter();
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            throw new eu.europa.esig.dss.model.DSSException("Unable to sign",
                    new MachineProtocolException("TIMESTAMP_FAILED", new IllegalStateException("HTTP 401 from tsa")));
        }), path -> true);

        service.sign("request-1", request("1234".toCharArray(), file("one", "one.pdf", "one-signed.pdf")));

        assertEquals("TIMESTAMP_FAILED", writer.payloadCode(2));
        assertFalse(writer.serialized().contains("HTTP 401 from tsa"));
    }

    @Test
    void emitsProgressAtMachineSigningBoundaries() throws Exception {
        var writer = new RecordingWriter();
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
            completed.run();
        }), path -> true);

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", "signed.pdf")));

        assertEquals(List.of("preparing", "signing", "validating", "saving"), writer.progressPhases());
    }

    @Test
    void v1SigningDoesNotInitializeTrustedLists() throws Exception {
        var writer = new RecordingWriter();
        var target = target("signed.pdf");
        var trustInitialized = new AtomicBoolean();
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
            completed.run();
        }), content -> true, () -> trustInitialized.set(true));

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", target.getFileName().toString())));

        assertFalse(trustInitialized.get());
        assertTrue(Files.exists(target));
        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.completed"),
                writer.lifecycleEventTypes());
    }

    /// The trusted lists only judge the timestamp: when none loads, the visible signature is
    /// still made and published, and its timestamp is reported unverified.
    @Test
    void visibleSigningContinuesWhenNoTrustedListLoads() throws Exception {
        var writer = new RecordingWriter();
        var target = target("visible-signed.pdf");
        var inspection = new MachineInspectionService(path -> locallyValidTimestampReport("existing"), content ->
                new String(content, java.nio.charset.StandardCharsets.ISO_8859_1).contains("signed")
                        ? locallyValidTimestampReport("existing", "new") : locallyValidTimestampReport("existing"));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
            completed.run();
        }), new MachineSigningService.PdfOutputValidator(inspection, (content, signatureId) ->
                "new".equals(signatureId) ? "BE" : null),
                () -> { throw new MachineProtocolException("TRUSTED_LIST_UNAVAILABLE"); });

        service.sign("request-1", request("1234".toCharArray(),
                visibleFile("one", "visible-source.pdf", target.getFileName().toString())));

        assertTrue(Files.exists(target));
        assertEquals("unverified", writer.payloadString(2, "timestampQualification"));
        assertEquals("BE", writer.payloadString(2, "country"));
    }

    /// Without a timestamp there is nothing to judge, so the lists are never loaded.
    @Test
    void visibleBaselineBNeverLoadsTrustedLists() throws Exception {
        var writer = new RecordingWriter();
        var target = target("visible-baseline-b.pdf");
        var trustLoaded = new AtomicBoolean();
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
            completed.run();
        }), new MachineSigningService.OutputValidator() {
            @Override
            public boolean isValid(byte[] content) {
                return true;
            }
        }, () -> trustLoaded.set(true));

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "PAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(visibleFile("one", "visible-source.pdf", target.getFileName().toString()))));

        assertFalse(trustLoaded.get());
        assertTrue(Files.exists(target));
        assertEquals(null, writer.payloadString(2, "timestampQualification"));
    }

    @Test
    void deletesInvalidOutputBeforeReportingOutputValidationFailure() throws Exception {
        var writer = new RecordingWriter();
        var target = target("invalid-signed.pdf");
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\ninvalid\n%%EOF".getBytes());
            completed.run();
        }), path -> false);

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", target.getFileName().toString())));

        assertFalse(Files.exists(target));
        assertEquals("OUTPUT_VALIDATION_FAILED", writer.payloadCode(2));
        assertEquals(List.of("session.started", "file.signingStarted", "file.failed", "session.completed"),
                writer.lifecycleEventTypes());
    }

    @Test
    void reportsEveryFileWhenTokenSetupFailsAndClearsTheRequestPin() throws Exception {
        var writer = new RecordingWriter();
        var pin = "1234".toCharArray();
        var service = new MachineSigningService(writer.writer(), request -> {
            throw new IllegalStateException("token at /private/card 1234");
        }, path -> true);

        service.sign("request-1", request(pin, file("one", "one.pdf", "one-signed.pdf"),
                file("two", "two.pdf", "two-signed.pdf")));

        assertEquals(List.of("session.started", "file.signingStarted", "file.failed", "file.signingStarted",
                "file.failed", "session.failed"), writer.lifecycleEventTypes());
        assertTrue(Arrays.equals(new char[pin.length], pin));
        assertFalse(writer.serialized().contains("/private/card"));
        assertFalse(writer.serialized().contains("1234"));
    }

    @Test
    void reportsNestedIncorrectPinAsAStableFailureCode() throws Exception {
        var writer = new RecordingWriter();
        var service = new MachineSigningService(writer.writer(), request -> {
            throw new IllegalStateException(new PINIncorrectException());
        }, path -> true);

        service.sign("request-1", request("1234".toCharArray(), file("one", "one.pdf", "one-signed.pdf")));

        assertEquals("PIN_INCORRECT", writer.payloadCode(2));
    }

    @Test
    void emitsNoDuplicateFileEventsWhenSessionCloseFails() throws Exception {
        var writer = new RecordingWriter();
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\ngood\n%%EOF".getBytes());
            completed.run();
        }, true), path -> true);

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", "signed.pdf")));

        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.failed"),
                writer.lifecycleEventTypes());
    }

    @Test
    void responderWritesOnlyThroughTheRetainedStagingHandle() {
        var target = new MemoryRetainedFile();
        var responder = new MachineFileResponder(target, () -> { });

        responder.onDocumentSigned(new SignedDocument(new InMemoryDocument("replacement".getBytes()), null));

        assertEquals("replacement", new String(target.content));
    }

    @Test
    void completionCallbackFailureLeavesThePrivateOwnerToCleanItsTarget() throws Exception {
        var target = new MemoryRetainedFile();
        var responder = new MachineFileResponder(target, () -> {
            throw new IllegalStateException("callback failure");
        });

        assertThrows(MachineProtocolException.class,
                () -> responder.onDocumentSigned(new SignedDocument(new InMemoryDocument("replacement".getBytes()), null)));

        assertEquals("replacement", new String(target.content));
    }

    @Test
    void signingFailureNeverDeletesAConcurrentUserTarget() throws Exception {
        var writer = new RecordingWriter();
        var target = target("late-collision.pdf");
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            Files.writeString(target, "%PDF-1.7\nother process\n%%EOF");
            throw new IllegalStateException("late collision");
        }), path -> true);

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", target.getFileName().toString())));

        assertEquals("%PDF-1.7\nother process\n%%EOF", Files.readString(target));
        assertEquals("SIGNING_FAILED", writer.payloadCode(2));
    }

    @Test
    void signingFailureNeverDeletesAConcurrentUserSymlink() throws Exception {
        var writer = new RecordingWriter();
        var target = target("symlink-replacement.pdf");
        var unrelated = Files.writeString(target("unrelated.pdf"), "%PDF-1.7\nunrelated\n%%EOF");
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            Files.createSymbolicLink(target, unrelated);
            throw new IllegalStateException("late symlink");
        }), path -> true);

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", target.getFileName().toString())));

        assertTrue(Files.isSymbolicLink(target));
        assertEquals("%PDF-1.7\nunrelated\n%%EOF", Files.readString(unrelated));
        assertEquals("SIGNING_FAILED", writer.payloadCode(2));
    }

    @Test
    void signsAnOwnedSnapshotInsteadOfAPathReopenedAfterPreparation() throws Exception {
        var writer = new RecordingWriter();
        var source = Files.writeString(temporaryDirectory.resolve("source.pdf"), "%PDF-1.7\noriginal\n%%EOF");
        var target = target("signed.pdf");
        var sourceSeenBySigner = new AtomicReference<String>();
        var sessionOpened = new AtomicReference<Boolean>(false);
        var service = new MachineSigningService(writer.writer(), request -> {
            try {
                assertEquals("%PDF-1.7\noriginal\n%%EOF", Files.readString(source));
                Files.writeString(source, "%PDF-1.7\nreplaced\n%%EOF", StandardOpenOption.TRUNCATE_EXISTING);
            } catch (java.io.IOException exception) {
                throw new IllegalStateException(exception);
            }
            sessionOpened.set(true);
            return new FakeSession((file, completed) -> {
                sourceSeenBySigner.set(new String(file.sourceContent()));
                file.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
                completed.run();
            });
        }, path -> true);

        service.sign("request-1", request("1234".toCharArray(),
                new MachineFile("one", source.toRealPath().toString(), target.toString())));

        assertTrue(sessionOpened.get());
        assertEquals("%PDF-1.7\noriginal\n%%EOF", sourceSeenBySigner.get());
        assertEquals("%PDF-1.7\nsigned\n%%EOF", Files.readString(target));
    }

    @Test
    void publishesOnlyAfterRealPdfOutputValidationSucceeds() throws Exception {
        var writer = new RecordingWriter();
        var target = target("published-after-validation.pdf");
        var targetSeenDuringSigning = new AtomicReference<Boolean>();
        var inspection = new MachineInspectionService(path -> qualifiedReport(), content ->
                new String(content, java.nio.charset.StandardCharsets.ISO_8859_1).contains("signed")
                        ? qualifiedReport("new") : qualifiedReport());
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            targetSeenDuringSigning.set(Files.exists(target));
            file.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
            completed.run();
        }), new MachineSigningService.PdfOutputValidator(inspection));

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", target.getFileName().toString())));

        assertFalse(targetSeenDuringSigning.get());
        assertEquals("%PDF-1.7\nsigned\n%%EOF", Files.readString(target));
        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.completed"),
                writer.lifecycleEventTypes());
    }

    @Test
    void validationFailureNeverDeletesAConcurrentUserTargetReplacement() throws Exception {
        var writer = new RecordingWriter();
        var target = target("concurrent-user-target.pdf");
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\ninvalid\n%%EOF".getBytes());
            completed.run();
        }), path -> {
            Files.writeString(target, "%PDF-1.7\nuser-replacement\n%%EOF");
            return false;
        });

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", target.getFileName().toString())));

        assertEquals("%PDF-1.7\nuser-replacement\n%%EOF", Files.readString(target));
        assertEquals("OUTPUT_VALIDATION_FAILED", writer.payloadCode(2));
    }

    @Test
    void validationFailurePreservesAReplacementAndReportsAnExplicitCleanupFailure() throws Exception {
        var writer = new RecordingWriter();
        var target = target("replaced.pdf");
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\ninvalid\n%%EOF".getBytes());
            completed.run();
        }), content -> {
            Files.writeString(target, "%PDF-1.7\nreplacement\n%%EOF");
            return false;
        });

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", target.getFileName().toString())));

        assertEquals("%PDF-1.7\nreplacement\n%%EOF", Files.readString(target));
        assertEquals("OUTPUT_VALIDATION_FAILED", writer.payloadCode(2));
    }

    @Test
    void validationExceptionDeletesOnlyTheOwnedOutputAndReportsValidationFailure() throws Exception {
        var writer = new RecordingWriter();
        var target = target("validator-threw.pdf");
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
            completed.run();
        }), path -> {
            throw new java.io.IOException("report unavailable");
        });

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", target.getFileName().toString())));

        assertFalse(Files.exists(target));
        assertEquals("OUTPUT_VALIDATION_FAILED", writer.payloadCode(2));
    }

    @Test
    void preparationCleanupFailureIsReportedBeforeTokenWork() throws Exception {
        var writer = new RecordingWriter();
        var tokenOpened = new AtomicBoolean();
        var nativeFiles = MacNativeFileSystem.createForCurrentPlatform();
        var service = new MachineSigningService(writer.writer(), request -> {
            tokenOpened.set(true);
            throw new AssertionError("Token must not open after preparation cleanup failure");
        }, content -> true, () -> { }, new MachineSigningFileSystem() {
            @Override
            public RetainedFile openSource(Path source) throws java.io.IOException {
                return nativeFiles.openSource(source);
            }

            @Override
            public Workspace createWorkspace(Path targetParent) {
                return failingWorkspace(false);
            }
        });

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", "target.pdf")));

        assertFalse(tokenOpened.get());
        assertEquals(List.of("session.started", "file.signingStarted", "file.failed", "session.failed"),
                writer.lifecycleEventTypes());
        assertEquals("OUTPUT_CLEANUP_FAILED", writer.payloadCode(2));
    }

    @Test
    void identitySetupFailureCleansThePreparedSourceBeforeTokenWork() throws Exception {
        var writer = new RecordingWriter();
        var tokenOpened = new AtomicBoolean();
        var sourceClosed = new AtomicBoolean();
        var service = new MachineSigningService(writer.writer(), request -> {
            tokenOpened.set(true);
            throw new AssertionError("Token must not open after source setup failure");
        }, content -> true, () -> { }, new MachineSigningFileSystem() {
            @Override
            public RetainedFile openSource(Path source) {
                return new MemoryRetainedFile("%PDF-1.7\nsource\n%%EOF".getBytes()) {
                    @Override
                    public void close() {
                        sourceClosed.set(true);
                    }
                };
            }

            @Override
            public Workspace createWorkspace(Path targetParent) {
                throw new IllegalStateException("identity capture failed");
            }
        });

        service.sign("request-1", request("1234".toCharArray(), file("one", "source.pdf", "target.pdf")));

        assertFalse(tokenOpened.get());
        assertTrue(sourceClosed.get());
        assertEquals("SIGNING_UNAVAILABLE", writer.payloadCode(2));
    }

    @Test
    void rejectsNonPdfSourceDuringSingleOpenPreparationBeforeTokenWork() throws Exception {
        var writer = new RecordingWriter();
        var source = Files.writeString(temporaryDirectory.resolve("not-pdf.pdf"), "not a PDF").toRealPath();
        var target = target("not-pdf-signed.pdf");
        var tokenOpened = new AtomicBoolean();
        var service = new MachineSigningService(writer.writer(), request -> {
            tokenOpened.set(true);
            throw new AssertionError("Token must not open for a non-PDF source");
        }, content -> true);

        service.sign("request-1", request("1234".toCharArray(),
                new MachineFile("one", source.toString(), target.toString())));

        assertFalse(tokenOpened.get());
        assertFalse(Files.exists(target));
        assertEquals("SIGNING_UNAVAILABLE", writer.payloadCode(2));
    }

    @Test
    void outputValidatorAcceptsOnlyANewFullyQualifiedBaselineTSignature() throws Exception {
        var target = Files.writeString(target("validated.pdf"), "%PDF-1.7\nvalidated\n%%EOF");
        var rejected = Files.writeString(target("rejected.pdf"), "%PDF-1.7\nrejected\n%%EOF");
        var existing = qualifiedReport("existing");
        var added = qualifiedReport("existing", "new");
        var invalidNew = qualifiedReport("existing", "new");
        when(invalidNew.isValid("new")).thenReturn(false);
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService(path -> existing,
                content -> new String(content, java.nio.charset.StandardCharsets.ISO_8859_1).contains("before")
                        ? existing : new String(content, java.nio.charset.StandardCharsets.ISO_8859_1).contains("rejected")
                                ? invalidNew : added));
        var before = "%PDF-1.7\nbefore\n%%EOF".getBytes(java.nio.charset.StandardCharsets.ISO_8859_1);

        assertEquals(java.util.Set.of("existing"), validator.signatureIds(before));
        assertTrue(validator.isValid(Files.readAllBytes(target), java.util.Set.of("existing")));
        assertFalse(validator.isValid(Files.readAllBytes(rejected), java.util.Set.of("existing")));
        assertFalse(validator.isValid(Files.readAllBytes(target), java.util.Set.of("existing", "new")));
    }

    /// An unqualified timestamp (time.certum.pl) no longer throws the signature away: it is
    /// published and the result says the timestamp is not qualified.
    @Test
    void anUnqualifiedTimestampIsPublishedAndReported() throws Exception {
        var writer = new RecordingWriter();
        var target = target("timestamp-unqualified.pdf");
        var inspection = new MachineInspectionService(path -> locallyValidTimestampReport("existing"), content ->
                new String(content, java.nio.charset.StandardCharsets.ISO_8859_1).contains("signed")
                        ? locallyValidTimestampReport("existing", "new") : locallyValidTimestampReport("existing"));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
            completed.run();
        }), new MachineSigningService.PdfOutputValidator(inspection));

        service.sign("request-1", request("1234".toCharArray(),
                visibleFile("one", "source.pdf", target.getFileName().toString())));

        assertTrue(Files.exists(target));
        assertEquals("notQualified", writer.payloadString(2, "timestampQualification"));
        assertEquals(null, writer.payloadString(2, "country"));
    }

    /// tsl.belgium.be was down on 2026-10-02 and 03: a BOSA timestamp cannot be shown
    /// qualified without the Belgian list, so the result says unverified and names the
    /// country, and the signature is kept.
    @Test
    void aTimestampWhoseNationalListIsMissingIsReportedUnverified() throws Exception {
        var writer = new RecordingWriter();
        var target = target("timestamp-anchor-missing.pdf");
        var inspection = new MachineInspectionService(path -> locallyValidTimestampReport("existing"), content ->
                new String(content, java.nio.charset.StandardCharsets.ISO_8859_1).contains("signed")
                        ? locallyValidTimestampReport("existing", "new") : locallyValidTimestampReport("existing"));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((file, completed) -> {
            file.writeSignedContent("%PDF-1.7\nsigned\n%%EOF".getBytes());
            completed.run();
        }), new MachineSigningService.PdfOutputValidator(inspection, (content, signatureId) ->
                "new".equals(signatureId) ? "BE" : null));

        service.sign("request-1", request("1234".toCharArray(),
                visibleFile("one", "source.pdf", target.getFileName().toString())));

        assertTrue(Files.exists(target));
        assertEquals("unverified", writer.payloadString(2, "timestampQualification"));
        assertEquals("BE", writer.payloadString(2, "country"));
        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.completed"),
                writer.lifecycleEventTypes());
    }

    @Test
    void anUnqualifiedTimestampWithItsListAvailableStaysUnqualified() {
        var report = locallyValidTimestampReport("new");
        var consulted = new AtomicBoolean();
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService(path -> report,
                content -> report), (content, signatureId) -> {
                    consulted.set(true);
                    return null;
                });
        var output = "%PDF-1.7\nvalidated\n%%EOF".getBytes(java.nio.charset.StandardCharsets.ISO_8859_1);

        assertEquals(null, validator.validationFailure(output, java.util.Set.of(), true));
        assertEquals("notQualified",
                validator.timestampQualification(output, java.util.Set.of(), true, "PAdES_BASELINE_T"));
        assertTrue(consulted.get());
    }

    @Test
    void aQualifiedTimestampNeverAsksForItsTrustAnchor() {
        var report = qualifiedReport("new");
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService(path -> report,
                content -> report), (content, signatureId) -> {
                    throw new AssertionError("a qualified timestamp needs no anchor lookup");
                });
        var output = "%PDF-1.7\nvalidated\n%%EOF".getBytes(java.nio.charset.StandardCharsets.ISO_8859_1);

        assertEquals(null, validator.validationFailure(output, java.util.Set.of(), true));
        assertEquals("qualified",
                validator.timestampQualification(output, java.util.Set.of(), true, "PAdES_BASELINE_T"));
    }

    @Test
    void theCompletionPayloadSplitsTheCountry() {
        assertEquals("{}", MachineSigningService.completion(null).toString());
        assertEquals("{\"timestampQualification\":\"qualified\"}",
                MachineSigningService.completion("qualified").toString());
        assertEquals("{\"timestampQualification\":\"unverified\",\"country\":\"BE\"}",
                MachineSigningService.completion("unverified:BE").toString());
    }

    @Test
    void productionTrustedInspectionAllowsQualifiedVisiblePadesPublication() {
        var inspection = MachineInspectionService.forTrustedValidation(ignored -> qualifiedReport("new"));
        var validator = new MachineSigningService.PdfOutputValidator(inspection);
        var output = "%PDF-1.7\nvalidated\n%%EOF".getBytes(java.nio.charset.StandardCharsets.ISO_8859_1);

        assertEquals(null, validator.validationFailure(output, java.util.Set.of(), true));
    }

    @Test
    void visiblePublicationRequiresPadesWhileV1KeepsBaselineTFormats() {
        var report = qualifiedReport("new");
        when(report.getSignatureFormat("new")).thenReturn(SignatureLevel.XAdES_BASELINE_T);
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService(path -> report,
                content -> report));
        var output = "%PDF-1.7\nvalidated\n%%EOF".getBytes(java.nio.charset.StandardCharsets.ISO_8859_1);

        assertEquals("OUTPUT_VALIDATION_FAILED", validator.validationFailure(output, java.util.Set.of(), true));
        assertEquals(null, validator.validationFailure(output, java.util.Set.of(), false));
    }

    /// nove.slovensko.sk asks for XAdES Baseline B around a PDF and rejects a
    /// signature with a timestamp it did not ask for. Such an output carries no
    /// timestamp, so only its level and cryptographic integrity can be checked.
    @Test
    void portalBaselineBOutputNeedsNoTimestampButTheRequestedLevel() {
        var report = mock(SimpleReport.class);
        when(report.getSignatureIdList()).thenReturn(List.of("new"));
        when(report.getSignatureFormat("new")).thenReturn(SignatureLevel.XAdES_BASELINE_B);
        when(report.isValid("new")).thenReturn(true);
        when(report.getIndication("new")).thenReturn(Indication.TOTAL_PASSED);
        when(report.getSignatureTimestamps("new")).thenReturn(List.of());
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService(path -> report,
                content -> report));
        var asice = new byte[] { 'P', 'K', 3, 4, 0, 0, 0, 0 };

        assertEquals(null, validator.validationFailure(asice, java.util.Set.of(), false, "XAdES_BASELINE_B"));
        assertEquals("OUTPUT_VALIDATION_FAILED",
                validator.validationFailure(asice, java.util.Set.of(), false, "XAdES_BASELINE_T"));
    }

    /// The qualified Baseline T route around a signed PDF: one new qualified signature in
    /// the container, which must carry the source unchanged. A second container signature
    /// or another document is refused.
    @Test
    void wrappedSignedSourceKeepsTheQualifiedBaselineTChecks() throws Exception {
        var container = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_pdf_xades.asice").getFile()));
        var unsigned = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));
        var signed = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_signed.pdf").getFile()));
        var one = qualifiedReport("new");
        when(one.getSignatureFormat("new")).thenReturn(SignatureLevel.XAdES_BASELINE_T);
        var two = qualifiedReport("other", "new");
        var validator = new MachineSigningService.PdfOutputValidator(MachineInspectionService.forTrustedValidation(
                ignored -> one));
        var twoSignatures = new MachineSigningService.PdfOutputValidator(MachineInspectionService.forTrustedValidation(
                ignored -> two));

        assertEquals(null, validator.wrappedSourceValidationFailure(container, unsigned, false, "XAdES_BASELINE_T"));
        assertEquals("OUTPUT_VALIDATION_FAILED",
                validator.wrappedSourceValidationFailure(container, signed, false, "XAdES_BASELINE_T"));
        assertEquals("OUTPUT_VALIDATION_FAILED",
                validator.wrappedSourceValidationFailure(container, unsigned, true, "XAdES_BASELINE_T"));
        assertEquals("OUTPUT_VALIDATION_FAILED",
                twoSignatures.wrappedSourceValidationFailure(container, unsigned, false, "XAdES_BASELINE_T"));
        assertEquals("OUTPUT_VALIDATION_FAILED",
                validator.wrappedSourceValidationFailure(signed, signed, false, "XAdES_BASELINE_T"));
    }

    @Test
    void portalBaselineBOutputStillRejectsABrokenSignature() {
        var report = mock(SimpleReport.class);
        when(report.getSignatureIdList()).thenReturn(List.of("new"));
        when(report.getSignatureFormat("new")).thenReturn(SignatureLevel.XAdES_BASELINE_B);
        when(report.isValid("new")).thenReturn(false);
        when(report.getIndication("new")).thenReturn(Indication.TOTAL_FAILED);
        when(report.getSignatureTimestamps("new")).thenReturn(List.of());
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService(path -> report,
                content -> report));
        var asice = new byte[] { 'P', 'K', 3, 4, 0, 0, 0, 0 };

        assertEquals("OUTPUT_VALIDATION_FAILED",
                validator.validationFailure(asice, java.util.Set.of(), false, "XAdES_BASELINE_B"));
    }

    @Test
    void outputValidatorRejectsSymlinkPaths() throws Exception {
        var document = Files.writeString(target("regular.pdf"), "%PDF-1.7\nregular\n%%EOF");
        var link = target("linked.pdf");
        Files.createSymbolicLink(link, document);
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService(path -> qualifiedReport(),
                content -> qualifiedReport("new")));

        assertThrows(java.io.IOException.class, () -> validator.isValid(link, java.util.Set.of()));
    }

    /// An eID signing slot holds one qualified signing key. Reading the certificates
    /// first costs the person a BOK entry, so the app may ask for "the signing key"
    /// instead of a serial.
    @Test
    void anySerialPicksTheOnlyNonRepudiationKey() {
        var signing = key(true);
        var other = key(false);

        assertSame(signing, MachineSigningService.DefaultSigningSession.selectedKey(List.of(other, signing),
                MachineSigningService.SIGNING_KEY_ON_TOKEN));
        assertSame(other, MachineSigningService.DefaultSigningSession.selectedKey(List.of(other),
                MachineSigningService.SIGNING_KEY_ON_TOKEN));
    }

    @Test
    void anySerialRefusesToGuessBetweenSigningKeys() {
        var failure = assertThrows(MachineProtocolException.class,
                () -> MachineSigningService.DefaultSigningSession.selectedKey(List.of(key(true), key(true)),
                        MachineSigningService.SIGNING_KEY_ON_TOKEN));
        assertEquals("CERTIFICATE_AMBIGUOUS", failure.getMessage());

        var none = assertThrows(MachineProtocolException.class,
                () -> MachineSigningService.DefaultSigningSession.selectedKey(List.of(),
                        MachineSigningService.SIGNING_KEY_ON_TOKEN));
        assertEquals("CERTIFICATE_NOT_FOUND", none.getMessage());
    }

    private static eu.europa.esig.dss.token.DSSPrivateKeyEntry key(boolean nonRepudiation) {
        var certificate = mock(eu.europa.esig.dss.model.x509.CertificateToken.class);
        when(certificate.checkKeyUsage(eu.europa.esig.dss.enumerations.KeyUsageBit.NON_REPUDIATION))
                .thenReturn(nonRepudiation);
        var key = mock(eu.europa.esig.dss.token.DSSPrivateKeyEntry.class);
        when(key.getCertificate()).thenReturn(certificate);
        return key;
    }

    @Test
    void defaultSessionFactorySelectsExactlyOneSerialAndClosesOneToken() throws Exception {
        var driver = new TestTokenDriver("test");
        var request = request("1234".toCharArray(), file("one", "source.pdf", "signed.pdf"));
        var serial = driver.serial();
        request = new SignRequest("test", serial, request.pin(), request.signatureLevel(), request.timestamp(), request.files());
        var factory = new MachineSigningService.DefaultSessionFactory(() -> List.of(driver), new MachineSettings(true),
                PasswordManager::new);

        try (var session = factory.apply(request)) {
            assertTrue(driver.created);
        }

        assertEquals(1, driver.closeCount());
    }

    @Test
    void defaultSessionFactoryRejectsAmbiguousSerialBeforeReturningASession() throws Exception {
        var driver = new TestTokenDriver("test", true);
        var request = request("1234".toCharArray(), file("one", "source.pdf", "signed.pdf"));
        var ambiguousRequest = new SignRequest("test", driver.serial(), request.pin(), request.signatureLevel(),
                request.timestamp(), request.files());
        var factory = new MachineSigningService.DefaultSessionFactory(() -> List.of(driver), new MachineSettings(true),
                PasswordManager::new);

        var failure = assertThrows(MachineProtocolException.class, () -> factory.apply(ambiguousRequest));

        assertEquals("CERTIFICATE_AMBIGUOUS", failure.getMessage());
        assertEquals(1, driver.closeCount());
    }

    @Test
    void failedPasswordManagerConstructionClosesAndZeroizesMachineSecretUi() {
        var capturedUi = new AtomicReference<MachineSecretUI>();
        var issuedSecret = new AtomicReference<char[]>();
        var request = new SignRequest("test", "123", "1234".toCharArray(), "PAdES_BASELINE_T",
                new QualifiedTimestampRequest(true, List.of("https://tsa.example.test")), List.of());

        assertThrows(IllegalStateException.class, () -> MachineSigningService.DefaultSigningSession.open(
                new TestTokenDriver("test"), request, new MachineSettings(true), (ui, settings) -> {
                    capturedUi.set(ui);
                    issuedSecret.set(ui.getKeystorePassword());
                    throw new IllegalStateException("factory failure");
                }));

        assertTrue(capturedUi.get().isClosed());
        assertTrue(Arrays.equals(new char[issuedSecret.get().length], issuedSecret.get()));
    }

    @Test
    void errorDuringPasswordManagerConstructionStillZeroizesMachineSecretUi() {
        var capturedUi = new AtomicReference<MachineSecretUI>();
        var issuedSecret = new AtomicReference<char[]>();
        var request = new SignRequest("test", "123", "1234".toCharArray(), "PAdES_BASELINE_T",
                new QualifiedTimestampRequest(true, List.of("https://tsa.example.test")), List.of());

        assertThrows(AssertionError.class, () -> MachineSigningService.DefaultSigningSession.open(
                new TestTokenDriver("test"), request, new MachineSettings(true), (ui, settings) -> {
                    capturedUi.set(ui);
                    issuedSecret.set(ui.getKeystorePassword());
                    throw new AssertionError("factory error");
                }));

        assertTrue(capturedUi.get().isClosed());
        assertTrue(Arrays.equals(new char[issuedSecret.get().length], issuedSecret.get()));
    }

    private static final String PROBE_NS = "http://probe.local/form/1.0";

    private static String probeForm() {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<Ziadost xmlns=\"" + PROBE_NS + "\"><Meno>Test</Meno></Ziadost>";
    }

    private static String probeSchema() {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\" xmlns=\"" + PROBE_NS + "\" "
                + "targetNamespace=\"" + PROBE_NS + "\" elementFormDefault=\"qualified\">"
                + "<xs:element name=\"Ziadost\"><xs:complexType><xs:sequence>"
                + "<xs:element name=\"Meno\" type=\"xs:string\"/>"
                + "</xs:sequence></xs:complexType></xs:element></xs:schema>";
    }

    private static String probeTransformation() {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<xsl:stylesheet version=\"1.0\" xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\" "
                + "xmlns:z=\"" + PROBE_NS + "\"><xsl:template match=\"/\"><html><body><h1>"
                + "<xsl:value-of select=\"z:Ziadost/z:Meno\"/></h1></body></html></xsl:template></xsl:stylesheet>";
    }

    private static String base64(String value) {
        return java.util.Base64.getEncoder().encodeToString(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    /**
     * The namespace is deliberately not a government one, so no live UPVS, ORSR or
     * FS registry lookup happens and the request's own schema and transformation
     * are used. Keeps the test hermetic.
     */
    @Test
    void signingJobBuildsAnXmlDataContainerFromEFormAttributes() throws Exception {
        var source = temporaryDirectory.resolve("probe-form.xml");
        Files.writeString(source, probeForm());
        var responder = new MachineFileResponder(new MemoryRetainedFile(), () -> { });
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        settings.setEform(new EFormRequest(
                "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
                base64(probeSchema()),
                base64(probeTransformation()),
                PROBE_NS,
                null, null, "sk", "HTML", "probe",
                true, false, null, null));

        var job = MachineSigningService.DefaultSigningSession.signingJob(Files.readAllBytes(source), source.toString(),
                responder, settings);

        assertEquals(SignatureLevel.XAdES_BASELINE_B, job.getParameters().getLevel());
        assertEquals(ASiCContainerType.ASiC_E, job.getParameters().getContainer());
        try (var stream = job.getDocument().openStream()) {
            var content = new String(stream.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
            assertTrue(content.contains("XMLDataContainer"), "expected an XML Data Container, got: " + content);
            assertTrue(content.contains("UsedXSDEmbedded"), "expected the schema to be embedded");
            assertTrue(content.contains("<Meno>Test</Meno>"), "expected the form payload to survive");
        }
    }

    /// A portal's finished container (D.Signer addXmlObject2) comes as an .xdcf with the
    /// portal's schema and transformation and embedUsedSchemas, as upstream autogram-extension
    /// sends it. It is validated and signed as it is: one data object, never wrapped again.
    /// The container embeds its schemas, so nothing is looked up online.
    @Test
    void aReadyMadeXmlDataContainerFromAPortalIsSignedAsItIs() throws Exception {
        // A portal's stylesheet names its output; addXmlObject2 passes no destination type.
        var transformation = probeTransformation().replace("<xsl:template", "<xsl:output method=\"html\"/><xsl:template");
        var eform = new EFormRequest(
                "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
                base64(probeSchema()),
                base64(transformation),
                PROBE_NS,
                null, null, "sk", "HTML", "probe",
                true, false, null, null);
        var buildSettings = new MachineSettings(true);
        buildSettings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        buildSettings.setEform(eform);
        var built = MachineSigningService.DefaultSigningSession.signingJob(
                probeForm().getBytes(java.nio.charset.StandardCharsets.UTF_8), "/tmp/probe-form.xml",
                new MachineFileResponder(new MemoryRetainedFile(), () -> { }), buildSettings);
        byte[] xdc;
        try (var stream = built.getDocument().openStream()) {
            xdc = stream.readAllBytes();
        }

        var retained = new MemoryRetainedFile();
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        settings.setEform(new EFormRequest(
                "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
                base64(probeSchema()),
                base64(transformation),
                PROBE_NS,
                null, null, null, null, null,
                true, false, null, "ENVELOPING"));
        var job = MachineSigningService.DefaultSigningSession.signingJob(xdc, "/tmp/form-object.xdcf",
                new MachineFileResponder(retained, () -> { }), settings);
        try (var stream = job.getDocument().openStream()) {
            assertArrayEquals(xdc, stream.readAllBytes(), "the portal's container must be signed unchanged");
        }
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        job.signWithKeyAndRespond(new SigningKey(token, token.getKeys().get(0)));

        var names = new ArrayList<String>();
        String manifest = null;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(retained.readAll()))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                names.add(entry.getName());
                var content = new String(zip.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
                if (entry.getName().equals("META-INF/manifest.xml")) manifest = content;
            }
        }
        assertEquals(1, names.stream().filter(name -> !name.equals("mimetype") && !name.startsWith("META-INF/")).count(),
                names.toString());
        assertTrue(names.contains("form-object.xdcf"), names.toString());
        assertTrue(manifest.contains("manifest:full-path=\"form-object.xdcf\" manifest:media-type=\"application/vnd.gov.sk.xmldatacontainer+xml"),
                manifest);
    }

    /// Several documents of one portal signature: plain text and an image next to the PDF.
    @Test
    void textAndImageAttachmentsKeepTheirMediaTypes() throws Exception {
        var pdf = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));
        var png = java.util.Base64.getDecoder().decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==");
        var retained = new MemoryRetainedFile();
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);

        var job = MachineSigningService.DefaultSigningSession.signingJob(pdf, "/tmp/priloha.pdf",
                new MachineFileResponder(retained, () -> { }), settings, null, List.of(
                        new MachineSigningService.AttachmentContent("poznamka.txt",
                                "Hello".getBytes(java.nio.charset.StandardCharsets.UTF_8)),
                        new MachineSigningService.AttachmentContent("obrazok.png", png)));
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        job.signWithKeyAndRespond(new SigningKey(token, token.getKeys().get(0)));

        String manifest = null;
        String signature = null;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(retained.readAll()))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                var content = new String(zip.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
                if (entry.getName().equals("META-INF/manifest.xml")) manifest = content;
                if (entry.getName().startsWith("META-INF/signatures")) signature = content;
            }
        }
        assertTrue(manifest.contains("manifest:full-path=\"poznamka.txt\" manifest:media-type=\"text/plain"), manifest);
        assertTrue(manifest.contains("manifest:full-path=\"obrazok.png\" manifest:media-type=\"image/png\""), manifest);
        for (var name : List.of("priloha.pdf", "poznamka.txt", "obrazok.png")) {
            assertTrue(signature.contains("URI=\"" + name + "\""), name + " in " + signature);
        }
    }

    /// Financna sprava forms carry no target namespace and a TXT (text-output) stylesheet,
    /// like the DPH form. The XDC build must handle that shape with referenced schemas.
    @Test
    void signingJobBuildsAnXmlDataContainerFromFsShapedEForm() throws Exception {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<dokument><hlavicka><dic>1084791499</dic></hlavicka></dokument>";
        var xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<xsd:schema xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" elementFormDefault=\"qualified\">"
                + "<xsd:element name=\"dokument\"><xsd:complexType><xsd:sequence>"
                + "<xsd:element name=\"hlavicka\"><xsd:complexType><xsd:sequence>"
                + "<xsd:element name=\"dic\" type=\"xsd:string\"/>"
                + "</xsd:sequence></xsd:complexType></xsd:element>"
                + "</xsd:sequence></xsd:complexType></xsd:element></xsd:schema>";
        var xslt = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<xsl:stylesheet version=\"1.0\" xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\">"
                + "<xsl:output method=\"text\" omit-xml-declaration=\"yes\" encoding=\"utf-8\"/>"
                + "<xsl:template match=\"/\">DIC:<xsl:value-of select=\"/dokument/hlavicka/dic\"/>"
                + "</xsl:template></xsl:stylesheet>";
        var source = temporaryDirectory.resolve("Object1279.xml");
        Files.writeString(source, xml);
        var responder = new MachineFileResponder(new MemoryRetainedFile(), () -> { });
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        settings.setEform(new EFormRequest(
                "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
                base64(xsd),
                base64(xslt),
                "https://ekr.financnasprava.sk/xdc/DPHv25/1.0",
                "https://ekr.financnasprava.sk/Formulare/XSD/dph2025.xsd",
                "https://pfseform.financnasprava.sk/Formulare/eFormVzor/DP/form.616.sb.xslt",
                null, "TXT", null,
                false, false, null, "ENVELOPING"));

        var job = MachineSigningService.DefaultSigningSession.signingJob(Files.readAllBytes(source), source.toString(),
                responder, settings);

        assertEquals(SignatureLevel.XAdES_BASELINE_B, job.getParameters().getLevel());
        assertEquals(ASiCContainerType.ASiC_E, job.getParameters().getContainer());
        try (var stream = job.getDocument().openStream()) {
            var content = new String(stream.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
            assertTrue(content.contains("XMLDataContainer"), "expected an XML Data Container, got: " + content);
            assertTrue(content.contains("UsedXSDReference"), "expected the schema to be referenced");
            assertTrue(content.contains("<dic>1084791499</dic>"), "expected the form payload to survive");
        }
    }

    /// ZaKo hands the PDF/A and the clause XDC as two documents. They must become two data
    /// objects of one ASiC-E, never a container nested inside another.
    @Test
    void attachmentsAreSignedAsDataObjectsOfOneContainer() throws Exception {
        var pdf = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));
        var xdcf = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><XMLDataContainer xmlns=\"http://data.gov.sk/def/container/xmldatacontainer+xml/1.1\"/>"
                .getBytes(java.nio.charset.StandardCharsets.UTF_8);
        var retained = new MemoryRetainedFile();
        var responder = new MachineFileResponder(retained, () -> { });
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);

        var job = MachineSigningService.DefaultSigningSession.signingJob(pdf, "/tmp/dokument.pdf", responder, settings,
                null, List.of(new MachineSigningService.AttachmentContent("dokument.xml.xdcf", xdcf)));
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        job.signWithKeyAndRespond(new SigningKey(token, token.getKeys().get(0)));

        var names = new ArrayList<String>();
        String manifest = null;
        String signature = null;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(retained.readAll()))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                names.add(entry.getName());
                var content = new String(zip.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
                if (entry.getName().equals("META-INF/manifest.xml")) manifest = content;
                if (entry.getName().startsWith("META-INF/signatures")) signature = content;
            }
        }
        assertTrue(names.contains("dokument.pdf"), names.toString());
        assertTrue(names.contains("dokument.xml.xdcf"), names.toString());
        assertTrue(names.stream().noneMatch(name -> name.endsWith(".asice")), names.toString());
        assertTrue(manifest.contains("manifest:full-path=\"dokument.xml.xdcf\" manifest:media-type=\"application/vnd.gov.sk.xmldatacontainer+xml\""), manifest);
        assertTrue(signature.contains("URI=\"dokument.pdf\""), signature);
        assertTrue(signature.contains("URI=\"dokument.xml.xdcf\""), signature);
    }

    /// A real advocate names a source with a space and a diacritic. The ZIP entry names and the
    /// signature's references must survive that exactly, whatever percent-encoding DSS applies.
    @Test
    void attachmentsWithSpaceAndDiacriticAreSignedAsDataObjectsOfOneContainer() throws Exception {
        var pdf = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));
        var xdcf = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><XMLDataContainer xmlns=\"http://data.gov.sk/def/container/xmldatacontainer+xml/1.1\"/>"
                .getBytes(java.nio.charset.StandardCharsets.UTF_8);
        var retained = new MemoryRetainedFile();
        var responder = new MachineFileResponder(retained, () -> { });
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);

        var sourceName = "Zmluva o dielo č. 3.pdf";
        var attachmentName = "Zmluva o dielo č. 3.xml.xdcf";
        var job = MachineSigningService.DefaultSigningSession.signingJob(pdf, "/tmp/" + sourceName, responder, settings,
                null, List.of(new MachineSigningService.AttachmentContent(attachmentName, xdcf)));
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        job.signWithKeyAndRespond(new SigningKey(token, token.getKeys().get(0)));

        var names = new ArrayList<String>();
        String signature = null;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(retained.readAll()))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                names.add(java.text.Normalizer.normalize(entry.getName(), java.text.Normalizer.Form.NFC));
                var content = new String(zip.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
                if (entry.getName().startsWith("META-INF/signatures")) signature = content;
            }
        }
        var normalizedSourceName = java.text.Normalizer.normalize(sourceName, java.text.Normalizer.Form.NFC);
        var normalizedAttachmentName = java.text.Normalizer.normalize(attachmentName, java.text.Normalizer.Form.NFC);
        assertTrue(names.contains(normalizedSourceName), names.toString());
        assertTrue(names.contains(normalizedAttachmentName), names.toString());
        assertTrue(names.stream().noneMatch(name -> name.endsWith(".asice")), names.toString());
        assertTrue(referencesFile(signature, sourceName), signature);
        assertTrue(referencesFile(signature, attachmentName), signature);
    }

    /// True when `signatureXml` carries a `dsig:Reference` URI for `fileName`, whether DSS wrote
    /// it plain or percent-encoded; both forms are normalised to NFC before comparison because a
    /// diacritic can be composed differently depending on the encoding step.
    private static boolean referencesFile(String signatureXml, String fileName) {
        var normalizedName = java.text.Normalizer.normalize(fileName, java.text.Normalizer.Form.NFC);
        var normalizedXml = java.text.Normalizer.normalize(signatureXml, java.text.Normalizer.Form.NFC);
        if (normalizedXml.contains("URI=\"" + normalizedName + "\"")) return true;
        var decodedXml = java.text.Normalizer.normalize(
                java.net.URLDecoder.decode(signatureXml, java.nio.charset.StandardCharsets.UTF_8),
                java.text.Normalizer.Form.NFC);
        return decodedXml.contains("URI=\"" + normalizedName + "\"");
    }

    /// The whole path Task 8 drives: validation, reading the attachment, a real signature, the
    /// output check of the two-object container and publishing it.
    @Test
    void signsAndPublishesASourceWithItsAttachmentThroughTheService() throws Exception {
        var writer = new RecordingWriter();
        var source = Files.copy(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()),
                temporaryDirectory.resolve("dokument.pdf")).toRealPath();
        var attachment = Files.writeString(temporaryDirectory.resolve("dokument.xml.xdcf"),
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><XMLDataContainer xmlns=\"http://data.gov.sk/def/container/xmldatacontainer+xml/1.1\"/>")
                .toRealPath();
        var target = target("dokument.asice");
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        var key = new SigningKey(token, token.getKeys().get(0));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((input, completed) ->
                MachineSigningService.DefaultSigningSession.signingJob(input.sourceContent(), input.file().source(),
                        new MachineFileResponder(input.staging(), completed), settings, null, input.attachments())
                        .signWithKeyAndRespond(key)),
                new MachineSigningService.PdfOutputValidator(new MachineInspectionService()));

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", source.toString(), target.toString(), null, List.of(attachment.toString())))));

        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.completed"),
                writer.lifecycleEventTypes());
        var names = new ArrayList<String>();
        try (var zip = new ZipInputStream(Files.newInputStream(target))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                names.add(entry.getName());
            }
        }
        assertTrue(names.containsAll(List.of("dokument.pdf", "dokument.xml.xdcf")), names.toString());
        assertTrue(names.stream().noneMatch(name -> name.endsWith(".asice")), names.toString());
    }

    private static final String RECORD_XDC = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><XMLDataContainer xmlns=\"http://data.gov.sk/def/container/xmldatacontainer+xml/1.1\">"
            + "<XMLData ContentType=\"application/xml; charset=UTF-8\" Identifier=\"http://data.gov.sk/doc/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0\" Version=\"1.0\"><ConversionRecord xmlns=\"https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0\"/></XMLData>"
            + "</XMLDataContainer>";

    /// The EZZK record is an XMLDataContainer signed alone, as in the record EZZK accepted.
    @Test
    void recordXdcIsSignedAloneWithTheBareXdcMimeAndNoNetwork() throws Exception {
        var xdcf = RECORD_XDC.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        var retained = new MemoryRetainedFile();
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        var job = MachineSigningService.DefaultSigningSession.signingJob(xdcf, "/tmp/260923-TEST.record.xml.xdcf",
                new MachineFileResponder(retained, () -> { }), settings, null, List.of());
        // No eForm is resolved: nothing is fetched, validated against a form or re-wrapped.
        assertTrue(job.getParameters().isPlainRecordXdc());
        assertFalse(job.getParameters().shouldCreateXdc());
        assertEquals(null, job.getParameters().getSchema());
        assertEquals(null, job.getParameters().getTransformation());
        assertEquals(ASiCContainerType.ASiC_E, job.getParameters().getContainer());
        var token = new Pkcs12SignatureToken(Objects.requireNonNull(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/test.keystore")).getFile(), new KeyStore.PasswordProtection("".toCharArray()));
        job.signWithKeyAndRespond(new SigningKey(token, token.getKeys().get(0)));

        var names = new ArrayList<String>();
        String manifest = null;
        String signature = null;
        byte[] data = null;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(retained.readAll()))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                names.add(entry.getName());
                var content = zip.readAllBytes();
                if (entry.getName().equals("META-INF/manifest.xml")) manifest = new String(content, java.nio.charset.StandardCharsets.UTF_8);
                if (entry.getName().startsWith("META-INF/signatures")) signature = new String(content, java.nio.charset.StandardCharsets.UTF_8);
                if (entry.getName().equals("260923-TEST.record.xml.xdcf")) data = content;
            }
        }
        assertEquals(List.of("260923-TEST.record.xml.xdcf"), names.stream()
                .filter(name -> !name.equals("mimetype") && !name.startsWith("META-INF/")).toList());
        assertArrayEquals(xdcf, data, "the record XDC must be signed byte for byte");
        assertTrue(manifest.contains("manifest:media-type=\"application/vnd.gov.sk.xmldatacontainer+xml\""), manifest);
        assertTrue(java.util.regex.Pattern.compile("<(\\w+:)?MimeType>application/vnd\\.gov\\.sk\\.xmldatacontainer\\+xml</(\\w+:)?MimeType>")
                .matcher(signature).find(), signature);
        assertFalse(signature.contains("charset"), signature);
    }

    @Test
    void anXdcfThatIsNotAnXmlDataContainerIsRefused() {
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        assertThrows(java.io.IOException.class, () -> MachineSigningService.DefaultSigningSession.signingJob(
                "<Other/>".getBytes(java.nio.charset.StandardCharsets.UTF_8), "/tmp/x.record.xml.xdcf",
                new MachineFileResponder(new MemoryRetainedFile(), () -> { }), settings, null, List.of()));
    }

    /// A record is signed alone; attachments go only next to a PDF.
    @Test
    void aRecordXdcWithAttachmentsIsRefused() {
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        assertThrows(java.io.IOException.class, () -> MachineSigningService.DefaultSigningSession.signingJob(
                RECORD_XDC.getBytes(java.nio.charset.StandardCharsets.UTF_8), "/tmp/260923-TEST.record.xml.xdcf",
                new MachineFileResponder(new MemoryRetainedFile(), () -> { }), settings, null,
                List.of(new MachineSigningService.AttachmentContent("dokument.pdf", "%PDF-1.7\n%%EOF".getBytes()))));
    }

    /// A record is XAdES in an ASiC-E; a PAdES level is refused rather than guessed.
    @Test
    void aRecordXdcIsRefusedForAPadesLevel() {
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.PAdES_BASELINE_B);
        assertThrows(java.io.IOException.class, () -> MachineSigningService.DefaultSigningSession.signingJob(
                RECORD_XDC.getBytes(java.nio.charset.StandardCharsets.UTF_8), "/tmp/260923-TEST.record.xml.xdcf",
                new MachineFileResponder(new MemoryRetainedFile(), () -> { }), settings, null, List.of()));
    }

    /// Only an `.xdcf` whose root is an XMLDataContainer passes preparation; any other XML stays refused.
    @Test
    void preparationAcceptsARecordXdcButStillRefusesOtherXml() throws Exception {
        var xdcWriter = new RecordingWriter();
        var xdcSource = Files.writeString(temporaryDirectory.resolve("260923-TEST.record.xml.xdcf"), RECORD_XDC).toRealPath();
        var sessionRequested = new AtomicBoolean();
        var xdcService = new MachineSigningService(xdcWriter.writer(), request -> {
            sessionRequested.set(true);
            throw new IllegalStateException("no token in this test");
        }, content -> true);

        xdcService.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", xdcSource.toString(), target("260923-TEST.asice").toString()))));

        assertTrue(sessionRequested.get(), "a record XDC must reach the session factory");

        var xmlWriter = new RecordingWriter();
        var xmlSource = Files.writeString(temporaryDirectory.resolve("record.xml"), RECORD_XDC).toRealPath();
        var tokenOpened = new AtomicBoolean();
        var xmlService = new MachineSigningService(xmlWriter.writer(), request -> {
            tokenOpened.set(true);
            throw new AssertionError("Token must not open for a plain XML source");
        }, content -> true);

        xmlService.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", xmlSource.toString(), target("record.asice").toString()))));

        assertFalse(tokenOpened.get());
        assertEquals("SIGNING_UNAVAILABLE", xmlWriter.payloadCode(2));
    }

    /// A state-portal eForm travels as plain XML: with eForm attributes it must reach the
    /// session factory, where the XDC build happens. Without them it stays refused (above).
    @Test
    void preparationAcceptsAnXmlEFormWithAttributes() throws Exception {
        var writer = new RecordingWriter();
        var xmlSource = Files.writeString(temporaryDirectory.resolve("Object1279.xml"), probeForm()).toRealPath();
        var sessionRequested = new AtomicBoolean();
        var service = new MachineSigningService(writer.writer(), request -> {
            sessionRequested.set(true);
            throw new IllegalStateException("no token in this test");
        }, content -> true);

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", xmlSource.toString(), target("Object1279.asice").toString())),
                new EFormRequest(
                        "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
                        base64(probeSchema()),
                        base64(probeTransformation()),
                        PROBE_NS,
                        null, null, "sk", "HTML", "probe",
                        true, false, null, null)));

        assertTrue(sessionRequested.get(), "an eForm XML source must reach the session factory");
    }

    /// The whole path for a record: preparation, a real Baseline B signature, the output check
    /// of the one-object container and publishing it.
    @Test
    void signsAndPublishesARecordXdcThroughTheService() throws Exception {
        var writer = new RecordingWriter();
        var xdcf = RECORD_XDC.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        var source = Files.write(temporaryDirectory.resolve("260923-TEST.record.xml.xdcf"), xdcf).toRealPath();
        var target = target("260923-TEST.asice");
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        var key = new SigningKey(token, token.getKeys().get(0));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((input, completed) ->
                MachineSigningService.DefaultSigningSession.signingJob(input.sourceContent(), input.file().source(),
                        new MachineFileResponder(input.staging(), completed), settings, null, input.attachments())
                        .signWithKeyAndRespond(key)),
                new MachineSigningService.PdfOutputValidator(new MachineInspectionService()));

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", source.toString(), target.toString()))));

        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.completed"),
                writer.lifecycleEventTypes());
        var names = new ArrayList<String>();
        String manifest = null;
        byte[] data = null;
        try (var zip = new ZipInputStream(Files.newInputStream(target))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                names.add(entry.getName());
                var content = zip.readAllBytes();
                if (entry.getName().equals("META-INF/manifest.xml")) manifest = new String(content, java.nio.charset.StandardCharsets.UTF_8);
                if (entry.getName().equals("260923-TEST.record.xml.xdcf")) data = content;
            }
        }
        assertEquals(List.of("260923-TEST.record.xml.xdcf"), names.stream()
                .filter(name -> !name.equals("mimetype") && !name.startsWith("META-INF/")).toList());
        assertArrayEquals(xdcf, data, "the record XDC must be published byte for byte");
        assertTrue(manifest.contains("manifest:full-path=\"260923-TEST.record.xml.xdcf\" manifest:media-type=\"application/vnd.gov.sk.xmldatacontainer+xml\""), manifest);
    }

    /// DSS only extends an existing container when it signs a single document; with attachments
    /// an existing ASiC would end up nested inside the new one.
    @Test
    void signingJobRefusesAnExistingContainerWithAttachments() throws Exception {
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_T);
        var container = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/FUPS_signed.asice").getFile()));

        assertThrows(java.io.IOException.class, () -> MachineSigningService.DefaultSigningSession.signingJob(container,
                "/tmp/podpisany.asice", new MachineFileResponder(new MemoryRetainedFile(), () -> { }), settings, null,
                List.of(new MachineSigningService.AttachmentContent("a.xml.xdcf", "<a/>".getBytes()))));
    }

    @Test
    void signingJobRefusesAContainerAsAnAttachment() throws Exception {
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        var pdf = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));
        var container = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/FUPS_signed.asice").getFile()));

        assertThrows(java.io.IOException.class, () -> MachineSigningService.DefaultSigningSession.signingJob(pdf,
                "/tmp/dokument.pdf", new MachineFileResponder(new MemoryRetainedFile(), () -> { }), settings, null,
                List.of(new MachineSigningService.AttachmentContent("dokument.xml.xdcf", container))));
    }

    /// The validator only sees the name; a ZIP hiding behind an `.xdcf` name is caught when the
    /// attachment is read, before the token opens.
    @Test
    void refusesAZipAttachmentBeforeTokenWork() throws Exception {
        var writer = new RecordingWriter();
        var source = Files.copy(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()),
                temporaryDirectory.resolve("dokument.pdf")).toRealPath();
        var attachment = Files.copy(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/FUPS_signed.asice").getFile()),
                temporaryDirectory.resolve("dokument.xml.xdcf")).toRealPath();
        var target = target("zip-attachment.asice");
        var tokenOpened = new AtomicBoolean();
        var service = new MachineSigningService(writer.writer(), request -> {
            tokenOpened.set(true);
            throw new AssertionError("Token must not open for a container attachment");
        }, content -> true);

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", source.toString(), target.toString(), null, List.of(attachment.toString())))));

        assertFalse(tokenOpened.get());
        assertFalse(Files.exists(target));
        assertEquals(List.of("session.started", "file.signingStarted", "file.failed", "session.failed"),
                writer.lifecycleEventTypes());
    }

    /// Attachments are read through the same retained, no-follow handle as the source, never by
    /// path a second time after validation.
    @Test
    void readsAttachmentsThroughTheRetainedSourceHandle() throws Exception {
        var writer = new RecordingWriter();
        var source = Files.writeString(temporaryDirectory.resolve("dokument.pdf"), "%PDF-1.7\nsource\n%%EOF").toRealPath();
        var attachment = Files.writeString(temporaryDirectory.resolve("dokument.xml.xdcf"), "<on-disk/>").toRealPath();
        var fileSystem = new TrackingFileSystem();
        var retainedAttachment = new MemoryRetainedFile("<retained/>".getBytes()) {
            boolean closed;

            @Override
            public void close() {
                closed = true;
            }
        };
        fileSystem.retained.put(attachment, retainedAttachment);
        var signed = new AtomicReference<MachineSigningService.SigningInput>();
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((input, completed) -> {
            signed.set(input);
            input.writeSignedContent("PK".getBytes());
            completed.run();
        }), content -> true, () -> { }, fileSystem);

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", source.toString(), target("retained.asice").toString(), null,
                        List.of(attachment.toString())))));

        assertEquals("<retained/>", new String(signed.get().attachments().getFirst().content()));
        assertTrue(retainedAttachment.closed);
    }

    @Test
    void attachmentsNeedAnAsicESignature() {
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.PAdES_BASELINE_T);
        settings.setTsaServer("https://tsa.example.test");
        settings.setTsaEnabled(true);
        assertThrows(java.io.IOException.class, () -> MachineSigningService.DefaultSigningSession.signingJob(
                Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/sample.pdf").getFile())),
                "/tmp/dokument.pdf", new MachineFileResponder(new MemoryRetainedFile(), () -> { }), settings, null,
                List.of(new MachineSigningService.AttachmentContent("a.xml.xdcf", new byte[] { '<', 'a', '/', '>' }))));
    }

    @Test
    void signingJobWithoutEFormAttributesStillTreatsPdfAsPades() throws Exception {
        var source = Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile());
        var responder = new MachineFileResponder(new MemoryRetainedFile(), () -> { });
        var settings = new MachineSettings(true);
        settings.setTsaServer("https://tsa.example.test");
        settings.setTsaEnabled(true);

        var job = MachineSigningService.DefaultSigningSession.signingJob(Files.readAllBytes(source), source.toString(),
                responder, settings);

        assertEquals(SignatureForm.PAdES, job.getParameters().getSignatureType());
    }

    @Test
    void signingJobUsesTheRequiredPadesBaselineTPolicy() throws Exception {
        var source = Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile());
        var responder = new MachineFileResponder(new MemoryRetainedFile(), () -> { });
        var settings = new MachineSettings(true);
        settings.setTsaServer("https://tsa.example.test");
        settings.setTsaEnabled(true);

        var job = MachineSigningService.DefaultSigningSession.signingJob(Files.readAllBytes(source), source.toString(),
                responder, settings);

        assertEquals(SignatureLevel.PAdES_BASELINE_T, job.getParameters().getLevel());
        assertEquals(eu.europa.esig.dss.enumerations.SignatureForm.PAdES, job.getParameters().getSignatureType());
    }

    @Test
    void signingJobBindsTheSnapshottedVisiblePadesAppearance() throws Exception {
        var source = Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile());
        var image = temporaryDirectory.resolve("visible-signature.png");
        Files.copy(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.png").getFile()), image);
        var appearance = new VisibleSignatureAppearance(image.toString(), 2, 72, 540, 216, 108,
                Instant.parse("2026-08-10T12:34:56Z"));
        var snapshot = appearance.snapshot();
        Files.writeString(image, "replacement");
        var responder = new MachineFileResponder(new MemoryRetainedFile(), () -> { });
        var settings = new MachineSettings(true);
        settings.setTsaServer("https://tsa.example.test");
        settings.setTsaEnabled(true);

        var job = MachineSigningService.DefaultSigningSession.signingJob(Files.readAllBytes(source), source.toString(),
                responder, settings, snapshot);
        var parameters = job.getParameters().getPAdESSignatureParameters();
        var field = parameters.getImageParameters().getFieldParameters();

        assertEquals(2, field.getPage());
        assertEquals(72, field.getOriginX());
        assertEquals(540, field.getOriginY());
        assertEquals(216, field.getWidth());
        assertEquals(108, field.getHeight());
        assertEquals(eu.europa.esig.dss.enumerations.VisualSignatureRotation.NONE, field.getRotation());
        assertEquals(eu.europa.esig.dss.enumerations.ImageScaling.STRETCH,
                parameters.getImageParameters().getImageScaling());
        assertEquals(Instant.parse("2026-08-10T12:34:56Z"), parameters.getSigningDate().toInstant());
        try (var imageStream = parameters.getImageParameters().getImage().openStream()) {
            assertTrue(Arrays.equals(snapshot.pngBytes(), imageStream.readAllBytes()));
        }
    }

    @Test
    void signingJobWrapsPdfInAsicEWithXadesWhenRequested() throws Exception {
        var source = Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile());
        var responder = new MachineFileResponder(new MemoryRetainedFile(), () -> { });
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_T);
        settings.setTsaServer("https://tsa.example.test");
        settings.setTsaEnabled(true);

        var job = MachineSigningService.DefaultSigningSession.signingJob(Files.readAllBytes(source), source.toString(),
                responder, settings);

        assertEquals(SignatureLevel.XAdES_BASELINE_T, job.getParameters().getLevel());
        assertEquals(SignatureForm.XAdES, job.getParameters().getSignatureType());
        assertEquals(ASiCContainerType.ASiC_E, job.getParameters().getContainer());
    }

    /// nove.slovensko.sk asks for XAdES Baseline B around a PDF. It must become an
    /// ASiC-E with the PDF inside, not a PAdES signature and not a nested container.
    @Test
    void signingJobWrapsPdfInAsicEWithXadesBaselineBWhenAPortalAsksForIt() throws Exception {
        var source = Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile());
        var responder = new MachineFileResponder(new MemoryRetainedFile(), () -> { });
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);

        var job = MachineSigningService.DefaultSigningSession.signingJob(Files.readAllBytes(source), source.toString(),
                responder, settings);

        assertEquals(SignatureLevel.XAdES_BASELINE_B, job.getParameters().getLevel());
        assertEquals(SignatureForm.XAdES, job.getParameters().getSignatureType());
        assertEquals(ASiCContainerType.ASiC_E, job.getParameters().getContainer());
    }

    @Test
    void signingJobUsesTheExistingAsicXadesFormatAndQualifiedTimestampPolicy() throws Exception {
        var source = Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_pdf_xades.asice").getFile());
        var responder = new MachineFileResponder(new MemoryRetainedFile(), () -> { });
        var settings = new MachineSettings(true);
        settings.setTsaServer("https://tsa.example.test");
        settings.setTsaEnabled(true);

        var job = MachineSigningService.DefaultSigningSession.signingJob(Files.readAllBytes(source), source.toString(),
                responder, settings);

        assertEquals(SignatureLevel.XAdES_BASELINE_T, job.getParameters().getLevel());
        assertEquals(eu.europa.esig.dss.enumerations.SignatureForm.XAdES, job.getParameters().getSignatureType());
    }

    @Test
    void configuresBasicTimestampAuthenticationForOnlyTheRequestedHostsAndClearsTheReceivedSecret() {
        var receivedSecret = "timestamp-password".toCharArray();
        var request = new QualifiedTimestampRequest(true,
                List.of("https://first.tsa.example.test", "https://second.tsa.example.test:8443"),
                new TimestampAuthentication("basic", "timestamp-user", receivedSecret));

        var dataLoader = MachineSigningService.MachineTimestampDataLoader.create(request);
        request.clearAuthentication();

        assertEquals(2, dataLoader.getAuthenticationMap().size());
        assertTrue(dataLoader.getAuthenticationMap().keySet().stream()
                .allMatch(host -> host.getHost().endsWith(".tsa.example.test")));
        assertTrue(Arrays.equals(new char[receivedSecret.length], receivedSecret));

        dataLoader.clearAuthentication();
        assertTrue(dataLoader.getAuthenticationMap().values().stream()
                .allMatch(credentials -> Arrays.equals(new char[credentials.getPassword().length], credentials.getPassword())));
    }

    private SignRequest request(char[] pin, MachineFile... files) {
        return new SignRequest("fake", "123", pin, "PAdES_BASELINE_T",
                new QualifiedTimestampRequest(true, List.of("https://tsa.example.test")), List.of(files));
    }

    private MachineFile file(String id, String sourceName, String targetName) throws Exception {
        var source = Files.writeString(temporaryDirectory.resolve(sourceName), "%PDF-1.7\nfixture\n%%EOF").toRealPath();
        return new MachineFile(id, source.toString(), target(targetName).toString());
    }

    private MachineFile visibleFile(String id, String sourceName, String targetName) throws Exception {
        var file = file(id, sourceName, targetName);
        var image = temporaryDirectory.resolve(id + "-visible.png");
        Files.copy(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.png").getFile()), image);
        var appearance = new VisibleSignatureAppearance(image.toString(), 2, 72, 540, 216, 108,
                Instant.parse("2026-08-10T12:34:56Z")).snapshot();
        return new MachineFile(file.id(), file.source(), file.target(), appearance);
    }

    private Path target(String name) throws Exception {
        return temporaryDirectory.toRealPath().resolve(name);
    }

    private static SimpleReport qualifiedReport(String... ids) {
        var report = mock(SimpleReport.class);
        when(report.getSignatureIdList()).thenReturn(List.of(ids));
        for (var id : ids) {
            var timestamp = new XmlTimestamp();
            timestamp.setId("ts-" + id);
            when(report.getSignatureFormat(id)).thenReturn(SignatureLevel.PAdES_BASELINE_T);
            when(report.isValid(id)).thenReturn(true);
            when(report.getIndication(id)).thenReturn(Indication.TOTAL_PASSED);
            when(report.getSignatureTimestamps(id)).thenReturn(List.of(timestamp));
            when(report.isValid("ts-" + id)).thenReturn(true);
            when(report.getTimestampQualification("ts-" + id)).thenReturn(
                    eu.europa.esig.dss.enumerations.TimestampQualification.QTSA);
        }
        return report;
    }

    private static SimpleReport locallyValidTimestampReport(String... ids) {
        var report = mock(SimpleReport.class);
        when(report.getSignatureIdList()).thenReturn(List.of(ids));
        for (var id : ids) {
            var timestamp = new XmlTimestamp();
            timestamp.setId("ts-" + id);
            when(report.getSignatureFormat(id)).thenReturn(SignatureLevel.PAdES_BASELINE_T);
            when(report.isValid(id)).thenReturn(true);
            when(report.getIndication(id)).thenReturn(Indication.TOTAL_PASSED);
            when(report.getSignatureTimestamps(id)).thenReturn(List.of(timestamp));
            when(report.isValid("ts-" + id)).thenReturn(true);
        }
        return report;
    }

    private static final class TestTokenDriver extends TokenDriver {
        private final boolean duplicateKey;
        private TestToken token;
        private boolean created;

        private TestTokenDriver(String shortname) {
            this(shortname, false);
        }

        private TestTokenDriver(String shortname, boolean duplicateKey) {
            super("Test token", Path.of("test-token"), shortname, "");
            this.duplicateKey = duplicateKey;
        }

        @Override
        public AbstractKeyStoreTokenConnection createToken(PasswordManager passwordManager,
                digital.slovensko.autogram.core.SignatureTokenSettings settings) {
            created = true;
            try {
                token = new TestToken(duplicateKey);
                return token;
            } catch (java.io.IOException exception) {
                throw new IllegalStateException(exception);
            }
        }

        private String serial() throws Exception {
            if (token == null) {
                var preview = new TestToken(duplicateKey);
                try {
                    return preview.getKeys().getFirst().getCertificate().getSerialNumber().toString();
                } finally {
                    preview.close();
                }
            }
            return token.getKeys().getFirst().getCertificate().getSerialNumber().toString();
        }

        private int closeCount() {
            return token == null ? 0 : token.closeCount;
        }
    }

    private static final class TestToken extends Pkcs12SignatureToken {
        private final boolean duplicateKey;
        private int closeCount;

        private TestToken(boolean duplicateKey) throws java.io.IOException {
            super(MachineSigningServiceTest.class.getResource("/digital/slovensko/autogram/test.keystore").getFile(),
                    new KeyStore.PasswordProtection(new char[0]));
            this.duplicateKey = duplicateKey;
        }

        @Override
        public List<eu.europa.esig.dss.token.DSSPrivateKeyEntry> getKeys() {
            var keys = super.getKeys();
            return duplicateKey ? List.of(keys.getFirst(), keys.getFirst()) : keys;
        }

        @Override
        public void close() {
            closeCount++;
            super.close();
        }
    }

    private static MachineSigningFileSystem.Workspace failingWorkspace(boolean cleanupResult) {
        return new MachineSigningFileSystem.Workspace() {
            @Override
            public MachineSigningFileSystem.RetainedFile createStagingFile() throws java.io.IOException {
                throw new java.io.IOException("identity capture failed");
            }

            @Override
            public void publish(MachineSigningFileSystem.RetainedFile source, String targetLeaf) {
                throw new AssertionError("Publication must not run");
            }

            @Override
            public boolean cleanup() {
                return cleanupResult;
            }

            @Override
            public void close() {
            }
        };
    }

    private static class MemoryRetainedFile implements MachineSigningFileSystem.RetainedFile {
        private byte[] content;

        private MemoryRetainedFile() {
            this(new byte[0]);
        }

        private MemoryRetainedFile(byte[] content) {
            this.content = content.clone();
        }

        @Override
        public byte[] readAll() {
            return content.clone();
        }

        @Override
        public void replaceContent(byte[] content) {
            this.content = content.clone();
        }

        @Override
        public void close() {
        }
    }

    private static final class TrackingFileSystem implements MachineSigningFileSystem {
        private final MemoryRetainedFile source = new MemoryRetainedFile("%PDF-1.7\nsource\n%%EOF".getBytes());
        private final MemoryRetainedFile staging = new MemoryRetainedFile();
        private final java.util.Map<Path, RetainedFile> retained = new java.util.HashMap<>();
        private Error cleanupFailure;

        @Override
        public RetainedFile openSource(Path source) {
            return retained.getOrDefault(source, this.source);
        }

        @Override
        public Workspace createWorkspace(Path targetParent) {
            return new Workspace() {
                @Override
                public RetainedFile createStagingFile() {
                    return staging;
                }

                @Override
                public void publish(RetainedFile source, String targetLeaf) throws java.io.IOException {
                }

                @Override
                public boolean cleanup() {
                    if (cleanupFailure != null) {
                        throw cleanupFailure;
                    }
                    return true;
                }

                @Override
                public void close() {
                }
            };
        }
    }

    private static final class FakeSession implements MachineSigningService.SigningSession {
        private final SignBehavior behavior;
        private final boolean closeFails;
        private boolean closed;

        private FakeSession(SignBehavior behavior) {
            this(behavior, false);
        }

        private FakeSession(SignBehavior behavior, boolean closeFails) {
            this.behavior = behavior;
            this.closeFails = closeFails;
        }

        @Override
        public void sign(MachineSigningService.SigningInput input, Runnable completed) throws Exception {
            behavior.sign(input, completed);
        }

        @Override
        public void close() {
            closed = true;
            if (closeFails) {
                throw new IllegalStateException("close failure");
            }
        }
    }

    @FunctionalInterface
    private interface SignBehavior {
        void sign(MachineSigningService.SigningInput file, Runnable completed) throws Exception;
    }

    @Test
    void plainTextPassesTheMachineGateByExtension() {
        var content = "Hello world".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        assertTrue(MachineSigningService.isSupportedSource("poznamka.txt", content, false));
        assertEquals(eu.europa.esig.dss.enumerations.MimeTypeEnum.TEXT,
                MachineSigningService.detectMimeType("poznamka.txt", content));
    }

    @Test
    void pngPassesTheMachineGateOnlyWithRealPngMagic() {
        var png = new byte[] { (byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00 };
        assertTrue(MachineSigningService.isSupportedSource("obrazok.png", png, false));
        assertEquals(eu.europa.esig.dss.enumerations.MimeTypeEnum.PNG,
                MachineSigningService.detectMimeType("obrazok.png", png));
        assertFalse(MachineSigningService.isSupportedSource("obrazok.png",
                "not a png".getBytes(java.nio.charset.StandardCharsets.UTF_8), false));
    }

    @Test
    void nonPdfBytesWithoutKnownExtensionStillFailTheGate() {
        var content = "garbage".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        assertFalse(MachineSigningService.isSupportedSource("dokument.pdf", content, false));
        assertEquals(eu.europa.esig.dss.enumerations.MimeTypeEnum.PDF,
                MachineSigningService.detectMimeType("dokument.pdf", content));
    }

    @Test
    void txtBuildsXadesAsicParametersThroughTheMachinePath() throws Exception {
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        var job = MachineSigningService.DefaultSigningSession.signingJob(
                "Hello world".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "poznamka.txt", mock(MachineFileResponder.class), settings);
        assertEquals(SignatureLevel.XAdES_BASELINE_B, job.getParameters().getLevel());
        assertEquals(ASiCContainerType.ASiC_E, job.getParameters().getContainer());
        assertEquals(SignatureForm.XAdES, job.getParameters().getSignatureType());
    }

    @Test
    void padesLevelRefusesPlainTextThroughTheMachinePath() {
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.PAdES_BASELINE_B);
        assertThrows(java.io.IOException.class, () -> MachineSigningService.DefaultSigningSession.signingJob(
                "Hello world".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "poznamka.txt", mock(MachineFileResponder.class), settings));
    }

    /// The whole production path for a portal TXT: the prepare gate, the previous-signature
    /// preflight (empty by construction for plain text), a real signature with the test token
    /// and the output check of the one-object container, published to the target.
    @Test
    void signsAndPublishesPlainTextThroughTheService() throws Exception {
        var writer = new RecordingWriter();
        var source = Files.writeString(temporaryDirectory.resolve("poznamka.txt"), "Hello world").toRealPath();
        var target = target("poznamka.asice");
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        var key = new SigningKey(token, token.getKeys().get(0));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((input, completed) ->
                MachineSigningService.DefaultSigningSession.signingJob(input.sourceContent(), input.file().source(),
                        new MachineFileResponder(input.staging(), completed), settings, null, input.attachments())
                        .signWithKeyAndRespond(key)),
                new MachineSigningService.PdfOutputValidator(new MachineInspectionService()));

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", source.toString(), target.toString()))));

        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.completed"),
                writer.lifecycleEventTypes());
        var names = new ArrayList<String>();
        String signature = null;
        try (var zip = new ZipInputStream(Files.newInputStream(target))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                names.add(entry.getName());
                var content = new String(zip.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
                if (entry.getName().startsWith("META-INF/signatures")) signature = content;
            }
        }
        assertTrue(names.contains("poznamka.txt"), names.toString());
        assertTrue(names.stream().noneMatch(name -> name.endsWith(".asice")), names.toString());
        assertTrue(referencesFile(Objects.requireNonNull(signature), "poznamka.txt"), signature);
    }

    /// Same production path for a PNG: the gate checks the real PNG magic and the published
    /// container carries the image as its single data object.
    /// A web form export asks the viewer to redraw its fields, and Acrobat then hides the
    /// signature. The PAdES output signs a revision with generated appearances and the flag
    /// cleared, keeps the source as its first revision and still passes the output check.
    /// The machine protocol refuses PAdES Baseline B and Baseline T needs a live TSA, so the
    /// job is signed directly with the test token and checked by the real output validator.
    @Test
    void padesSignatureOfANeedAppearancesFormSignsGeneratedAppearances() throws Exception {
        var source = NeedAppearancesFixture.webForm(true);
        var retained = new MemoryRetainedFile();
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.PAdES_BASELINE_B);
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));

        MachineSigningService.DefaultSigningSession.signingJob(source, "/tmp/formular.pdf",
                new MachineFileResponder(retained, () -> { }), settings)
                .signWithKeyAndRespond(new SigningKey(token, token.getKeys().get(0)));

        var signed = retained.readAll();
        var validator = new MachineSigningService.PdfOutputValidator(new MachineInspectionService());
        var previousSignatureIds = validator.signatureIds(source);
        assertEquals(java.util.Set.of(), previousSignatureIds);
        assertEquals(null, validator.validationFailure(signed, previousSignatureIds, false, "PAdES_BASELINE_B"));
        assertArrayEquals(source, Arrays.copyOf(signed, source.length), "the source stays the first revision");
        try (var document = org.apache.pdfbox.Loader.loadPDF(signed)) {
            var acroForm = document.getDocumentCatalog().getAcroForm(null);
            assertFalse(acroForm.getNeedAppearances());
            assertEquals(1, document.getSignatureDictionaries().size());
            for (var field : acroForm.getFieldTree()) {
                for (var widget : field.getWidgets()) {
                    assertTrue(widget.getAppearance() != null, field.getFullyQualifiedName() + " has no appearance");
                }
            }
        }
    }

    /// An ASiC-E carries the PDF as its data object, which must stay the source itself.
    @Test
    void asicSignatureOfANeedAppearancesFormKeepsThePdfByteIdentical() throws Exception {
        var source = NeedAppearancesFixture.webForm(true);
        var target = signThroughTheService(source, "formular.pdf", "formular.asice", SignatureLevel.XAdES_BASELINE_B);

        byte[] dataObject = null;
        try (var zip = new ZipInputStream(Files.newInputStream(target))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                if (entry.getName().equals("formular.pdf")) dataObject = zip.readAllBytes();
            }
        }
        assertArrayEquals(source, dataObject);
    }

    private Path signThroughTheService(byte[] source, String sourceName, String targetName, SignatureLevel level)
            throws Exception {
        var writer = new RecordingWriter();
        var sourcePath = Files.write(temporaryDirectory.resolve(sourceName), source).toRealPath();
        var target = target(targetName);
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(level);
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        var key = new SigningKey(token, token.getKeys().get(0));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((input, completed) ->
                MachineSigningService.DefaultSigningSession.signingJob(input.sourceContent(), input.file().source(),
                        new MachineFileResponder(input.staging(), completed), settings, null, input.attachments())
                        .signWithKeyAndRespond(key)),
                new MachineSigningService.PdfOutputValidator(new MachineInspectionService()));

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), level.name(),
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", sourcePath.toString(), target.toString()))));

        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.completed"),
                writer.lifecycleEventTypes(), writer.serialized());
        return target;
    }

    @Test
    void signsAndPublishesPngThroughTheService() throws Exception {
        var writer = new RecordingWriter();
        var image = Files.copy(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.png").getFile()),
                temporaryDirectory.resolve("obrazok.png")).toRealPath();
        var target = target("obrazok.asice");
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        var key = new SigningKey(token, token.getKeys().get(0));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((input, completed) ->
                MachineSigningService.DefaultSigningSession.signingJob(input.sourceContent(), input.file().source(),
                        new MachineFileResponder(input.staging(), completed), settings, null, input.attachments())
                        .signWithKeyAndRespond(key)),
                new MachineSigningService.PdfOutputValidator(new MachineInspectionService()));

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", image.toString(), target.toString()))));

        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.completed"),
                writer.lifecycleEventTypes());
        var names = new ArrayList<String>();
        String signature = null;
        try (var zip = new ZipInputStream(Files.newInputStream(target))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                names.add(entry.getName());
                var content = new String(zip.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
                if (entry.getName().startsWith("META-INF/signatures")) signature = content;
            }
        }
        assertTrue(names.contains("obrazok.png"), names.toString());
        assertTrue(names.stream().noneMatch(name -> name.endsWith(".asice")), names.toString());
        assertTrue(referencesFile(Objects.requireNonNull(signature), "obrazok.png"), signature);
    }

    /// A PDF that already carries a PAdES signature, wrapped into a new ASiC-E: the
    /// container lists only its own signature, so the PDF's signatures survive as the
    /// unchanged signed data object instead of as container signatures.
    @Test
    void signsAndPublishesAnAlreadySignedPdfIntoANewContainerThroughTheService() throws Exception {
        var writer = new RecordingWriter();
        var source = Files.copy(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_signed.pdf").getFile()),
                temporaryDirectory.resolve("dokument.pdf")).toRealPath();
        var sourceBytes = Files.readAllBytes(source);
        var target = target("dokument.asice");
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        var key = new SigningKey(token, token.getKeys().get(0));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((input, completed) ->
                MachineSigningService.DefaultSigningSession.signingJob(input.sourceContent(), input.file().source(),
                        new MachineFileResponder(input.staging(), completed), settings, null, input.attachments())
                        .signWithKeyAndRespond(key)),
                new MachineSigningService.PdfOutputValidator(new MachineInspectionService()));

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", source.toString(), target.toString()))));

        assertEquals(List.of("session.started", "file.signingStarted", "file.completed", "session.completed"),
                writer.lifecycleEventTypes(), writer.serialized());
        byte[] embedded = null;
        String signature = null;
        try (var zip = new ZipInputStream(Files.newInputStream(target))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                var content = zip.readAllBytes();
                if (entry.getName().equals("dokument.pdf")) embedded = content;
                if (entry.getName().startsWith("META-INF/signatures")) {
                    signature = new String(content, java.nio.charset.StandardCharsets.UTF_8);
                }
            }
        }
        assertArrayEquals(sourceBytes, embedded);
        assertTrue(referencesFile(Objects.requireNonNull(signature), "dokument.pdf"), signature);
    }

    /// The relaxed previous-signature check never lets a container around another document
    /// through: the signed source must be the signed data object, byte for byte.
    @Test
    void refusesANewContainerThatDoesNotCarryTheSignedSourceUnchanged() throws Exception {
        var writer = new RecordingWriter();
        var source = Files.copy(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_signed.pdf").getFile()),
                temporaryDirectory.resolve("dokument.pdf")).toRealPath();
        var other = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));
        var target = target("dokument.asice");
        var settings = new MachineSettings(true);
        settings.setSignatureLevel(SignatureLevel.XAdES_BASELINE_B);
        var token = new Pkcs12SignatureToken(
                Objects.requireNonNull(MachineSigningServiceTest.class
                        .getResource("/digital/slovensko/autogram/test.keystore")).getFile(),
                new KeyStore.PasswordProtection("".toCharArray()));
        var key = new SigningKey(token, token.getKeys().get(0));
        var service = new MachineSigningService(writer.writer(), request -> new FakeSession((input, completed) ->
                MachineSigningService.DefaultSigningSession.signingJob(other, input.file().source(),
                        new MachineFileResponder(input.staging(), completed), settings, null, input.attachments())
                        .signWithKeyAndRespond(key)),
                new MachineSigningService.PdfOutputValidator(new MachineInspectionService()));

        service.sign("request-1", new SignRequest("fake", "123", "1234".toCharArray(), "XAdES_BASELINE_B",
                new QualifiedTimestampRequest(false, List.of()),
                List.of(new MachineFile("one", source.toString(), target.toString()))));

        assertEquals(List.of("session.started", "file.signingStarted", "file.failed", "session.completed"),
                writer.lifecycleEventTypes());
        assertEquals("OUTPUT_VALIDATION_FAILED", writer.payloadCode(2));
        assertFalse(Files.exists(target));
    }

    /// A wrapped signed PDF must come back byte-identical inside the container; a
    /// container around any other document cannot stand in for it.
    @Test
    void wrappedSignedSourceMustBeTheContainersSignedDataObject() throws Exception {
        var container = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_pdf_xades.asice").getFile()));
        var unsigned = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));
        var signed = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_signed.pdf").getFile()));

        assertTrue(MachineInspectionService.signaturesCoverDocument(container, unsigned));
        assertFalse(MachineInspectionService.signaturesCoverDocument(container, signed));
        assertFalse(MachineInspectionService.signaturesCoverDocument(signed, signed));
    }

    /// Being in the container is not enough: an entry the signature does not reference
    /// is not covered, even when its bytes equal the source.
    @Test
    void anUnreferencedEntryWithTheSourceBytesIsNotCovered() throws Exception {
        var container = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_pdf_xades.asice").getFile()));
        var signed = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample_signed.pdf").getFile()));
        var widened = new java.io.ByteArrayOutputStream();
        try (var input = new ZipInputStream(new ByteArrayInputStream(container));
                var output = new java.util.zip.ZipOutputStream(widened)) {
            for (var entry = input.getNextEntry(); entry != null; entry = input.getNextEntry()) {
                var content = input.readAllBytes();
                var copy = new java.util.zip.ZipEntry(entry.getName());
                if (entry.getName().equals("mimetype")) {
                    var crc = new java.util.zip.CRC32();
                    crc.update(content);
                    copy.setMethod(java.util.zip.ZipEntry.STORED);
                    copy.setSize(content.length);
                    copy.setCrc(crc.getValue());
                }
                output.putNextEntry(copy);
                output.write(content);
                output.closeEntry();
            }
            output.putNextEntry(new java.util.zip.ZipEntry("extra.pdf"));
            output.write(signed);
            output.closeEntry();
        }

        var unsigned = Files.readAllBytes(Path.of(MachineSigningServiceTest.class
                .getResource("/digital/slovensko/autogram/sample.pdf").getFile()));
        assertTrue(MachineInspectionService.signaturesCoverDocument(widened.toByteArray(), unsigned));
        assertFalse(MachineInspectionService.signaturesCoverDocument(widened.toByteArray(), signed));
    }

    private static final class RecordingWriter {
        private final StringWriter output = new StringWriter();

        private MachineEventWriter writer() {
            return new MachineEventWriter(new PrintWriter(output));
        }

        private List<String> lifecycleEventTypes() {
            return events().stream()
                    .filter(event -> !"file.progress".equals(event.get("type").getAsString()))
                    .map(event -> event.get("type").getAsString()).toList();
        }

        private List<String> progressPhases() {
            return events().stream()
                    .filter(event -> "file.progress".equals(event.get("type").getAsString()))
                    .map(event -> event.getAsJsonObject("payload").get("phase").getAsString()).toList();
        }

        private String payloadCode(int eventIndex) {
            return events().stream()
                    .filter(event -> !"file.progress".equals(event.get("type").getAsString()))
                    .toList().get(eventIndex).getAsJsonObject("payload").get("code").getAsString();
        }

        private String payloadString(int eventIndex, String field) {
            var payload = events().stream()
                    .filter(event -> !"file.progress".equals(event.get("type").getAsString()))
                    .toList().get(eventIndex).getAsJsonObject("payload");
            return payload.has(field) ? payload.get(field).getAsString() : null;
        }

        private String serialized() {
            return output.toString();
        }

        private List<com.google.gson.JsonObject> events() {
            return Arrays.stream(output.toString().strip().split("\\n"))
                    .map(JsonParser::parseString).map(value -> value.getAsJsonObject()).toList();
        }
    }
}
