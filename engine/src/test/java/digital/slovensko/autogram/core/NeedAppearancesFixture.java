package digital.slovensko.autogram.core;

import org.apache.pdfbox.cos.COSArray;
import org.apache.pdfbox.cos.COSDictionary;
import org.apache.pdfbox.cos.COSFloat;
import org.apache.pdfbox.cos.COSInteger;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.cos.COSString;
import org.apache.pdfbox.pdfwriter.compress.CompressParameters;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;

import java.io.ByteArrayOutputStream;
import java.io.IOException;

/**
 * A PDF shaped like a JSF web form export (openhtmltopdf): /NeedAppearances true, no /DA,
 * an empty /DR and hidden text widgets (/F 2, Rect [0 0 1 1]) with a value but no /AP,
 * including two top-level "javax" fields that both end in javax.faces.ViewState, one on
 * page 1 and one on page 3. Built at COS level so PDFBox generates no appearance on the way.
 */
public final class NeedAppearancesFixture {
    private NeedAppearancesFixture() {
    }

    public static byte[] webForm(boolean needAppearances) throws IOException {
        return build(needAppearances, false, true);
    }

    /// The same form with a signature dictionary already in the AcroForm.
    public static byte[] signedWebForm() throws IOException {
        return build(true, true, true);
    }

    public static byte[] withoutAcroForm() throws IOException {
        return build(false, false, false);
    }

    private static byte[] build(boolean needAppearances, boolean signed, boolean withAcroForm) throws IOException {
        try (var document = new PDDocument()) {
            var page1 = new PDPage();
            var page2 = new PDPage();
            var page3 = new PDPage();
            document.addPage(page1);
            document.addPage(page2);
            document.addPage(page3);
            if (withAcroForm) {
                var mainForm = hiddenTextWidget("mainForm", "mainForm", page1);
                var commandLink = hiddenTextWidget("j_idt12:j_idt13", "j_idt12:j_idt13", page1);
                var viewStateOnPage1 = hiddenTextWidget("ViewState", "4292776008881557501:3131270279105810742", page1);
                var viewStateOnPage3 = hiddenTextWidget("ViewState", "4292776008881557501:3131270279105810742", page3);
                var javax1 = nonTerminal("javax", nonTerminal("faces", viewStateOnPage1));
                var javax3 = nonTerminal("javax", nonTerminal("faces", viewStateOnPage3));

                var fields = new COSArray();
                fields.add(mainForm);
                fields.add(javax1);
                fields.add(commandLink);
                fields.add(javax3);
                var page1Annotations = new COSArray();
                page1Annotations.add(mainForm);
                page1Annotations.add(commandLink);
                page1Annotations.add(viewStateOnPage1);
                if (signed) {
                    var signatureField = signatureField(page1);
                    fields.add(signatureField);
                    page1Annotations.add(signatureField);
                }
                var page3Annotations = new COSArray();
                page3Annotations.add(viewStateOnPage3);
                page1.getCOSObject().setItem(COSName.ANNOTS, page1Annotations);
                page3.getCOSObject().setItem(COSName.ANNOTS, page3Annotations);

                var acroForm = new COSDictionary();
                acroForm.setItem(COSName.DR, new COSDictionary());
                acroForm.setItem(COSName.FIELDS, fields);
                acroForm.setBoolean(COSName.NEED_APPEARANCES, needAppearances);
                if (signed) {
                    acroForm.setInt(COSName.SIG_FLAGS, 3);
                }
                document.getDocumentCatalog().getCOSObject().setItem(COSName.ACRO_FORM, acroForm);
            }
            var output = new ByteArrayOutputStream();
            document.save(output, CompressParameters.NO_COMPRESSION);
            return output.toByteArray();
        }
    }

    private static COSDictionary hiddenTextWidget(String name, String value, PDPage page) {
        var widget = new COSDictionary();
        widget.setItem(COSName.TYPE, COSName.ANNOT);
        widget.setItem(COSName.SUBTYPE, COSName.WIDGET);
        widget.setItem(COSName.FT, COSName.TX);
        widget.setString(COSName.T, name);
        widget.setString(COSName.V, value);
        widget.setString(COSName.DV, value);
        widget.setInt(COSName.F, 2);
        widget.setItem(COSName.RECT, rect(1));
        widget.setItem(COSName.P, page.getCOSObject());
        return widget;
    }

    private static COSDictionary nonTerminal(String name, COSDictionary kid) {
        var field = new COSDictionary();
        field.setString(COSName.T, name);
        var kids = new COSArray();
        kids.add(kid);
        field.setItem(COSName.KIDS, kids);
        kid.setItem(COSName.PARENT, field);
        return field;
    }

    private static COSDictionary signatureField(PDPage page) {
        var signature = new COSDictionary();
        signature.setItem(COSName.TYPE, COSName.SIG);
        signature.setItem(COSName.FILTER, COSName.ADOBE_PPKLITE);
        signature.setItem(COSName.SUB_FILTER, COSName.getPDFName("ETSI.CAdES.detached"));
        var byteRange = new COSArray();
        for (int index = 0; index < 4; index++) {
            byteRange.add(COSInteger.ZERO);
        }
        signature.setItem(COSName.BYTERANGE, byteRange);
        signature.setItem(COSName.CONTENTS, new COSString(new byte[8]));

        var field = new COSDictionary();
        field.setItem(COSName.TYPE, COSName.ANNOT);
        field.setItem(COSName.SUBTYPE, COSName.WIDGET);
        field.setItem(COSName.FT, COSName.SIG);
        field.setString(COSName.T, "Signature1");
        field.setItem(COSName.V, signature);
        field.setInt(COSName.F, 132);
        field.setItem(COSName.RECT, rect(0));
        field.setItem(COSName.P, page.getCOSObject());
        return field;
    }

    private static COSArray rect(float size) {
        var rect = new COSArray();
        rect.add(new COSFloat(0));
        rect.add(new COSFloat(0));
        rect.add(new COSFloat(size));
        rect.add(new COSFloat(size));
        return rect;
    }
}
