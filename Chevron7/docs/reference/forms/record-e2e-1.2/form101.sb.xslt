<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:egonp="http://schemas.gov.sk/form/50349287.ConversionRecordOfElectronicDocumentToElectronicDocument_2021.sk/1.2">
  <xsl:output method="text" indent="yes" omit-xml-declaration="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <xsl:text>Záznam o zaručenej konverzii z elektronickej podoby do elektronického dokumentu</xsl:text>
    <xsl:text>&#xa;</xsl:text>
      <xsl:for-each select="egonp:ConversionRecord">
            <xsl:text>&#xa;Údaje o pôvodných elektronických dokumentoch: </xsl:text>
            <xsl:text>&#xa;</xsl:text>
            <xsl:apply-templates select="egonp:OriginalDocumentInfo"></xsl:apply-templates>

            <xsl:if test="count(egonp:OriginalDocumentTimestamp) > 0">
              <xsl:text>&#xa;Údaje o elektronických časových pečiatkach zahrňujúcich pôvodné dokumenty v elektronickej podobe:</xsl:text>
              <xsl:text>&#xa;</xsl:text>
              <xsl:apply-templates select="egonp:OriginalDocumentTimestamp"></xsl:apply-templates>
            </xsl:if>
            <xsl:choose>
              <xsl:when test="count(egonp:Authorization) = 0 and count(egonp:OriginalDocumentTimestamp) = 0">
                <xsl:text>&#xa;Bezpečnostné prvky pôvodného dokumentu v elektronickej podobe: </xsl:text>
                <xsl:text>&#xa;  Pôvodný dokument neobsahuje bezpečnostné prvky</xsl:text>
              </xsl:when>
              <xsl:otherwise>
                <xsl:if test="count(egonp:Authorization) > 0">
                  <xsl:text>&#xa;Bezpečnostné prvky pôvodného dokumentu v elektronickej podobe: </xsl:text>
                  <xsl:apply-templates select="egonp:Authorization"></xsl:apply-templates>
                </xsl:if>
              </xsl:otherwise>
            </xsl:choose>        
          
            <xsl:text>&#xa;&#xa;Údaje novovzniknutého dokumentu v elektronickej podobe: </xsl:text>
            <xsl:apply-templates select="egonp:NewDocumentInfo/egonp:NewDocumentName"></xsl:apply-templates>
            <xsl:apply-templates select="egonp:NewDocumentInfo/egonp:NewDocumentType"></xsl:apply-templates>
            <xsl:apply-templates select="egonp:NewDocumentInfo/egonp:ContentType"></xsl:apply-templates>
            <xsl:apply-templates select="egonp:NewDocumentInfo"></xsl:apply-templates>

            <xsl:text>&#xa;&#xa;Údaje o zaručenej konverzii: </xsl:text>
            <xsl:apply-templates select="egonp:ConversionRecordEvidenceNumber"></xsl:apply-templates>
            <xsl:apply-templates select="egonp:UsedDevice"></xsl:apply-templates> 
            <xsl:apply-templates select="egonp:ConversionExecutionDateTime"></xsl:apply-templates>

            <xsl:text>&#xa;&#xa;Zaručenú konverziu vykonal: </xsl:text>
            <xsl:apply-templates select="egonp:PersonPerformingConversion"></xsl:apply-templates>
      </xsl:for-each>
  </xsl:template>

  <!-- ORIGINAL DOKUMENT -->
  <xsl:template match="egonp:ConversionRecord/egonp:OriginalDocumentInfo">
    <xsl:text>&#xa;  Pôvodný dokument v elektronickej podobe</xsl:text>
    <xsl:apply-templates select="egonp:OriginalDocumentName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentType"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:ContentType"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentFormat/egonp:Codelist/egonp:CodelistItem/egonp:ItemName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentFormatOther"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:ElectronicFingerprintValue"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:ElectronicFingerprintCalculationMethod/egonp:Codelist/egonp:CodelistItem/egonp:ItemName"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
  </xsl:template>

  <xsl:template match="egonp:ConversionRecord/egonp:OriginalDocumentInfo/egonp:OriginalDocumentName">
    Názov dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentFormat/egonp:Codelist/egonp:CodelistItem/egonp:ItemName">
    Formát dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentFormatOther">
    <xsl:if test=". and string-length(.) &gt; 0">
    Iný formát dokumentu: <xsl:value-of select="."></xsl:value-of>
    </xsl:if>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentType">
    Druh dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ContentType">
    Typ obsahu pôvodného dokumentu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ElectronicFingerprintValue">
    Hodnota elektronického odtlačku: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:ElectronicFingerprintCalculationMethod/egonp:Codelist/egonp:CodelistItem/egonp:ItemName">
    Funkcia použitá na výpočet elektronického odtlačku: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentTimestamp">
      <xsl:text>&#xa; Časová pečiatka pôvodného dokumentu v elektronickej podobe</xsl:text>
      <xsl:text>&#xa;</xsl:text>
      <xsl:apply-templates select="egonp:TimeStampName"></xsl:apply-templates>
      <xsl:text>&#xa;</xsl:text>
      <xsl:apply-templates select="egonp:DSId"></xsl:apply-templates>
      <xsl:for-each select="egonp:OriginalDocumentInfo">
        <xsl:apply-templates select="."></xsl:apply-templates>
        <xsl:text>&#xa;</xsl:text>
      </xsl:for-each>
      <xsl:apply-templates select="egonp:TimeStampType"></xsl:apply-templates>
      <xsl:text>&#xa;</xsl:text>
      <xsl:apply-templates select="egonp:TimeStampState"></xsl:apply-templates>
      <xsl:text>&#xa;</xsl:text>
      <xsl:apply-templates select="egonp:TimeStampCreated"></xsl:apply-templates>
      <xsl:text>&#xa;</xsl:text>
      <xsl:apply-templates select="egonp:TimeStampPublisher"></xsl:apply-templates>
      <xsl:text>&#xa;</xsl:text>
      <xsl:apply-templates select="egonp:TimeStampValidationTime"></xsl:apply-templates>
      <xsl:text>&#xa;</xsl:text>   
  </xsl:template>
  
  <!--Casove peciatky povodnych dokumentov - zaciatok-->
  <xsl:template match="egonp:OriginalDocumentTimestamp/egonp:TimeStampName">
    <xsl:text>    Názov elektronickej časovej pečiatky: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:DSId">
    <xsl:text>    Identifikátor časovej pečiatky: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
    <xsl:text>&#xa;</xsl:text>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentTimestamp/egonp:TimeStampType">
    <xsl:text>    Typ elektronickej časovej pečiatky: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentTimestamp/egonp:TimeStampState">
    <xsl:text>    Výsledok overenia platnosti časovej pečiatky: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentTimestamp/egonp:TimeStampCreated">
    <xsl:text>    Čas vystavenia elektronickej časovej pečiatky: </xsl:text>
    <xsl:call-template name="formatToSkDateTimeZone">
      <xsl:with-param name="dateTime" select="." />
    </xsl:call-template>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentTimestamp/egonp:TimeStampPublisher">
    <xsl:text>    Vydavateľ elektronickej časovej pečiatky: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentTimestamp/egonp:TimeStampValidationTime">
    <xsl:text>    Čas overenia elektronickej časovej pečiatky: </xsl:text>
    <xsl:call-template name="formatToSkDateTimeZone">
      <xsl:with-param name="dateTime" select="." />
    </xsl:call-template>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentTimestamp/egonp:OriginalDocumentInfo">
    <xsl:text>    Elektronický dokument viazaný k elektronickej časovej pečiatke</xsl:text>
    <xsl:text>&#xa;</xsl:text>
    <xsl:apply-templates select="egonp:OriginalDocumentName"></xsl:apply-templates>
  </xsl:template>
  <xsl:template match="egonp:OriginalDocumentName">
    <xsl:text>      Názov dokumentu: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <!--Casove peciatky povodnych dokumentov - koniec-->

  <!--AUTORIZACIA-->
  <xsl:template match="egonp:Authorization">
    <xsl:text>&#xa;&#xa;  Autorizácia</xsl:text>
    <xsl:apply-templates select="egonp:AuthorizationName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:DSId"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationType"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OriginalDocumentAuthorization"></xsl:apply-templates>
  </xsl:template>
                
  <xsl:template match="egonp:Authorization/egonp:AuthorizationName">
    Názov autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:Authorization/egonp:DSId">
    Identifikátor autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  
  <xsl:template match="egonp:Authorization/egonp:AuthorizationType">
    Typ autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:Authorization/egonp:OriginalDocumentAuthorization">
    <xsl:text>&#xa;  Autorizácia pôvodného elektronického dokumentu</xsl:text>
    <xsl:apply-templates select="egonp:OriginalDocumentInfo"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizedTimeStamp"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizedAuthorization"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationState"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationTime"></xsl:apply-templates>
  	<xsl:apply-templates select="egonp:ElectronicSignature"></xsl:apply-templates> 
		<xsl:apply-templates select="egonp:ValidityVerificationResult"></xsl:apply-templates>    
    <xsl:apply-templates select="egonp:AuthorizationValidationTime"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationTimeAfterTimeStampName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationTimeAfter"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationTimeBeforeTimeStampName"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationTimeBefore"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:AuthorizationPerson"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:CertificateType"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:OtherAuthorizationInfo"></xsl:apply-templates>
    <xsl:for-each select="egonp:TimeStamp">
      <xsl:apply-templates select="."></xsl:apply-templates>
    </xsl:for-each>
  </xsl:template>
  
  <xsl:template match="egonp:OriginalDocumentAuthorization/egonp:OriginalDocumentInfo">
    Autorizovaný elektronický dokument:
    <xsl:apply-templates select="egonp:OriginalDocumentName"></xsl:apply-templates>
  </xsl:template>
  
  <xsl:template match="egonp:AuthorizedTimeStamp">
    <xsl:text>&#xa;</xsl:text>
    <xsl:text>    Autorizovaná časová pečiatka:</xsl:text>
    <xsl:apply-templates select="egonp:AuthorizedTimeStampName"></xsl:apply-templates>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentAuthorization/egonp:AuthorizedAuthorization">
    <xsl:text>&#xa;</xsl:text>
    <xsl:text>    Autorizovaná autorizácia:</xsl:text>
    <xsl:apply-templates select="egonp:AuthorizationName"></xsl:apply-templates>
  </xsl:template>

  <xsl:template match="egonp:AuthorizedTimeStamp/egonp:AuthorizedTimeStampName">
      Názov časovej pečiatky:  <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:AuthorizedAuthorization/egonp:AuthorizationName">
      Názov autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OriginalDocumentAuthorization/egonp:OriginalDocumentInfo/egonp:OriginalDocumentName">
    <xsl:text>  Názov dokumentu: </xsl:text><xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationState">
    Výsledok overenia platnosti autorizácie: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationTime">
    Deklarovaný čas autorizácie: <xsl:call-template name="formatToSkDateTimeZone">
      <xsl:with-param name="dateTime" select="." />
    </xsl:call-template>
  </xsl:template>

  <xsl:template match="egonp:ElectronicSignature">
    Hodnota elektronického podpisu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
    
  <xsl:template match="egonp:ValidityVerificationResult">
    Výsledok overenia autorizácie a časovej pečiatky: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationValidationTime">
    Čas overenia autorizácie: <xsl:call-template name="formatToSkDateTimeZone">
      <xsl:with-param name="dateTime" select="." />
    </xsl:call-template>
  </xsl:template>
  
  <xsl:template match="egonp:AuthorizationTimeBefore">
    Potvrdený najskorší čas po autorizácii: <xsl:call-template name="formatToSkDateTimeZone">
    <xsl:with-param name="dateTime" select="." />
    </xsl:call-template>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationTimeAfter">
    Potvrdený najneskorší čas pred autorizáciou: <xsl:call-template name="formatToSkDateTimeZone">
      <xsl:with-param name="dateTime" select="." />
    </xsl:call-template>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationTimeBeforeTimeStampName">
    Názov časovej pečiatky pre potvrdenie času po autorizácii: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationTimeAfterTimeStampName">
    Názov časovej pečiatky pre potvrdenie času pred autorizáciou: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:AuthorizationPerson">
      <xsl:text>&#xa;    Identifikácia držiteľa prostriedku autorizácie:  </xsl:text>
      <xsl:apply-templates select="egonp:PersonID"> </xsl:apply-templates> 
      <xsl:apply-templates select="egonp:Mandant"> </xsl:apply-templates>
      <xsl:apply-templates select="egonp:Mandate"></xsl:apply-templates>
  </xsl:template>
  
  <xsl:template match="egonp:PersonID">&#xa;      Identifikácia autorizujúcej osoby: <xsl:value-of select="."></xsl:value-of>; </xsl:template>

  <xsl:template match="egonp:Mandant">&#xa;      Zastúpená osoba: <xsl:value-of select="."></xsl:value-of>; </xsl:template>

  <xsl:template match="egonp:Mandate">&#xa;      Mandát: <xsl:value-of select="."> </xsl:value-of>; </xsl:template>
  
  <xsl:template match="egonp:TimeStamp">
    <xsl:text>&#xa;    Časová pečiatka pripojená k prostriedku autorizácie:</xsl:text>
    <xsl:text>&#xa;</xsl:text>
    <xsl:apply-templates select="egonp:TimeStampName"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
    <xsl:apply-templates select="egonp:DSId"></xsl:apply-templates>    
    <xsl:apply-templates select="egonp:TimeStampType"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
    <xsl:apply-templates select="egonp:TimeStampState"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
    <xsl:apply-templates select="egonp:TimeStampCreated"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
    <xsl:apply-templates select="egonp:TimeStampPublisher"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
    <xsl:apply-templates select="egonp:TimeStampValidationTime"></xsl:apply-templates>  
  </xsl:template>

  <xsl:template match="egonp:TimeStampName">
    <xsl:text>        Názov časovej pečiatky: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  
  <xsl:template match="egonp:TimeStamp/egonp:DSId">
    <xsl:text>        Identifikátor časovej pečiatky:  </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
    <xsl:text>&#xa;</xsl:text>
  </xsl:template>  

  <xsl:template match="egonp:TimeStampType">
    <xsl:text>        Typ časovej pečiatky: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:TimeStampState">
    <xsl:text>        Výsledok overenia platnosti časovej pečiatky: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:TimeStampCreated">
    <xsl:text>        Čas vystavenia časovej pečiatky: </xsl:text>
    <xsl:call-template name="formatToSkDateTimeZone">
      <xsl:with-param name="dateTime" select="." />
    </xsl:call-template>
  </xsl:template>

  <xsl:template match="egonp:TimeStampPublisher">
    <xsl:text>        Vydavateľ časovej pečiatky: </xsl:text>
    <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:TimeStampValidationTime">
    <xsl:text>        Čas overenia časovej pečiatky: </xsl:text>
    <xsl:call-template name="formatToSkDateTimeZone">
      <xsl:with-param name="dateTime" select="." />
    </xsl:call-template>
  </xsl:template>

  <xsl:template match="egonp:CertificateType">
    Typ certifikátu: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:OtherAuthorizationInfo">
    Ďalšie údaje o autorizácii: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>
  <!--AUTORIZACIA KONIEC-->
  
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

  <xsl:template match="egonp:PersonPerformingConversion">
    <xsl:apply-templates select="egonp:PersonData/egonp:ID/egonp:IdentifierValue"></xsl:apply-templates>
    <xsl:apply-templates select="egonp:PersonData/egonp:LegalSubject/egonp:Name"></xsl:apply-templates>
    Meno: <xsl:apply-templates select="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:GivenName"></xsl:apply-templates>
    Priezvisko: <xsl:apply-templates select="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:FamilyName"></xsl:apply-templates>
    <xsl:text>&#xa;</xsl:text>
  </xsl:template>

  <xsl:template match="egonp:PersonData/egonp:ID/egonp:IdentifierValue">
    Identifikačné číslo: <xsl:value-of select="substring-after(.,'https://data.gov.sk/id/legal-subject/')"></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:PersonData/egonp:LegalSubject/egonp:Name">
    Názov právnickej osoby: <xsl:value-of select="."></xsl:value-of>
  </xsl:template>

  <xsl:template match="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:GivenName"> <xsl:value-of select="."></xsl:value-of> </xsl:template>

  <xsl:template match="egonp:PersonData/egonp:PhysicalPerson/egonp:PersonName/egonp:FamilyName"><xsl:value-of select="concat(' ', . , ' ')"></xsl:value-of> </xsl:template>

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