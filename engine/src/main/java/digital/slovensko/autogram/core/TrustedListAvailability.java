package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.tsl.TLInfo;
import eu.europa.esig.dss.model.tsl.TLValidationJobSummary;
import eu.europa.esig.dss.tsl.sync.SynchronizationStrategy;

import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Which national trusted lists a load actually brought in. A list counts only when it was
 * parsed (downloaded now or taken from its cached copy) and the synchronization strategy
 * lets its certificates into the trusted source, under a list of trusted lists that may be
 * synchronized too: anything else contributes no trust anchor.
 */
public final class TrustedListAvailability {
    private TrustedListAvailability() {
    }

    public static Set<String> availableTerritories(TLValidationJobSummary summary, SynchronizationStrategy strategy) {
        var available = new LinkedHashSet<String>();
        for (var lotl : summary.getLOTLInfos()) {
            if (!parsed(lotl) || !strategy.canBeSynchronized(lotl)) {
                continue;
            }
            for (var list : lotl.getTLInfos()) {
                var territory = territory(list);
                if (territory != null && parsed(list) && strategy.canBeSynchronized(list)) {
                    available.add(territory);
                }
            }
        }
        return Set.copyOf(available);
    }

    /** The configured countries without a list, in configuration order and upper case. */
    public static List<String> unavailable(Collection<String> configured, Set<String> available) {
        var normalizedAvailable = available.stream().map(TrustedListAvailability::normalized)
                .collect(java.util.stream.Collectors.toSet());
        return configured.stream().map(TrustedListAvailability::normalized)
                .filter(country -> !normalizedAvailable.contains(country)).distinct().toList();
    }

    /// The LOTL pointer names a list's country even when the list itself never arrived.
    private static String territory(TLInfo list) {
        var pointer = list.getOtherTSLPointer();
        if (pointer != null && pointer.getSchemeTerritory() != null) {
            return normalized(pointer.getSchemeTerritory());
        }
        var parsing = list.getParsingCacheInfo();
        return parsing == null || parsing.getTerritory() == null ? null : normalized(parsing.getTerritory());
    }

    private static boolean parsed(TLInfo info) {
        return info.getParsingCacheInfo() != null && info.getParsingCacheInfo().isResultExist();
    }

    private static String normalized(String country) {
        return country.trim().toUpperCase(Locale.ROOT);
    }
}
