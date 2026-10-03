package digital.slovensko.autogram.core;

import eu.europa.esig.dss.model.tsl.LOTLInfo;
import eu.europa.esig.dss.model.tsl.OtherTSLPointer;
import eu.europa.esig.dss.model.tsl.ParsingInfoRecord;
import eu.europa.esig.dss.model.tsl.TLInfo;
import eu.europa.esig.dss.model.tsl.TLValidationJobSummary;
import eu.europa.esig.dss.tsl.sync.SynchronizationStrategy;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class TrustedListAvailabilityTest {
    @Test
    void aListCountsOnlyWhenItWasParsedAndCanBeSynchronized() {
        var austria = list("AT", true);
        var belgium = list("BE", false);
        var spain = list("ES", true);
        var lotl = lotl(true, austria, belgium, spain);
        var strategy = mock(SynchronizationStrategy.class);
        when(strategy.canBeSynchronized(lotl)).thenReturn(true);
        when(strategy.canBeSynchronized(austria)).thenReturn(true);
        when(strategy.canBeSynchronized(spain)).thenReturn(false);

        assertEquals(Set.of("AT"), TrustedListAvailability.availableTerritories(summary(lotl), strategy));
    }

    @Test
    void noListCountsWhenTheirListOfTrustedListsCannotBeSynchronized() {
        var austria = list("AT", true);
        var lotl = lotl(true, austria);
        var strategy = mock(SynchronizationStrategy.class);
        when(strategy.canBeSynchronized(lotl)).thenReturn(false);
        when(strategy.canBeSynchronized(austria)).thenReturn(true);

        assertEquals(Set.of(), TrustedListAvailability.availableTerritories(summary(lotl), strategy));
    }

    @Test
    void theUnavailableCountriesAreTheConfiguredOnesWithoutAList() {
        assertEquals(List.of("BE", "ES"), TrustedListAvailability.unavailable(
                List.of("SK", "CZ", "AT", "PL", "HU", "BE", "NL", "ES"),
                Set.of("SK", "CZ", "AT", "PL", "HU", "NL")));
        assertEquals(List.of("BE"), TrustedListAvailability.unavailable(List.of("sk", "be"), Set.of("SK")));
    }

    private static TLInfo list(String territory, boolean parsed) {
        var info = mock(TLInfo.class);
        var pointer = mock(OtherTSLPointer.class);
        when(pointer.getSchemeTerritory()).thenReturn(territory);
        when(info.getOtherTSLPointer()).thenReturn(pointer);
        var parsing = mock(ParsingInfoRecord.class);
        when(parsing.isResultExist()).thenReturn(parsed);
        when(parsing.getTerritory()).thenReturn(parsed ? territory : null);
        when(info.getParsingCacheInfo()).thenReturn(parsing);
        return info;
    }

    private static LOTLInfo lotl(boolean parsed, TLInfo... lists) {
        var info = mock(LOTLInfo.class);
        when(info.getTLInfos()).thenReturn(List.of(lists));
        var parsing = mock(ParsingInfoRecord.class);
        when(parsing.isResultExist()).thenReturn(parsed);
        when(info.getParsingCacheInfo()).thenReturn(parsing);
        return info;
    }

    private static TLValidationJobSummary summary(LOTLInfo... lotls) {
        return new TLValidationJobSummary(List.of(lotls), List.of());
    }
}
