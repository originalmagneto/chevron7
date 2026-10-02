package digital.slovensko.autogram.ui.machine;

import digital.slovensko.autogram.core.SignatureValidator;
import digital.slovensko.autogram.util.DSSUtils;
import eu.europa.esig.dss.model.InMemoryDocument;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.spi.x509.tsp.TimestampToken;

import javax.naming.InvalidNameException;
import javax.naming.ldap.LdapName;
import javax.security.auth.x500.X500Principal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import java.util.function.BiFunction;
import java.util.function.Supplier;
import java.util.stream.Collectors;

/**
 * Tells whether a signature's timestamp could not be shown qualified only because the
 * trusted list of its authority's country did not load. The country is read from the
 * timestamp's own certificate (subject, then issuer), which is how the national lists
 * are split: a BOSA timestamp needs the Belgian list, a Certum one the Polish list.
 */
final class TimestampTrustAnchors {
    private TimestampTrustAnchors() {
    }

    static MachineSigningService.MissingTrustAnchor production() {
        return of(() -> SignatureValidator.getInstance().unavailableTrustedListCountries(),
                TimestampTrustAnchors::timestampCountries);
    }

    static MachineSigningService.MissingTrustAnchor of(Supplier<? extends Collection<String>> unavailableCountries,
            BiFunction<byte[], String, List<String>> timestampCountries) {
        return (content, signatureId) -> {
            var unavailable = unavailableCountries.get().stream().map(TimestampTrustAnchors::normalized)
                    .collect(Collectors.toSet());
            if (unavailable.isEmpty()) {
                return null;
            }
            return timestampCountries.apply(content, signatureId).stream().map(TimestampTrustAnchors::normalized)
                    .filter(unavailable::contains).findFirst().orElse(null);
        };
    }

    /** The countries of the signature timestamps of one signature, empty when none can be read. */
    static List<String> timestampCountries(byte[] content, String signatureId) {
        try {
            var validator = DSSUtils.createDocumentValidator(new InMemoryDocument(content));
            if (validator == null) {
                return List.of();
            }
            validator.setCertificateVerifier(new CommonCertificateVerifier());
            var countries = new ArrayList<String>();
            for (var signature : validator.getSignatures()) {
                if (!signature.getId().equals(signatureId)) {
                    continue;
                }
                for (var timestamp : signature.getSignatureTimestamps()) {
                    var country = timestampCountry(timestamp);
                    if (country != null && !countries.contains(country)) {
                        countries.add(country);
                    }
                }
            }
            return List.copyOf(countries);
        } catch (RuntimeException exception) {
            return List.of();
        }
    }

    private static String timestampCountry(TimestampToken timestamp) {
        var signer = timestamp.getCertificates().stream().filter(timestamp::isSignedBy).findFirst().orElse(null);
        if (signer != null) {
            return countryOf(signer.getSubject().getPrincipal(), signer.getIssuer().getPrincipal());
        }
        return countryOf(null, timestamp.getIssuerX500Principal());
    }

    static String countryOf(X500Principal subject, X500Principal issuer) {
        var country = country(subject);
        return country != null ? country : country(issuer);
    }

    private static String country(X500Principal principal) {
        if (principal == null) {
            return null;
        }
        try {
            for (var rdn : new LdapName(principal.getName(X500Principal.RFC2253)).getRdns()) {
                if ("C".equalsIgnoreCase(rdn.getType()) && rdn.getValue() != null) {
                    var value = normalized(rdn.getValue().toString());
                    return value.isEmpty() ? null : value;
                }
            }
        } catch (InvalidNameException exception) {
            return null;
        }
        return null;
    }

    private static String normalized(String country) {
        return country.trim().toUpperCase(Locale.ROOT);
    }
}
