package digital.slovensko.autogram.ui.machine;

import eu.europa.esig.dss.enumerations.TimestampQualification;
import eu.europa.esig.dss.simplereport.SimpleReport;
import eu.europa.esig.dss.simplereport.jaxb.XmlTimestamp;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class TimestampQualificationEvaluatorTest {
    @Test
    void requiresAtLeastOneValidQualifiedSignatureTimestamp() {
        var report = mock(SimpleReport.class);
        when(report.getSignatureTimestamps("sig-1")).thenReturn(List.of(timestamp("ts-1")));
        when(report.isValid("ts-1")).thenReturn(true);
        when(report.getTimestampQualification("ts-1")).thenReturn(TimestampQualification.QTSA);

        assertTrue(new TimestampQualificationEvaluator().hasValidQualifiedTimestamp(report, "sig-1"));
    }

    @Test
    void rejectsOrdinaryTsaQualification() {
        var report = reportWith(TimestampQualification.TSA, true);

        assertFalse(new TimestampQualificationEvaluator().hasValidQualifiedTimestamp(report, "sig-1"));
    }

    @Test
    void rejectsInvalidQualifiedTimestamp() {
        var report = reportWith(TimestampQualification.QTSA, false);

        assertFalse(new TimestampQualificationEvaluator().hasValidQualifiedTimestamp(report, "sig-1"));
    }

    @Test
    void rejectsSignatureWithoutTimestamps() {
        var report = mock(SimpleReport.class);
        when(report.getSignatureTimestamps("sig-1")).thenReturn(List.of());

        assertFalse(new TimestampQualificationEvaluator().hasValidQualifiedTimestamp(report, "sig-1"));
    }

    /// A qualified content timestamp dates the data; the signature still has no qualified
    /// timestamp of its own.
    @Test
    void aQualifiedContentTimestampIsNoQualifiedSignatureTimestamp() {
        var report = reportWith(TimestampQualification.QTSA, true);

        assertFalse(new TimestampQualificationEvaluator().hasValidQualifiedTimestamp(report, "sig-1",
                java.util.Set.of("ts-1")));
    }

    private static SimpleReport reportWith(TimestampQualification qualification, boolean valid) {
        var report = mock(SimpleReport.class);
        when(report.getSignatureTimestamps("sig-1")).thenReturn(List.of(timestamp("ts-1")));
        when(report.isValid("ts-1")).thenReturn(valid);
        when(report.getTimestampQualification("ts-1")).thenReturn(qualification);
        return report;
    }

    private static XmlTimestamp timestamp(String id) {
        var timestamp = new XmlTimestamp();
        timestamp.setId(id);
        return timestamp;
    }
}
