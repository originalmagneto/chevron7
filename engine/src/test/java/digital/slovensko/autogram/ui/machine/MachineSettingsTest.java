package digital.slovensko.autogram.ui.machine;

import eu.europa.esig.dss.enumerations.DigestAlgorithm;
import eu.europa.esig.dss.model.DSSException;
import eu.europa.esig.dss.service.http.commons.TimestampDataLoader;
import eu.europa.esig.dss.spi.x509.tsp.TSPSource;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;

class MachineSettingsTest {
    @Test
    void secureStoreUsesTheCardSlotWhenNoSlotIsConfigured() {
        assertEquals(-1, MachineSettings.secureStoreSlotIndex(-1));
    }

    @Test
    void secureStoreKeepsAConfiguredSlot() {
        assertEquals(0, MachineSettings.secureStoreSlotIndex(0));
        assertEquals(3, MachineSettings.secureStoreSlotIndex(3));
    }

    /// UserSettings ties "force context-specific login" to bulk mode, and the machine
    /// session runs in bulk mode. On an eID (CKF_PROTECTED_AUTHENTICATION_PATH) that
    /// sent a PIN from the app to the card as the BOK for every signature, and a
    /// wrong one spends a BOK attempt. The eID client asks for the BOK itself.
    @Test
    void machineModeNeverForcesAProgrammaticLoginOnProtectedTokens() {
        assertFalse(new MachineSettings(true).getForceContextSpecificLoginEnabled());
        assertFalse(new MachineSettings(false).getForceContextSpecificLoginEnabled());
    }

    @Test
    void machineSettingsLeaveSecureStoreUnsetSoTheProbeCanPickTheTokenSlot() {
        var settings = new MachineSettings();

        assertEquals(-1, settings.getDriverSlotIndex("secure_store"));
        assertNull(settings.getEform());
    }

    /// Any failure of the timestamp source becomes TIMESTAMP_FAILED, keeping DSS's cause.
    @Test
    void aTimestampSourceFailureBecomesTimestampFailed() {
        var refusal = new DSSException("HTTP 401 Unauthorized");
        TSPSource refusing = (digestAlgorithm, digest) -> { throw refusal; };
        var source = new MachineSettings.TimestampFailureSource(refusing);

        var error = assertThrows(MachineProtocolException.class,
                () -> source.getTimeStampResponse(DigestAlgorithm.SHA256, new byte[32]));

        assertEquals("TIMESTAMP_FAILED", error.getMessage());
        assertSame(refusal, error.getCause());
    }

    @Test
    void machineSettingsHandTheSignerTheMappingTimestampSource() {
        var settings = new MachineSettings();
        settings.setTsaServer("http://tsa.example.test/qts", new TimestampDataLoader());

        assertInstanceOf(MachineSettings.TimestampFailureSource.class, settings.getTspSource());
    }
}
