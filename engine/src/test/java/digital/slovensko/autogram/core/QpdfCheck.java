package digital.slovensko.autogram.core;

import org.junit.jupiter.api.Assertions;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/// An independent structural check of a PDF the engine wrote, with qpdf (`qpdf --check`), which
/// parses the file with its own parser and decodes every stream and page content stream. PDFBox
/// reading back what PDFBox wrote would hide a mistake both share.
///
/// The verdict is qpdf's exit code: 0 passes, 3 (warnings) and 2 (errors) fail, so a file qpdf
/// only repairs silently still fails. Without qpdf only this check is left out (the calling test's
/// own assertions still run) and a notice goes to stderr once, unless
/// `AUTOGRAM_REQUIRE_QPDF=1` makes that a failure (for CI). `AUTOGRAM_QPDF` names the binary;
/// when it is set, nothing else is looked for. Otherwise Homebrew's paths, then `PATH`.
public final class QpdfCheck {
    private static final long TIMEOUT_SECONDS = 60;
    private static final List<String> CANDIDATES = List.of("/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf");

    private QpdfCheck() {
    }

    /// Fails the test unless qpdf finds the PDF free of errors and warnings.
    public static void assertClean(byte[] pdf, String label) {
        var qpdf = qpdf();
        if (qpdf == null) {
            return;
        }
        var result = check(qpdf, pdf, label);
        Assertions.assertEquals(0, result.exitCode,
                () -> label + ": qpdf --check exit " + result.exitCode + "\n" + result.output);
    }

    /// For an incremental update of a source the engine did not write: the source's own bytes
    /// stay a verbatim prefix, so its warnings carry over unchanged and are allowed; any warning
    /// the source does not have, and any error, fails. A clean source must give a clean output.
    public static void assertNoNewFindings(byte[] source, byte[] output, String label) {
        var qpdf = qpdf();
        if (qpdf == null) {
            return;
        }
        var before = check(qpdf, source, label + " (source)");
        var after = check(qpdf, output, label);
        if (after.exitCode == 0) {
            return;
        }
        Assertions.assertEquals(3, after.exitCode,
                () -> label + ": qpdf --check exit " + after.exitCode + "\n" + after.output);
        var known = new java.util.HashSet<>(warnings(before.output));
        var added = warnings(after.output).stream().filter(line -> !known.contains(line)).toList();
        Assertions.assertTrue(added.isEmpty(),
                () -> label + ": qpdf warnings the source does not have:\n" + String.join("\n", added));
    }

    private static List<String> warnings(String output) {
        return output.lines().filter(line -> line.startsWith("WARNING:")).toList();
    }

    private static Result check(String qpdf, byte[] pdf, String label) {
        Path file = null;
        try {
            file = Files.createTempFile("qpdf-check-", ".pdf");
            Files.write(file, pdf);
            return run(qpdf, file);
        } catch (IOException exception) {
            return Assertions.fail(label + ": qpdf could not run: " + exception.getMessage(), exception);
        } finally {
            if (file != null) {
                try {
                    Files.deleteIfExists(file);
                } catch (IOException ignored) {
                    // a temporary file left behind does not change the verdict
                }
            }
        }
    }

    /// Fails the test unless qpdf finds the file free of errors and warnings.
    public static void assertClean(File pdf, String label) {
        try {
            assertClean(Files.readAllBytes(pdf.toPath()), label);
        } catch (IOException exception) {
            Assertions.fail(label + ": cannot read " + pdf, exception);
        }
    }

    record Result(int exitCode, String output) {
    }

    static Result run(String qpdf, Path file) throws IOException {
        // Output goes to a file, so a damaged PDF with many warnings cannot fill a pipe and stall qpdf.
        var log = Files.createTempFile("qpdf-check-", ".txt");
        try {
            var process = new ProcessBuilder(qpdf, "--check", file.toString())
                    .redirectErrorStream(true)
                    .redirectOutput(log.toFile())
                    .start();
            try {
                if (!process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                    process.destroyForcibly();
                    throw new IOException("qpdf did not finish within " + TIMEOUT_SECONDS + " s");
                }
            } catch (InterruptedException exception) {
                process.destroyForcibly();
                Thread.currentThread().interrupt();
                throw new IOException("interrupted", exception);
            }
            var output = Files.readString(log, StandardCharsets.UTF_8).replace(file.toString(), "<file>");
            return new Result(process.exitValue(), output);
        } finally {
            Files.deleteIfExists(log);
        }
    }

    private static volatile boolean skipNoticePrinted;

    /// The qpdf binary, or null when it is missing and not required.
    static String qpdf() {
        var found = locate();
        if (found == null) {
            var message = "qpdf is not installed (brew install qpdf), so the independent PDF structure check was skipped";
            if ("1".equals(System.getenv("AUTOGRAM_REQUIRE_QPDF"))) {
                Assertions.fail(message + " although AUTOGRAM_REQUIRE_QPDF=1");
            }
            if (!skipNoticePrinted) {
                skipNoticePrinted = true;
                System.err.println(message + "; the tests' own assertions still ran");
            }
        }
        return found;
    }

    private static String locate() {
        var named = System.getenv("AUTOGRAM_QPDF");
        if (named != null && !named.isBlank()) {
            return new File(named).canExecute() ? named : null;
        }
        var candidates = new ArrayList<String>(CANDIDATES);
        var path = System.getenv("PATH");
        if (path != null) {
            for (var directory : path.split(File.pathSeparator)) {
                if (!directory.isBlank()) {
                    candidates.add(directory + File.separator + "qpdf");
                }
            }
        }
        for (var candidate : candidates) {
            if (new File(candidate).canExecute()) {
                return candidate;
            }
        }
        return null;
    }
}
