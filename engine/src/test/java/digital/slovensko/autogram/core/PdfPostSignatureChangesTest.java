package digital.slovensko.autogram.core;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSName;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

class PdfPostSignatureChangesTest {
    @Test
    void nothingAfterTheSignedRevisionIsNoChange() throws Exception {
        var signed = ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false);
        assertEquals(List.of(), PdfPostSignatureChanges.find(signed, signed.length));
    }

    @Test
    void aSecondSignatureWithAVisibleStampIsAChangeToTheFirst() throws Exception {
        var signed = ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false);
        var twice = ConversionTestPdfs.sign(signed, true);
        assertFalse(PdfPostSignatureChanges.find(twice, signed.length).isEmpty());
        assertEquals(List.of(), PdfPostSignatureChanges.find(twice, twice.length));
    }

    @Test
    void aPageRelabelledAsASignatureIsNamed() throws Exception {
        var signed = ConversionTestPdfs.sign(ConversionTestPdfs.samplePdf(), false);
        byte[] changed;
        try (var document = Loader.loadPDF(signed)) {
            document.getPage(0).getCOSObject().setItem(COSName.TYPE, COSName.SIG);
            var output = new ByteArrayOutputStream();
            document.saveIncremental(output);
            changed = output.toByteArray();
        }
        var reasons = PdfPostSignatureChanges.find(changed, signed.length);
        assertEquals(1, reasons.size(), reasons.toString());
    }

    @Test
    void bytesThatAreNoPdfAreAReason() {
        var reasons = PdfPostSignatureChanges.find("not a pdf at all, twice as long".getBytes(), 10);
        assertFalse(reasons.isEmpty());
    }
}
