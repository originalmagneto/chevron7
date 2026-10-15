package digital.slovensko.autogram.ui.machine;

import eu.europa.esig.dss.enumerations.TimestampQualification;
import eu.europa.esig.dss.simplereport.SimpleReport;

public final class TimestampQualificationEvaluator {
    public boolean hasValidQualifiedTimestamp(SimpleReport report, String signatureId) {
        return hasValidQualifiedTimestamp(report, signatureId, java.util.Set.of());
    }

    /// `inSignedData`: timestamps inside the signed data (content timestamps), which date the
    /// data and never stand in for the signature's own qualified timestamp.
    public boolean hasValidQualifiedTimestamp(SimpleReport report, String signatureId,
            java.util.Set<String> inSignedData) {
        return report.getSignatureTimestamps(signatureId).stream().anyMatch(timestamp ->
                !inSignedData.contains(timestamp.getId())
                        && report.isValid(timestamp.getId())
                        && report.getTimestampQualification(timestamp.getId()) == TimestampQualification.QTSA);
    }
}
