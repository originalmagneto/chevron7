<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:egonp="http://schemas.gov.sk/form/50349287.ConversionRecordOfPaperToElectronicDocument_2021.sk/1.2">
  <xsl:output method="text" indent="yes" omit-xml-declaration="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <xsl:text>Záznam o zaručenej konverzii z listinej podoby do elektronického dokumentu</xsl:text>
    <xsl:for-each select="egonp:ConversionRecord">
      <xsl:text>&#xa;</xsl:text>

      <xsl:text>&#xa;Údaje o pôvodných listinných dokumentoch: </xsl:text>
      <xsl:apply-templates select="egonp:OriginalDocumentInfo"></xsl:apply-templates>

      <xsl:text>&#xa;</xsl:text>
      <xsl:text>&#xa;Údaje novovzniknutého dokumentu v elektronickej podobe: </xsl:text>
      <xsl:apply-templates select="egonp:NewDocumentInfo/egonp:NewDocumentName"></xsl:apply-templates>
      <xsl:apply-templates select="egonp:NewDocumentInfo/egonp:NewDocumentType"></xsl:apply-templates>
      <xsl:apply-templates select="egonp:NewDocumentInfo/egonp:ContentType"></xsl:apply-templates>
      <xsl:apply-templates select="egonp:NewDocumentInfo"></xsl:apply-templates>

      <xsl:text>&#xa;</xsl:text>
      <xsl:text>&#xa;Údaje o zaručenej konverzii: </xsl:text>
      <xsl:apply-templates select="egonp:ConversionRecordEvidenceNumber"></xsl:apply-templates>
      <xsl:apply-templates select="egonp:ConversionExecutionDateTime"></xsl:apply-templates>
      <xsl:apply-templates select="egonp:UsedDevice"></xsl:apply-templates>

      <xsl:text>&#xa;</xsl:text>
      <xsl:text>&#xa;Zaručenú konverziu vykonal: </xsl:text>
      <xsl:apply-templates select="egonp:PersonPerformingConversion"></xsl:apply-templates>

    </xsl:for-each>
  </xsl:template>

  <!-- ORIGINAL DOKUMENT -->
  <xsl:template match="egonp:OriginalDocumentInfo">
    <xsl:text>&#xa;</xsl:text>
    <xsl:text>&#xa;</xsl:text> Pôvodný dokument v listinnej podobe
    <xsl:apply-templates select="egonp:OriginalDocumentName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentOrder"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentType"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentNumberOfSheets"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentNonEmptyPageCount"></xsl:apply-templates>

    <xsl:text>&#xa;</xsl:text>
    <xsl:text>&#xa;  Formát papiera pôvodného dokumentu</xsl:text>
    <xsl:apply-templates select="egonp:OriginalDocumentPaperSize"></xsl:apply-templates>

    <xsl:text>&#xa;</xsl:text>
    <xsl:choose>
      <xsl:when test="count(egonp:DocumentSecurityElementsDetails) = 0">
        <xsl:text>&#xa;  Pôvodný dokument neobsahuje bezpečnostné prvky</xsl:text>
      </xsl:when>
      <xsl:otherwise>
        <xsl:text>&#xa;  Bezpečnostné prvky pôvodného dokumentu</xsl:text>
        <xsl:apply-templates select="egonp:DocumentSecurityElementsDetails"></xsl:apply-templates>
      </xsl:otherwise>
    </xsl:choose>    
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentName">
    Názov dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentOrder">
    Poradie dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentType">
    Druh dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentNumberOfSheets">
    Počet listov pôvodného dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentNonEmptyPageCount">
    Počet neprázdnych strán pôvodného dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:PaperSize">
    Formát papiera: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:PaperSizeOther">
    <xsl:if test=". and string-length(.) &gt; 0">
    Iný formát papiera: <xsl:value-of select="."></xsl:value-of>
    </xsl:if>
  </xsl:template>

  <xsl:template match="egonp:PaperSizeNumberOfSheets">
    Počet listov: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentPaperSize">
    <xsl:text>&#xa;</xsl:text>
    <xsl:text>&#xa;   Formát papiera:</xsl:text>
    <xsl:apply-templates select="egonp:PaperSize"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:PaperSizeOther"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:PaperSizeNumberOfSheets"></xsl:apply-templates>
  </xsl:template>

  <xsl:template match="egonp:DocumentSecurityElementsDetails">
    <xsl:text>&#xa;</xsl:text>
    <xsl:text>&#xa;   Bezpečnostný prvok:</xsl:text>
    <xsl:apply-templates select="egonp:OriginalDocumentSecurityElementsDescription"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentSecurityElementsDescriptionOther"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentSecurityElementsPage"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentSecurityElementsSheet"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentSecurityElementsLocation"></xsl:apply-templates>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentSecurityElementsDescription">
    Slovný opis: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentSecurityElementsDescriptionOther">
    <xsl:if test=". and string-length(.) &gt; 0">
    Iný slovný opis: <xsl:value-of select="."></xsl:value-of>
    </xsl:if>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentSecurityElementsPage">
    Výskyt na strane: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentSecurityElementsSheet">
    Výskyt na liste: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentSecurityElementsLocation">
    Miesto umiestnenia na strane dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <!-- NOVY DOKUMENT -->
  <xsl:template match="egonp:NewDocumentInfo">
    <xsl:apply-templates select="egonp:NewDocumentFormat/egonp:Codelist/egonp:CodelistItem/egonp:ItemName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:ElectronicFingerprintValue"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:ElectronicFingerprintCalculationMethod/egonp:Codelist/egonp:CodelistItem/egonp:ItemName"></xsl:apply-templates>
  </xsl:template>

  <xsl:template match="egonp:NewDocumentInfo/egonp:NewDocumentName">
    Názov dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
    <xsl:template match="egonp:NewDocumentInfo/egonp:NewDocumentType">
    Druh dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:NewDocumentInfo/egonp:ContentType">
    Typ obsahu dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:NewDocumentFormat/egonp:Codelist/egonp:CodelistItem/egonp:ItemName">
    Formát dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:ElectronicFingerprintValue">
    Hodnota elektronického odtlačku: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:ElectronicFingerprintCalculationMethod/egonp:Codelist/egonp:CodelistItem/egonp:ItemName">
    Funkcia použitá na výpočet elektronického odtlačku: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ConversionRecordEvidenceNumber">
    Evidenčné číslo záznamu o zaručenej konverzii: <xsl:value-of select="substring-after(.,'https://data.gov.sk/id/egov/conversion-record/')"></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:UsedDevice">
    Použité zariadenie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ConversionExecutionDateTime">
    Dátum a čas vykonania zaručenej konverzie: <xsl:call-template name="formatToSkDateTimeZone">
      <xsl:with-param name="dateTime" select="." />
    </xsl:call-template>
  </xsl:template>

  <!-- OSOBA VYKONAVAJUCA KONVERZIU -->
  <xsl:template match="egonp:PersonPerformingConversion">
    <xsl:apply-templates select="egonp:PersonData/egonp:ID/egonp:IdentifierValue"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:PersonData/egonp:LegalSubject/egonp:Name"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:GivenName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:FamilyName"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
  </xsl:template>

  <xsl:template match="egonp:ID/egonp:IdentifierValue">
    Identifikačné číslo: <xsl:value-of select="substring-after(.,'https://data.gov.sk/id/legal-subject/')"></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:LegalSubject/egonp:Name">
    Názov právnickej osoby: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:GivenName">
    Meno: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:FamilyName">
    Priezvisko: <xsl:value-of select="concat(' ', . , ' ')"></xsl:value-of>
  </xsl:template>

  <!-- NOVY FORMAT CASOVYCH ZON -->
  <xsl:template name="formatToSkDateTimeZone">
    <xsl:param name="dateTime" />
    <xsl:variable name="dateSubstring" select="substring($dateTime, 1, 10)" />
    <xsl:variable name="timeSubstring" select="substring($dateTime, 12, 8)" />

    <xsl:variable name="timezoneSubstring" select="substring($dateTime, 20, 6)" />
    <xsl:variable name="timezoneSubstringUTC" select="substring($dateTime, 20, 7)" />
    <xsl:variable name="timezoneSubstringChar" select="substring($dateTime, 20, 1)" />

    <xsl:variable name="timeZoneString">
      <xsl:choose>
        <xsl:when test="contains($timezoneSubstringChar, 'Z') or contains($timezoneSubstringUTC, '+/-0:00')">
          <xsl:text>časové pásmo UTC</xsl:text>
        </xsl:when>
        <xsl:otherwise>
          <xsl:choose>
            <xsl:when test="contains($timezoneSubstring, '+02:00')">
              <xsl:text>časové pásmo +02:00</xsl:text>
            </xsl:when>
            <xsl:when test="contains($timezoneSubstring, '+01:00')">
              <xsl:text>časové pásmo +01:00</xsl:text>
            </xsl:when>
            <xsl:otherwise>
              <xsl:text>časové pásmo </xsl:text><xsl:value-of select="$timezoneSubstring"></xsl:value-of>
            </xsl:otherwise>
          </xsl:choose>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <xsl:variable name="dateString">
      <xsl:choose>
        <xsl:when test="$dateSubstring != '' and string-length($dateSubstring)=10 and string(number(substring($dateSubstring, 1, 4))) != 'NaN' ">
          <xsl:value-of select="concat(substring($dateSubstring, 9, 2), '.', substring($dateSubstring, 6, 2), '.', substring($dateSubstring, 1, 4))" />
        </xsl:when>
        <xsl:otherwise>
          <xsl:value-of select="$dateSubstring"></xsl:value-of>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <xsl:variable name="timeString">
      <xsl:if test="$timeSubstring != ''">
        <xsl:value-of select="substring($timeSubstring, 1, 5)" />
      </xsl:if>
    </xsl:variable>

    <xsl:value-of select="concat($dateString,' ',$timeString,' ',$timeZoneString)"/>

  </xsl:template>
  <!-- KONIEC NOVY FORMAT CASOVYCH ZON-->

</xsl:stylesheet>