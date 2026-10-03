package digital.slovensko.autogram.ui.machine;

import org.junit.jupiter.api.Test;

import javax.security.auth.x500.X500Principal;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class TimestampTrustAnchorsTest {
    @Test
    void namesTheTimestampCountryOnlyWhenItsListIsMissing() {
        var bosa = TimestampTrustAnchors.of(() -> Set.of("BE", "ES"), (content, id) -> List.of("BE"));
        var certum = TimestampTrustAnchors.of(() -> Set.of("BE", "ES"), (content, id) -> List.of("PL"));
        var unconfigured = TimestampTrustAnchors.of(() -> Set.of("BE"), (content, id) -> List.of("DE"));
        var unknown = TimestampTrustAnchors.of(() -> Set.of("BE"), (content, id) -> List.of());

        assertEquals("BE", bosa.missingCountry(new byte[0], "sig"));
        assertNull(certum.missingCountry(new byte[0], "sig"));
        assertNull(unconfigured.missingCountry(new byte[0], "sig"));
        assertNull(unknown.missingCountry(new byte[0], "sig"));
    }

    @Test
    void theCountryComesFromTheTimestampCertificateThenItsIssuer() {
        assertEquals("BE", TimestampTrustAnchors.countryOf(
                new X500Principal("CN=Belgium TSA, O=Kingdom of Belgium - Federal Government, C=BE"),
                new X500Principal("CN=Belgium Root CA4, C=BE")));
        assertEquals("PL", TimestampTrustAnchors.countryOf(new X500Principal("CN=Certum QTST 2023"),
                new X500Principal("CN=Certum QTST CA, O=Asseco Data Systems S.A., C=pl")));
        assertNull(TimestampTrustAnchors.countryOf(new X500Principal("CN=Somewhere"), null));
        assertNull(TimestampTrustAnchors.countryOf(null, null));
    }

    @Test
    void aDocumentWithoutTimestampsHasNoTimestampCountry() {
        assertEquals(List.of(), TimestampTrustAnchors.timestampCountries(
                "%PDF-1.7\nnot signed\n%%EOF".getBytes(StandardCharsets.ISO_8859_1), "sig"));
    }
}
