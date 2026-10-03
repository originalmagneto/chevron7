# Chevron7: test české karty na Macu

Návod pro kolegu z ČR (česky). Patří k úkolu 1 plánu `Chevron7/docs/superpowers/plans/2026-10-02-czech-signing.md`: zjišťujeme, jak se české karty a tokeny chovají na macOS, než pro ně Chevron7 upravíme.

Zabere to asi 10 minut. Skript kartu jen čte: nepřihlašuje se k ní, nežádá ani neposílá PIN ani QPIN a nic na Macu ani na kartě nemění.

## Co budete potřebovat

- Mac s procesorem Apple (M1 a novější). Na Macu s Intelem skript také poběží, Chevron7 tam ale nefunguje.
- Svou kartu nebo token s kvalifikovaným certifikátem a čtečku.
- Ovladač karty nainstalovaný tak, jak ho běžně používáte (například I.CA SecureStore, eObčanka, SafeNet Authentication Client, ProID+, Bit4id).
- Volitelně OpenSC, se kterým bude report úplnější. Pokud máte Homebrew, spusťte v Terminálu `brew install opensc`. Instalátor OpenSC z jeho webu (DMG) prosím neinstalujte, přidává do systému vlastní ovladač karet.

## Krok 1: diagnostika (bezpečná pro každou kartu)

1. Zasuňte kartu do čtečky (token do USB).
2. Otevřete Terminál a vložte:

```bash
curl -fsSLo ~/Downloads/czech-card-probe.sh https://raw.githubusercontent.com/originalmagneto/chevron7/main/Chevron7/scripts/czech-card-probe.sh
```

```bash
bash ~/Downloads/czech-card-probe.sh
```

3. Skript běží 1 až 3 minuty. Kdyby se přesto objevilo okno s žádostí o PIN, klikněte na Zrušit a nic nezadávejte.
4. Na Ploše vznikne soubor `chevron7-cz-karta-<datum>.txt`. Pošlete ho prosím zpět.

Co report obsahuje: verzi macOS, nainstalované ovladače karet a jejich architekturu, model karty, příznaky tokenu (například jestli si ovladač PIN vyžádá ve vlastním okně a kolik pokusů zbývá) a veřejné certifikáty z karty (jméno, vydavatel, typ klíče). Stejné údaje nese každý dokument, který podepíšete. PIN ani soukromý klíč v něm nejsou a být nemohou.

## Krok 2: zkušební podpis (jen karta I.CA)

Na konci skript vypíše pro každou kartu verdikt. Podepisujte jen tehdy, když u ní stojí „zkušební podpis v Chevron7 je povolen". Dnes to platí jen pro karty I.CA (ovladač SecureStore).

Proč ostatní zatím ne: eObčanka a kvalifikované tokeny PostSignum, eIdentity nebo ProID+ mají vedle PINu ještě samostatný podpisový kód (QPIN). Dnešní Chevron7 by jako QPIN poslal stejný kód, jaký zadáte jako PIN. Každý takový pokus by se počítal jako chybný QPIN a po třech chybných pokusech se QPIN zablokuje. To nejprve opravíme a potom vás poprosíme o další test.

Postup pro kartu I.CA:

1. Stáhněte Chevron7: https://github.com/originalmagneto/chevron7/releases/latest/download/Chevron7.dmg a přetáhněte aplikaci do složky Aplikace.
2. Připravte si zkušební PDF bez důležitého obsahu.
3. V Chevron7 zvolte Podpisovanie, otevřete PDF a vyberte formát PAdES. Kvalifikované časové razítko (QTS) nechte vypnuté.
4. Zadejte PIN karty jednou a podepište („Podpísať KEP").
5. Pokud se objeví jakákoli chyba, znovu to nezkoušejte. Udělejte snímek obrazovky (Cmd+Shift+4) a pošlete ho.
6. Pošlete prosím:
   - podepsaný soubor, nebo snímek chyby,
   - snímky všech oken, která se během podpisu objevila (okno SecureStore pro PIN, hlášení Chevron7),
   - kolikrát a kde jste PIN zadávali.

Děkujeme! Každý report nám ušetří hádání: podle něj Chevron7 nastavíme pro skutečné české karty.
