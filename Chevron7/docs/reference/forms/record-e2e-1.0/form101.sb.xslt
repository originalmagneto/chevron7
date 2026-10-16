<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:egonp="https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfElectronicDocumentToElectronicDocument.sk/1.0">
  <xsl:output method="text" indent="yes" omit-xml-declaration="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <xsl:text>Záznam o zaručenej konverzii z elektronickej podoby do elektronického dokumentu</xsl:text>
    <xsl:text>&#xa;</xsl:text>
      <xsl:for-each select="egonp:ConversionRecord">
            <xsl:text>&#xa;Údaje o pôvodných elektronických dokumentoch: </xsl:text>
            <xsl:text>&#xa;</xsl:text>
            <xsl:apply-templates select="egonp:OriginalDocumentInfo"></xsl:apply-templates>
          
            <xsl:text>&#xa;Autorizačné prvky pôvodného dokumentu v elektronickej podobe: </xsl:text>
            <xsl:apply-templates select="egonp:OriginalDocumentAuthorization/egonp:OriginalDocumentAuthorizationOccurance"></xsl:apply-templates>
            <xsl:apply-templates select="egonp:OriginalDocumentAuthorization/egonp:OriginalDocumentAuthorization"></xsl:apply-templates>
          
            <xsl:text>&#xa;Údaje novovzniknutého dokumentu v elektronickej podobe: </xsl:text>
            <xsl:apply-templates select="egonp:NewDocumentInfo"></xsl:apply-templates>

            <xsl:text>&#xa;Údaje o zaručenej konverzii: </xsl:text>
            <xsl:apply-templates select="egonp:ConversionRecordEvidenceNumber"></xsl:apply-templates>
            <xsl:apply-templates select="egonp:UsedDevice"></xsl:apply-templates> 
            <xsl:apply-templates select="egonp:ConversionExecutionDateTime"></xsl:apply-templates>

            <xsl:text>&#xa;Zaručenú konverziu vykonal: </xsl:text>
            <xsl:apply-templates select="egonp:PersonPerformingConversion"></xsl:apply-templates>

      </xsl:for-each>
  </xsl:template>

  <xsl:template match="egonp:ConversionRecord">
    <xsl:text>&#xa;</xsl:text>Záznam č. <xsl:value-of select="position()"></xsl:value-of><xsl:text>&#xa;</xsl:text>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentsQuantity">
    Formát pôvodného dokumentu: <xsl:value-of select="@Format"></xsl:value-of>, Počet dokumentov: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ExecutedConversionTypesQuantity">
    Počet konverzií z elektronickej podoby do iného formátu v elektronickej podobe: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <!-- ORIGINAL DOKUMENT -->
  <xsl:template match="egonp:OriginalDocumentInfo">
    <xsl:text>&#xa;</xsl:text>  Originálny dokument č. <xsl:value-of select="position()"></xsl:value-of>
    <xsl:apply-templates select="egonp:OriginalDocumentName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentFormat"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentType"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:ElectronicFingerprintValue"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:ElectronicFingerprintCalculationMethod"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentName">
    Názov pôvodného dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentFormat">
    Formát pôvodného dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentType">
    Typ pôvodného dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ElectronicFingerprintValue">
    Hodnota el. odtlačku: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ElectronicFingerprintCalculationMethod">
    Funkcia použitá na výpočet elektronického odtlačku: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <!-- AUTORIZACIA POVODNEHO DOKUMENTU -->
  <xsl:template match="egonp:OriginalDocumentAuthorization/egonp:OriginalDocumentAuthorizationOccurance">
    Prítomnosť autorizačných prvkov: 
      <xsl:choose>
        <xsl:when test=".">
          <xsl:text>Dokument obsahuje autorizačné prvky.</xsl:text>
        </xsl:when>
        <xsl:otherwise>
          <xsl:text>Dokument neobsahuje autorizačné prvky.</xsl:text>
        </xsl:otherwise>
      </xsl:choose>  
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentAuthorization/egonp:OriginalDocumentAuthorization">
    <xsl:apply-templates select="egonp:AuthorizationType"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizedDocument/egonp:AuthorizedDocumentName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationState"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationTime"></xsl:apply-templates>
  	<xsl:apply-templates select="egonp:ElectronicSignature"></xsl:apply-templates> 
		<xsl:apply-templates select="egonp:ValidityVerificationResult"></xsl:apply-templates>    
    <xsl:apply-templates select="egonp:AuthorizationValidationTime"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationLocation"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationPerson"></xsl:apply-templates>
		<xsl:apply-templates select="egonp:TimeStamp"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OtherAutorizationInfo"></xsl:apply-templates>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationType">
    Typ autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
 
  <xsl:template match="egonp:AuthorizedDocument/egonp:AuthorizedDocumentName">
    Názov dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationState">
    Stav autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationTime">
    Dátum a čas vykonania autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ElectronicSignature">
    Elektronický podpis / pečať: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
    
  <xsl:template match="egonp:ValidityVerificationResult">
    Overenie platnosti dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>  
  
  <xsl:template match="egonp:AuthorizationValidationTime">
    Dátum a čas overenia platnosti autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>  

  <xsl:template match="egonp:AuthorizationLocation">
    Miesto vykonania autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationPerson">
    Autorizujúca osoba:  <xsl:apply-templates select="egonp:PersonID"> </xsl:apply-templates> <xsl:apply-templates select="egonp:Mandant"> </xsl:apply-templates> <xsl:apply-templates select="egonp:Mandate"></xsl:apply-templates>
  </xsl:template>
  
  <xsl:template match="egonp:PersonID">Identifikátor osoby ktorá vykonala autorizáciu: <xsl:value-of select="."></xsl:value-of>; </xsl:template>

  <xsl:template match="egonp:Mandant">Názov právnickej osoby: <xsl:value-of select="."></xsl:value-of>; </xsl:template>

  <xsl:template match="egonp:Mandate">Oprávnenie: <xsl:value-of select="."> </xsl:value-of>; </xsl:template>
  
  <xsl:template match="egonp:TimeStamp">
    Časová pečiatka:<xsl:apply-templates select="egonp:TimeStampType"></xsl:apply-templates> <xsl:apply-templates select="egonp:TimeStampState"></xsl:apply-templates>   <xsl:apply-templates select="egonp:TimeStampCreated"></xsl:apply-templates> <xsl:apply-templates select="egonp:TimeStampPublisher"></xsl:apply-templates> <xsl:apply-templates select="egonp:TimeStampValidationTime"></xsl:apply-templates>  
  </xsl:template>

  <xsl:template match="egonp:TimeStampType">Typ časovej pečiatky: <xsl:value-of select="."></xsl:value-of>; </xsl:template>

  <xsl:template match="egonp:TimeStampState">Výsledok overenia platnosti časovej pečiatky: <xsl:value-of select="."></xsl:value-of>; </xsl:template>

  <xsl:template match="egonp:TimeStampCreated">Dátum a čas vydania časovej pečiatky: <xsl:value-of select="."></xsl:value-of>; </xsl:template>

  <xsl:template match="egonp:TimeStampPublisher">Vydavateľ časovej pečiatky: <xsl:value-of select="."></xsl:value-of>; </xsl:template>

  <xsl:template match="egonp:TimeStampValidationTime">Dátum a čas overenia platnosti časovej pečiatky: <xsl:value-of select="."></xsl:value-of>; </xsl:template>

  <xsl:template match="egonp:OtherAutorizationInfo">
    Ďalšie údaje o autorizácii: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <!-- NOVY DOKUMENT -->
  <xsl:template match="egonp:NewDocumentInfo">
    <xsl:apply-templates select="egonp:NewDocumentName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:NewDocumentFormat"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:ElectronicFingerprintValue"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:ElectronicFingerprintCalculationMethod"></xsl:apply-templates>
  </xsl:template>

  <xsl:template match="egonp:NewDocumentName">
    Názov nového dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:NewDocumentFormat">
    Formát nového dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ConversionRecordEvidenceNumber">
    Evidenčné číslo záznamu o konverzii: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:UsedDevice">
    Použité zariadenie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ConversionExecutionDateTime">
    Dátum a čas vykonania zaručenej konverzie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:PersonPerformingConversion">
    <xsl:apply-templates select="egonp:PersonData/egonp:ID/egonp:IdentifierValue"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:PersonData/egonp:LegalSubject/egonp:Name"></xsl:apply-templates>
    Meno a priezvisko: <xsl:apply-templates select="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:GivenName"></xsl:apply-templates> <xsl:apply-templates select="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:FamilyName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:PersonData/egonp:PhysicalPerson/egonp:Position"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
  </xsl:template>


  <xsl:template match="egonp:PersonData/egonp:ID/egonp:IdentifierValue">
    Identifikačné číslo: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:PersonData/egonp:LegalSubject/egonp:Name">
    Názov právnickej osoby: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:GivenName"> <xsl:value-of select="."></xsl:value-of> </xsl:template>

  <xsl:template match="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:FamilyName"><xsl:value-of select="concat(' ', . , ' ')"></xsl:value-of> </xsl:template>

  <xsl:template match="egonp:PersonData/egonp:PhysicalPerson/egonp:Position">
    Funkcia alebo pracovné zaradenie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>


  <xsl:template name="booleanToSkString">
    <xsl:param name="boolValue" />
    <xsl:variable name="boolValueString" select="string($boolValue)" />
    <xsl:choose>
      <xsl:when test="$boolValueString = 'true' ">
        <xsl:text>Áno</xsl:text>
      </xsl:when>
      <xsl:when test="$boolValueString = '1' ">
        <xsl:text>Áno</xsl:text>
      </xsl:when>
      <xsl:when test="$boolValueString = 'false' ">
        <xsl:text>Nie</xsl:text>
      </xsl:when>
      <xsl:when test="$boolValueString = '0' ">
        <xsl:text>Nie</xsl:text>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$boolValueString"></xsl:value-of>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  
</xsl:stylesheet>