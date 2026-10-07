<p align="center">
  <img src="docs/diagrams/hero.svg" alt="Chevron7: podpisovanie a zaručená konverzia" width="100%">
</p>

<h1 align="center">Chevron7</h1>

<p align="center">
  <a href="https://github.com/originalmagneto/chevron7/releases/latest"><img src="https://img.shields.io/github/v/release/originalmagneto/chevron7?display_name=tag&style=flat-square&color=ffb23e" alt="Aktuálne vydanie"></a>
  <img src="https://img.shields.io/badge/macOS-27%2B-2d3142?style=flat-square" alt="macOS 27 alebo novší">
  <a href="https://chevron7.slovensko.app"><img src="https://img.shields.io/badge/web-chevron7.slovensko.app-0a0b1a?style=flat-square" alt="Web chevron7.slovensko.app"></a>
  <a href="https://buymeacoffee.com/chevron7"><img src="https://img.shields.io/badge/podpori%C5%A5-Buy%20Me%20a%20Coffee-ffdd00?style=flat-square&logo=buymeacoffee&logoColor=000" alt="Podporiť vývoj"></a>
</p>

<p align="center">
  <strong>Kvalifikovaný elektronický podpis a zaručená konverzia, natívne na Macu.</strong><br>
  Zadarmo, open source a dokumenty ostávajú na vašom Macu.<br>
  <a href="https://chevron7.slovensko.app"><strong>chevron7.slovensko.app</strong></a> · <a href="https://chevron7.slovensko.app/en/">English</a>
</p>

## Čo Chevron7 robí

- **Podpisuje kartou aj mobilom.** Občiansky preukaz, advokátsky preukaz SAK, karty I.CA a Disig v čítačke, alebo bez čítačky iPhonom cez Autogram v mobile či štátnu aplikáciu eIDENTITA. Podpis v PDF alebo v kontajneri .asice, s kvalifikovanou časovou pečiatkou, viditeľnou pečiatkou a dávkovým podpisovaním.
- **Podpisuje na štátnych portáloch v Safari.** Na slovensko.sk, nove.slovensko.sk, finančnej správe, ORSR a ďalších sa podpis otvorí v okne Chevron7 s celým dokumentom a nič sa nepodpíše bez vášho potvrdenia.
- **Ukáže a overí podpisy.** PDF alebo .asice otvorené z Findera ukáže všetky podpisy aj s ich overením voči európskym zoznamom dôveryhodných služieb.
- **Pre advokátov: zaručená konverzia** podľa zákona č. 305/2013 Z. z. z listiny do elektronickej podoby. Umelá inteligencia na Macu navrhne bezpečnostné prvky, vy ich skontrolujete, podpíšete mandátnym certifikátom a evidenčné číslo aj záznam o konverzii vybaví Chevron7 s EZZK sám.
- **Register konverzií** so stavom každého záznamu v EZZK, vyhľadávaním a exportom.

Podrobný popis všetkých funkcií je v [príručke](docs/PRIRUCKA.md).

## Stiahnutie

**[Stiahnuť Chevron7.dmg](https://github.com/originalmagneto/chevron7/releases/latest/download/Chevron7.dmg)** (odkaz vždy vedie na najnovšiu verziu). Nainštalovaná aplikácia sa ďalej aktualizuje sama, ponuka **Chevron7 ▸ Skontrolovať aktualizácie…** to urobí hneď. Všetky vydania a ich poznámky sú v [GitHub Releases](https://github.com/originalmagneto/chevron7/releases).

### Požiadavky

- Mac s čipom Apple (M1 alebo novší) a macOS 27 alebo novší.
- Na podpis kartou čítačka a ovládač k vašej karte od jej vydavateľa (k občianskemu preukazu eID klient). Ak ovládač chýba, Chevron7 to povie a odkáže, kde ho stiahnuť.
- Alebo namiesto čítačky iPhone s aplikáciou Autogram v mobile a občiansky preukaz s čipom.
- Na zaručenú konverziu karta s mandátnym certifikátom a vlastný účet v EZZK (meno a heslo z registrácie). Bez účtu si postup vyskúšate v skúšobnom režime.
- Voliteľne Apple Intelligence: spresní návrhy bezpečnostných prvkov priamo na Macu.

### Inštalácia

1. Otvorte stiahnutý DMG a presuňte **Chevron7** do priečinka **Aplikácie**.
2. Spustite Chevron7. macOS sa raz opýta, či chcete otvoriť aplikáciu stiahnutú z internetu; zvoľte **Otvoriť**.
3. Pri prvom spustení si Chevron7 zaregistruje prepojenie so Safari a macOS to oznámi ako pridanú položku na pozadí. Nechajte ju povolenú, inak podpisovanie zo Safari nepôjde.

Stiahnutý súbor si môžete overiť: GitHub pri súbore vo vydaní uvádza jeho odtlačok SHA-256, porovnajte ho s výstupom `shasum -a 256 Chevron7.dmg`.

## Podpisovanie v Safari

1. V Safari otvorte **Nastavenia ▸ Rozšírenia** a zapnite **Chevron7**. Povoľte ho na stránkach, kde podpisujete.
2. Na portáli kliknite na podpis ako obvykle. Chevron7 sa spustí sám (netreba ho mať otvorený) a ukáže okno s dokumentom a adresou stránky.
3. Potvrďte podpis kartou alebo mobilom. Podpísaný dokument sa vráti stránke a vy sa vrátite do Safari.

Ak podpis zo stránky nejde, otvorte v Chevron7 **Nastavenia ▸ Prehliadač a Finder**: ukážu stav prepojenia so Safari a ponúknu, čo treba urobiť. Potom ukončite Safari (⌘Q) a otvorte ho znova. Podrobnosti v [príručke](docs/PRIRUCKA.md#podpisovanie-na-štátnych-weboch).

## Prvé nastavenie

Nastavenia (⌘,) majú bočný panel ako Systémové nastavenia: Profil advokáta, EZZK, Podpisovanie, Mobil a eIdentita, Prehliadač a Finder, AI a učenie a Všeobecné. Bežne stačia základné voľby, prepínač **Rozšírené nastavenia** dole v paneli ukáže ostatné.

- **Podpisovanie:** zvoľte službu kvalifikovanej časovej pečiatky.
- **Mobil a eIdentita:** Autogram v mobile funguje hneď. eIDENTITA potrebuje jednorazové nastavenie na portáli Autogram, ktorým vás prevedie **Nastaviť eIdentitu…**.
- **Profil advokáta** a **EZZK** pre zaručenú konverziu: vyplňte svoje údaje do doložky, zadajte prihlasovacie údaje do EZZK a kliknite na **Pripojiť k EZZK**. Chevron7 sa pripojí k ostrej evidencii jedným krokom.

## Súkromie

Chevron7 podpisuje priamo na vašom Macu. Von ide len to, čo si sami zvolíte:

| Kedy | Čo odchádza |
|---|---|
| Podpis mobilom | Dokument prejde zašifrovaný cez server Autogramu v mobile a do 24 hodín sa zmaže. Pri eIDENTITE ostáva v histórii vášho balíka na portáli Autogram. |
| Časová pečiatka | Len odtlačok dokumentu, nikdy dokument. |
| Overenie podpisov | Aplikácia si stiahne európske zoznamy dôveryhodných služieb. |
| Zaručená konverzia | Do EZZK sa odošle podpísaný záznam o konverzii. Bezpečnostné prvky hľadá umelá inteligencia na Macu; cloudovú AI aplikácia použije, len ak ju sami zapnete. |

Heslá a kľúče sú v Keychaine. Kde presne sú vaše súbory, popisuje [príručka](docs/PRIRUCKA.md#kde-sú-vaše-súbory).

## Chyby a návrhy

Chevron7 je open source projekt, nie služba: nemá zákaznícku podporu ani zaručenú dobu odpovede. Chybu alebo návrh nahláste v [GitHub Issues](https://github.com/originalmagneto/chevron7/issues). Pomôže verzia aplikácie (**Chevron7 ▸ O aplikácii Chevron7**), čo ste robili a čo sa stalo. Nikdy neprikladajte skutočné dokumenty klientov, PIN ani heslá.

Ak vám Chevron7 šetrí čas, môžete dobrovoľne [podporiť jeho vývoj](https://buymeacoffee.com/chevron7). Rovnaké žlté tlačidlo je dole v bočnom paneli aplikácie a v ponuke **Pomoc ▸ Podporiť vývoj…**.

<p align="center">
  <a href="https://www.buymeacoffee.com/chevron7"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="60" width="217"></a>
</p>

## Pre vývojárov

Zostavenie zo zdrojov, testy, vydania, nástroje príkazového riadka a architektúra sú v [Chevron7/docs/DEVELOPMENT.md](Chevron7/docs/DEVELOPMENT.md). Pravidlá projektu a podrobné poznámky k architektúre sú v [CLAUDE.md](CLAUDE.md), fakty, ktoré smie tvrdiť web, v [PRODUCT.md](PRODUCT.md) a vizuálny systém webu v [DESIGN.md](DESIGN.md).

## Pôvod a licencia

Podpisové jadro v priečinku `engine/` je fork projektu [slovensko-digital/autogram](https://github.com/slovensko-digital/autogram) pod licenciou EUPL 1.2. Podpisovanie mobilom používa aplikáciu Autogram v mobile a server autogram.slovensko.digital, ktoré prevádzkuje Slovensko.Digital, a eIDENTITA portál Autogram. Rozšírenie pre Safari preberá časti [slovensko-digital/autogram-extension](https://github.com/slovensko-digital/autogram-extension).

Chevron7 nie je spojený so Slovensko.Digital ani ním podporovaný a nemá nič spoločné so spoločnosťou Chevron Corporation. Licencia: EUPL 1.2, pozri [LICENSE](LICENSE) a [NOTICE](NOTICE).

## Právne upozornenie

Chevron7 je technický nástroj. Nenahrádza právne posúdenie konkrétneho dokumentu ani povinnosť advokáta skontrolovať originál, bezpečnostné prvky, certifikát a výsledný dokument. Návrhy umelej inteligencie sú len návrhy; bez potvrdenia advokátom sa do osvedčovacej doložky nedostanú. Overenie podpisov v aplikácii je informatívne, nie kvalifikovaná služba validácie.
