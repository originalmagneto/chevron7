# Príručka Chevron7

Podrobný popis toho, čo Chevron7 robí a ako. Stiahnutie, požiadavky a inštalácia sú v [README](../README.md#stiahnutie), zostavenie zo zdrojov v [DEVELOPMENT.md](../Chevron7/docs/DEVELOPMENT.md).

- [Podpisovanie](#podpisovanie)
- [Podpisovanie na štátnych weboch](#podpisovanie-na-štátnych-weboch)
- [Zaručená konverzia](#zaručená-konverzia)
- [Detekcia bezpečnostných prvkov a učenie](#detekcia-bezpečnostných-prvkov-a-učenie)
- [Kde sú vaše súbory](#kde-sú-vaše-súbory)

## Podpisovanie

1. Otvorte PDF cez `⌘O`, pretiahnutím do okna, dvojklikom alebo cez **Otvoriť v** vo Finderi, alebo ho podpíšte rýchlou akciou vo Finderi. Podpísaný súbor sa uloží vedľa pôvodného pod jeho menom s príponou `_podpisane`. Do vlastného priečinka aplikácie sa uloží len vtedy, keď pôvodný priečinok nie je zapisovateľný alebo keď dokument prišiel bez súboru (napríklad obrázok pretiahnutý z inej aplikácie).
2. Pri viacerých dokumentoch kliknite vo fronte podpisovania na **Podpísať všetky** (pozri [Dávkové podpisovanie](#dávkové-podpisovanie)).
3. Vyberte formát, certifikát a voliteľne vizuálny podpis a kvalifikovanú časovú pečiatku.
4. Podpíšte cez **Podpísať KEP** (karta v čítačke) alebo **Podpísať mobilom** (občiansky preukaz s NFC cez iPhone).
5. Skontrolujte výsledok. Obrazovka po podpise ukáže podpisy dokumentu a ich overenie.

### Podpísané dokumenty a ich overenie

Podpísané PDF aj kontajner `.asice` otvoríte z Findera dvojklikom, cez **Otvoriť v** alebo pretiahnutím na ikonu v Docku. Chevron7 sa v ponuke **Otvoriť v** ponúka aj vtedy, keď kontajnery `.asice` má na Macu na starosti iná aplikácia. Dokument sa otvorí na obrazovke podpisovania so stromom podpisov: pri každom podpise je podpisujúci, druh podpisu (KEP, kvalifikovaná pečať, nekvalifikovaný) a výsledok overenia, a to aj pri podpisoch vnorených v dokumentoch vnútri kontajnera. Najprv sa ukáže rýchle čítanie, overenie voči európskym zoznamom dôveryhodných služieb dobehne na pozadí. **Overiť znova** overenie zopakuje, **Overiť aj na slovensko.sk** otvorí štátnu overovaciu službu v prehliadači. Overenie v aplikácii je informatívne.

K už podpísanému dokumentu pridáte ďalší podpis tlačidlom **Pridať ďalší podpis**. Podpísané PDF ani kontajner sa pritom nemenia: PDF sa nekonvertuje do PDF/A ani sa doň nevpaľuje pečiatka a kontajner sa rozšíri o nový podpis, aby pôvodné podpisy ostali platné. Kontajner rozšíri iba podpis kartou, nie mobilom.

<details>
<summary><strong>Stavy podpisu a dôveryhodnosti</strong></summary>

| Stav | Význam |
|---|---|
| Platný | Podpis je neporušený a certifikát vedie k dôveryhodnej službe v zozname EÚ. |
| Neplatný | Dokument sa po podpise zmenil alebo certifikát nesedí. V dávke sa zablokuje len tento dokument, ostatné pokračujú. |
| Neurčitý | Zoznam dôveryhodných služieb sa nedal načítať alebo kvalifikácia sa nedá určiť. Nie je to platný ani neplatný podpis a dávku neblokuje. |
| DEMO | Ukážkový podpis bez skutočnej karty. Nie je právne záväzný. |

</details>

### Karta a ovládač

Chevron7 podpisuje občianskym preukazom (eID), advokátskym preukazom SAK, kartami I.CA a Disig a ďalšími kartami s ovládačom PKCS#11. Ovládač karty od jej vydavateľa (k občianskemu preukazu eID klient) treba nainštalovať samostatne. Keď je karta v čítačke, ale jej ovládač na Macu chýba, ukazovateľ karty dole v bočnom paneli napíše **Chýba ovládač karty** a odkáže na stránku, kde si ho stiahnete.

Pri občianskom preukaze sa BOK zadáva v okne eID klienta; pri ostatných kartách sa PIN zadáva v Chevron7. Ak pole PIN necháte prázdne, aplikácia si ho pri **Podpísať KEP** vypýta.

### Časová pečiatka

Kvalifikovanú časovú pečiatku zapnete prepínačom pri podpise, v dávke aj v Nastaveniach (Podpisovanie). Ponuka obsahuje iba kvalifikované služby (BOSA, Sectigo Qualified a CA Disig, ktorá vyžaduje zmluvu s Disigom) a vlastné adresy; pri vlastnej adrese aplikácia upozorní, že jej kvalifikáciu nevie overiť. Bez pečiatky sa podpisuje úrovňou B, rovnako ako v aplikácii Autogram. Pri podpise mobilom pridáva pečiatku služba v telefóne a obrazovka po podpise ukáže autoritu, ktorú overenie v pečiatke našlo.

### Dávkové podpisovanie

**Podpísať všetky** vo fronte podpisovania skontroluje všetky dokumenty naraz: načíta certifikát (PIN sa zadá raz pre celú dávku), overí existujúce podpisy jednou validáciou a naplánuje názvy výstupov. Karta **Nastavenie dávky** je formulár, v ktorom sa všetko dá zmeniť až do spustenia; zmena sa hneď prejaví v plánovaných výstupoch, bez opätovného čítania karty.

| Voľba | Čo robí |
|---|---|
| Formát podpisu | **PAdES** (podpis priamo v každom PDF, výstup `<názov>_podpisane.pdf`) alebo **ASiC-E (XAdES)**. |
| Balenie ASiC-E | **Samostatný kontajner pre každý dokument** (predvolené) alebo **Jeden spoločný kontajner**, v ktorom je každé PDF samostatným dokumentom jedného podpisu. Aplikácia si poslednú voľbu pamätá. |
| Názov kontajnera | Pri spoločnom kontajneri predvyplnený ako `<prvý dokument>_podpisane`. Nepovolené znaky sa nahradia a existujúci súbor sa nikdy neprepíše (pridá sa „(2)“). |
| Časová pečiatka | Zapína sa priamo v dávke, s výberom služby. Neplatná adresa služby nechá dávku pripravenú, ale nedovolí ju spustiť. |
| PDF/A | Konverzia do PDF/A pred podpisom. Už podpísané PDF sa nekonvertujú ani nepečiatkujú. |
| Vizuálna pečiatka | Preberá sa z náhľadu dokumentu (umiestnenie a vzhľad). |

Riadok **Výstup** vždy povie, čo vznikne, napríklad „3 kontajnery, každý dokument vo vlastnom …_podpisane.asice“. Po spustení sa voľby zamknú; rovnaké údaje zapíše aj **Exportovať protokol…**. Kontajnery ASiC-E sa do dávky nepridávajú, podpisujú sa samostatne.

### Podpis mobilom

Bez čítačky podpíšete dokument občianskym preukazom s NFC a iPhonom. Tlačidlo **Podpísať mobilom** ponúka dve cesty.

**Autogram v mobile.** Mac dokument zašifruje kľúčom, ktorý pozná len on, nahrá ho na server autogram.slovensko.digital, zobrazí QR kód a čaká. Po naskenovaní kódu aplikáciou [Autogram v mobile](https://sluzby.slovensko.digital/autogram-v-mobile/) telefón dokument podpíše a Mac si podpísaný súbor stiahne, overí a uloží rovnako ako pri karte. Server dokument dešifruje len v pamäti pri podpise a zmaže ho do 24 hodín. Netreba registráciu.

**eIDENTITA (štátna aplikácia).** Ide cez portál Autogram: dokument sa nahrá do vášho balíka na portáli, QR kód naskenujete aplikáciou eIDENTITA a podpísaný dokument sa stiahne späť. Dokument ostáva v histórii portálu. Treba to raz nastaviť v **Nastavenia ▸ Mobil a eIdentita ▸ Nastaviť eIdentitu…**: prihlásite sa na portál (predvolený je testovací portál, na ktorom Slovensko.Digital dnes sprístupňuje API), požiadate o zapnutie API prístupu pre vašu organizáciu, vložíte verejný kľúč z Chevron7 na portál a prepíšete ID organizácie do Chevron7. Súkromný kľúč ostáva iba v Keychaine.

<p align="center">
  <img src="diagrams/mobile-signing.svg" alt="Sekvencia podpisu mobilom cez Autogram v mobile" width="100%">
</p>

| Čo platí | Detail |
|---|---|
| Formát a pečiatka | Rovnaké voľby ako pri karte: podpis v PDF alebo kontajner ASiC-E. Zapnutú časovú pečiatku pridá služba mobilu, nie autorita z Nastavení. |
| Vizuálny podpis | Vpáli sa do PDF lokálne ešte pred odoslaním. |
| Zaručená konverzia | Vyžaduje mandátny certifikát, ktorý mobil nemá. Podpis z mobilu bez neho aplikácia odmietne, nič neuloží a evidenciu nezmení. ZaKo mobilom je dostupná len v skúšobnom režime EZZK. |
| Hranice | Mobil číta len občiansky preukaz, nie kartu SAK. Rýchla akcia vo Finderi podpisuje len kartou. |

### Rýchla akcia vo Finderi

Označte PDF vo Finderi a v kontextovej ponuke zvoľte **Rýchle akcie ▸ Podpísať s QES + QTS (Chevron7)**. Výber karty, certifikátu a PIN alebo BOK sa zobrazí bez otvorenia hlavného okna a podpísané PDF sa uloží vedľa pôvodného. Ak rýchlu akciu vo Finderi nevidíte, **Nastavenia ▸ Prehliadač a Finder** ukážu, či ju Finder zobrazuje, a cez **Ako aktivovať vo Findere…** vás prevedú zapnutím.

## Podpisovanie na štátnych weboch

Rozšírenie Chevron7 pre Safari podpisuje priamo na slovensko.sk (schránka aj nove.slovensko.sk), financnasprava.sk, sluzby.orsr.sk, eformulare.socpoist.sk, obcan.justice.sk, konto.bratislava.sk a eform.esluzbykosice.sk. Portál zavolá svoj obvyklý podpisovač a Chevron7 ho obslúži namiesto neho. Prehliadač a aplikácia sa spoja priamo v Macu, bez otvoreného portu a bez internetu.

| Čo platí | Detail |
|---|---|
| Spustenie | Chevron7 netreba mať otvorený. Pri požiadavke sa spustí na pozadí, bez ikony v Docku a bez hlavného okna, a ukáže iba okno podpisu nad oknom Safari. Po podpise, zrušení alebo chybe sa vrátite rovno do Safari. |
| Potvrdenie | Stránka nepodpíše nič ticho. Každá požiadavka otvorí okno s adresou stránky, ktorá o podpis žiada: vľavo všetky strany PDF a **Otvoriť náhľad**, vpravo karta a mobil. Naraz sa spracúva jedna požiadavka. |
| Karty | Karta I.CA: po vložení sa zameria pole PIN a Enter načíta certifikáty. Občiansky preukaz: certifikáty sa vopred nečítajú a BOK sa zadáva v okne eID klienta, okno podpisu ostane pod ním. |
| Mobil | **Použiť mobil** podpíše občianskym preukazom cez Autogram v mobile, aj elektronický formulár. Keď máte nastavenú eIDENTITU, ponúkne aj ju; eIDENTITA podpisuje PDF, nie formuláre. |
| Formuláre a prílohy | Chevron7 podpíše aj formulár, ktorý portál pripraví ako hotový kontajner. Keď portál pridá k jednému podpisu viac dokumentov (formulár a PDF prílohy), podpíšu sa jedným podpisom v jednom kontajneri ASiC-E a okno pri každom ukáže **Náhľad**. Viac dokumentov naraz sa podpíše, len keď je medzi nimi PDF, a len kartou. |
| Formát | Určuje ho portál, nie nastavenia. PDF, ktoré nove.slovensko.sk pýta v obálke ASiC-E, sa podpíše ako kontajner s pôvodným PDF vnútri, kartou aj mobilom. |
| Časová pečiatka | Portály pýtajú podpis bez pečiatky a aplikácia im pošle presne to. Na slovensko.sk sa prepínač pečiatky neponúka vôbec, lebo nove.slovensko.sk podpis s nevyžiadanou pečiatkou odmietne. Na ostatných weboch pri každej požiadavke začína vypnutý. |
| Ukladanie | Podpis z prehliadača sa vracia stránke. Kópiu si aplikácia predvolene odkladá do vlastného priečinka; v **Nastavenia ▸ Prehliadač a Finder** sa dá priečinok zmeniť, ukladanie vypnúť alebo kópie presúvať do Koša po 7, 30 alebo 90 dňoch. |
| Návrat k pôvodnému | Prepínač v rozšírení vráti konkrétnu stránku jej pôvodnému podpisovaču (napríklad D.Bridge 2) bez vypínania celého rozšírenia. |

### Keď podpisovanie zo Safari nejde

1. Skontrolujte, že rozšírenie **Chevron7** je zapnuté v **Safari ▸ Nastavenia ▸ Rozšírenia**.
2. Otvorte **Nastavenia ▸ Prehliadač a Finder** v Chevron7. Ukážu stav prepojenia so Safari a ponúknu, čo treba: **Zaregistrovať**, otvorenie **Položiek pri prihlásení** v nastaveniach macOS, alebo na Macoch so starou inštaláciou **Odstrániť staré prepojenie** (potom reštartujte Mac a o pár minút kliknite na **Zaregistrovať**).
3. Ukončite Safari (⌘Q) a otvorte ho znova. Safari si drží starú verziu rozšírenia až do ukončenia.

## Zaručená konverzia

**Rozsah:** Chevron7 robí zaručenú konverziu len z listinnej do elektronickej podoby (sken papierovej listiny na PDF/A s osvedčovacou doložkou). Konverziu elektronického dokumentu, napríklad do listinnej podoby, nepodporuje. Pri elektronickom origináli by podľa [§ 3 ods. 4 vyhlášky č. 70/2021 Z. z.](https://www.slov-lex.sk/ezbierky/pravne-predpisy/SK/ZZ/2021/70/) bolo treba jeho kvalifikované podpisy a pečate overiť kvalifikovanou službou validácie a jej výstup uchovať v zázname o konverzii. Overenie podpisov v aplikácii je informatívne, nie kvalifikovaná služba validácie.

| 1 · Vstup | 2 · Overenie | 3 · Doložka | 4 · Autorizácia | 5 · Hotovo |
|---|---|---|---|---|
| PDF alebo obrazový sken, potvrdenie pôvodu | analýza, návrhy AI, fyzická kontrola, kontrola každej strany | osoba, počítadlá, poloha prvkov, náhľad | evidenčné číslo, PDF/A, podpis mandátnym certifikátom | kontajner pre klienta a záznam v Registri |

<p align="center">
  <img src="diagrams/process-zako.svg" alt="Proces zaručenej konverzie" width="100%">
</p>

### Bezpečnostné prvky

- Katalóg má 16 druhov. Rýchly výber obsahuje pečiatku, podpis, slepotlač, parafu, šnúrku a pásku či štítok; ďalšie možnosti sú v ponuke.
- Prvok možno označiť rámcom v skene alebo zaznamenať cez **Skontrolované na origináli**. Fyzická kontrola vyžaduje opis umiestnenia a pred autorizáciou aj konkrétnu stranu zachytenia v novom PDF.
- Dokument bez bezpečnostných prvkov vyžaduje výslovné potvrdenie po kontrole neprázdnych strán. Zmena nálezu zruší príslušné potvrdenia.
- Potvrdený nález opraví automatické vyhodnotenie jeho strany ako prázdnej. Úradné osvedčenie podpisu a ďalšie právne posúdenia potvrdzuje človek.

Sekcia bezpečnostných prvkov v zázname o konverzii používa overenú štruktúru record 1.0 s textovým opisom, umiestnením a číslami strán. Podrobnosti: [pravidlá tréningového datasetu](../Chevron7/docs/security-element-training.md) a [oficiálne formulárové podklady](../Chevron7/docs/reference/security-elements/FINDINGS.md).

### Doložka a autorizácia

- **Druh dokumentu navrhne text.** Zmluva, plná moc, rozsudok, osvedčenie alebo rozhodnutie sa odvodí z textu prvej strany; návrh sa ukáže ako tlačidlo **Použiť** a do doložky sa nikdy nezapíše sám. Každé pole má nápovedu.
- **Údaje advokáta** sa vyplnia z profilu (**Nastavenia ▸ Profil advokáta**) a po podpise sa do profilu uložia.
- **Autorizácia sa drží, nie kliká.** **Autorizovať konverziu** vyžaduje približne sekundové podržanie, lebo autorizácia spotrebuje evidenčné číslo. Klávesnica a VoiceOver potvrdzujú priamo.
- **Len s mandátnym certifikátom.** Bez karty aplikácia vyzve na jej vloženie; karta bez mandátneho certifikátu sa odmietne. PIN si aplikácia pamätá len počas behu a zabudne ho, keď kartu vyberiete.

### EZZK

Chevron7 komunikuje s EZZK s prihlasovacím menom a heslom, ktoré advokát dostal pri registrácii. V **Nastavenia ▸ EZZK** ich zadáte a kliknete na **Pripojiť k EZZK**: aplikácia sa po potvrdení prepne na ostrú evidenciu a prihlási sa; ak prihlásenie zlyhá, vráti predchádzajúci režim. Heslo sa uloží do Keychainu až vtedy, keď ho EZZK prijme, a prihlasovací token existuje len v pamäti aplikácie. V Rozšírených nastaveniach sa dá zvoliť režim: **Skúšobný režim (lokálne)** (bez EZZK, čísla tvaru `DEMO-rrmmdd-n`), **Testovacia evidencia** alebo **Ostrá evidencia**.

- **Evidenčné číslo** pridelí EZZK samo pri autorizácii, tesne pred podpisom. Číslo z iného dňa alebo z iného režimu aplikácia odmietne ešte pred podpisom, lebo EZZK nepoužité čísla o polnoci spotrebuje. Pridelené a nepoužité čísla sa v ten deň použijú znova.
- **Ochrana pred stratou čísla:** mimo skúšobného režimu aplikácia nepridelí číslo ani neautorizuje s ukážkovým podpisom bez karty.
- **Výstup pre klienta** je jeden kontajner `<názov výstupu>.asice`, v ktorom sú PDF/A a doložka `<číslo>.xml.xdcf` podpísané spolu s kvalifikovanou časovou pečiatkou, rovnako ako v kontajneroch z podpisuj.sk. Uloží sa vedľa zdroja a nikdy neprepíše existujúci súbor.
- **Záznam o konverzii** (record 1.0) sa podpíše rovnakým PIN hneď po doložke, mimo skúšobného režimu vždy s kvalifikovanou časovou pečiatkou, a sám sa odošle do EZZK. Ostáva v Registri konverzií; **Uložiť záznam…** ho uloží ako `<číslo>.record.asice`.
- **Stav v EZZK:** aplikácia čakajúce záznamy odosiela a ich stav overuje každých päť minút (Prijatý na spracovanie, Spracovaný, Odmietnutý), alebo hneď cez **Overiť v EZZK**. Odosiela len v režime, v ktorom záznam vznikol, ale stav overí vždy. Pri prerušenom spojení záznam znova neposiela naslepo: najprv overí, či ho EZZK už má. Záznam odoslaný po polnoci dňa pridelenia sa označí ako oneskorený. Záznam, ktorý EZZK pri odoslaní odmietlo, sa dá po potvrdení odoslať znova. Ak sa záznam nepodarí podpísať, výstupy pre klienta ostanú a riadok má stav Záznam nepodpísaný.
- **Register** má filter stavu, vyhľadávanie, detail a CSV export. Riadok, ktorého záznam sa práve podpisuje alebo odosiela, sa nedá vymazať. Posledných päť konverzií je aj v bočnom paneli.

Technické podrobnosti: [EZZK-INTEGRATION.md](../Chevron7/docs/EZZK-INTEGRATION.md).

## Detekcia bezpečnostných prvkov a učenie

Vstavaná detekcia beží na Macu a skladá sa z troch vrstiev. Listina ani jej časť neodchádza na server; externé modely sa použijú, len ak ich výslovne zapnete v **Nastavenia ▸ AI a učenie**.

<p align="center">
  <img src="diagrams/ai-vision.svg" alt="AI Vision: strana, kandidáti, klasifikácia, kontrola a učenie" width="100%">
</p>

| Vrstva | Ako funguje |
|---|---|
| 1 · Kandidáti | Strana sa vykreslí raz a prejde rýchlym aj presným rozpoznaním textu. Tri nezávislé zdroje navrhnú oblasti, ktoré sa zlúčia podľa prekrytia. Filtre odstránia návrhy na tlačenom texte, linkovaných bunkách a čiarových kódoch. |
| 2 · Klasifikácia | Každý výrez sa porovná s vašimi potvrdenými a odmietnutými príkladmi. Ak je výsledok neistý, rozhodne model Apple na Macu (najviac 12 výrezov na stranu). |
| 3 · Kontrola | Advokát nález potvrdí alebo odmietne (aj všetky naraz cez **Odmietnuť návrhy**), upraví rámec ťahaním, alebo zvolí druh a klikne na prvok, aby sa rámec prichytil k obrysu. Každý druh má vlastnú farbu. Bez kontroly každej neprázdnej strany aplikácia nepokračuje. |

### Ako sa detekcia učí z vašej kontroly

<p align="center">
  <img src="diagrams/ai-learning.svg" alt="Učenie detekcie: potvrdiť uloží pozitívny príklad, odmietnuť negatívny príklad, zmazať vlastný rámec nič neuloží" width="100%">
</p>

Každý nález, ktorý potvrdíte alebo odmietnete, sa uloží ako **príklad**: výrez zo skenu, jeho číselný odtlačok vzhľadu a vaše rozhodnutie. Pri ďalšom dokumente sa každý návrh porovná s piatimi najpodobnejšími príkladmi. Ak sa aspoň tri jasne zhodujú, aplikácia rozhodne sama: podobný potvrdenému rovno pomenuje, podobný odmietnutému zahodí ešte predtým, než ho uvidíte. Takmer rovnaký výrez rozhodne jediný príklad, takže jedno odmietnutie platí aj pri ďalšom spustení. Pri zapnutom učení sa dokument, ktorého strany ste už skontrolovali, pri ďalšom otvorení vráti s vašimi nálezmi namiesto novej detekcie (**Znova analyzovať AI** detekuje odznova).

**Prečo nechať odmietnuté návrhy odmietnuté.** Odmietnutý návrh učí, čo bezpečnostný prvok **nie je** (tlačený text, logo, tabuľka, šum skenu). Preto je odmietnutý nález bledý, zamknutý a nereaguje na klik, v zozname je v zbalenej skupine **Odmietnuté (N)** s jedinou akciou **Vrátiť na kontrolu**, a kláves Delete návrh detektora odmietne, nie zmaže.

| Situácia | Správny postup |
|---|---|
| Na mieste nie je žiadny bezpečnostný prvok | **Odmietnuť**. Vznikne negatívny príklad. |
| Prvok tam je, ale rámec sedí nepresne alebo má zlý druh | Rámec **posuňte alebo zmeňte druh a potvrďte**. Odmietnutím by sa skutočná pečiatka naučila ako „nie prvok“. |
| Sami ste nakreslili rámec omylom | **Zmazať**. Nič sa neuloží. |

Príklady sú uložené len na Macu (pozri [Kde sú vaše súbory](#kde-sú-vaše-súbory)). V **Nastavenia ▸ AI a učenie** sa dá učenie vypnúť, dataset vymazať alebo exportovať pre Create ML (exportujú sa len úplne skontrolované strany).

### Vlastný detektor

<p align="center">
  <img src="diagrams/ai-training-loop.svg" alt="Cyklus trénovania: kontrola ukladá strany, tréning beží na Macu, overenie porovná nový a starý detektor, aktiváciu potvrdí človek" width="100%">
</p>

Príklady vedia premenovať návrhy, ale nové rámce nenavrhnú. Keď skontrolujete dosť strán (40 strán z 8 dokumentov, 15 príkladov na druh), aplikácia ponúkne natrénovanie vlastného detektora, ktorý sa učí, kde prvky na vašich dokumentoch bývajú. Jeho návrhy prechádzajú rovnakou klasifikáciou aj vašou kontrolou.

1. Ponuka sa objaví po konverzii, alebo ju otvoríte v **Nastavenia ▸ AI a učenie ▸ Otvoriť trénovanie…**.
2. Pozrite správu: koľko strán a dokumentov máte a ktorým druhom chýbajú príklady.
3. Spustite trénovanie (prvý raz približne 8 až 15 minút). Beží na pozadí a zrušením sa nič nestratí.
4. Nový detektor sa ponúkne, len keď na dokumentoch, ktoré nevidel, nájde aspoň o 5 % prvkov viac a nechybuje pritom častejšie. Aktivujete ho tlačidlom **Používať nový detektor**; predchádzajúci ostáva na jedno vrátenie.

**Exportovať detektor…** uloží zip so samotným modelom, bez skenov. Na inom Macu ho okno trénovania prijme cez **Importovať detektor zo súboru…**, ale aktivuje sa, len keď prejde rovnakým overením na tamojších stranách.

## Kde sú vaše súbory

| Čo | Kde a ako |
|---|---|
| Podpísané a konvertované súbory | Vedľa zdrojového dokumentu, inak `~/Library/Application Support/Chevron7/Output`. Existujúce súbory sa neprepíšu (`dokument (2).pdf`). |
| Register konverzií | `~/Library/Application Support/Chevron7/Evidence/register.json`, bez obsahu dokumentov. Vedľa neho `records/` s podpísanými záznamami a `allocated-numbers.json` s pridelenými nepoužitými číslami. Register, ktorý sa nedá načítať, sa nikdy neprepíše; odloží sa jeho kópia. |
| Príklady a detektor | `~/Library/Application Support/Chevron7/VisionBank`: náhľady strán, výrezy a odtlačky posúdených prvkov, v `models/` vaše detektory. Len lokálne, vymazateľné v Nastaveniach. |
| Heslá a kľúče | Keychain: heslo do EZZK (zvlášť pre testovaciu a ostrú evidenciu), kľúč eIdentity a API kľúče externých modelov. Token EZZK len v pamäti. |
| Podpis mobilom | Cez Autogram v mobile dočasne na autogram.slovensko.digital, zašifrovaný kľúčom z tohto Macu, zmazaný po podpise alebo do 24 hodín. Cez eIDENTITU v histórii vášho balíka na portáli Autogram. |

Zaručená konverzia vytvára PDF/A-2b. Kontrola PDF/A v aplikácii nenahrádza veraPDF ani Acrobat Preflight.
