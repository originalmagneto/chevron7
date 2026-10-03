# Technická Vývojárska Špecifikácia & UI Blueprint: Autogram macOS (SwiftUI)

Tento dokument slúži ako presný vývojársky podklad pre kódovanie natívnej macOS aplikácie **Autogram** v **SwiftUI / AppKit** pre macOS (Liquid Glass štýl).

---

## 1. Architektúra Natívnej SwiftUI Aplikácie

Aplikácia je navrhnutá ako natívna macOS macOS aplikácia (`WindowGroup` a `NavigationSplitView`) využívajúca natívnu systémovú tému (`@Environment(\.colorScheme)`). Nespravuje sa ručným prepínačom tém, ale plne rešpektuje nastavenia macOS.

### Kľúčové SwiftUI Prvky:
* **Okno Aplikácie:** `WindowGroup` s `.windowStyle(.hiddenTitleBar)` a `NSVisualEffectView` (`.ultraThinMaterial`).
* **Navigácia:** `NavigationSplitView` s trojstĺpcovým alebo dvojstĺpcovým rozložením.
* **Ikonografia:** Výhradne systémové **SF Symbols 6+** (žiadne unicode emojis).

---

## 2. Modul 1: Autogram Native Document Signing Suite

Hlavný modul pre bežné podpisovanie KEP/PAdES/XAdES.

### Vizuálne Obrazovky & SwiftUI Komponenty:

1. **`FileIntakeView` (Drag-and-Drop Dropzone):**
   - Využíva `.onDrop(of: [.pdf, .xml], isTargeted: $isTargeted)` pre prijatie súborov.
   - Plynulá spring animácia `.animation(.interpolatingSpring(stiffness: 300, damping: 25))` pri pretiahnutí súboru nad okno.
   - Použité SF Symbols: `doc.viewfinder`, `arrow.down.doc.fill`.

2. **`DocumentReviewCanvasView` (Náhľad PDF & Vizuálna Pečiatka):**
   - Renders PDF prostredníctvom `PDFView` (PDFKit Wrapper).
   - **`VisualSignatureStampView`**: Vizuálny prekryvný podpisový rámček s metadátami (Meno, SAK č., UTC čas, CA vydavateľ).
   - Použité SF Symbols: `signature`, `checkmark.seal.fill`, `magnifyingglass`, `arrow.clockwise`.

3. **`SmartcardStatusDock` (eID Status Panel):**
   - Monitoruje pripojenie PKCS#11 čítačky a eID karty.
   - Použité SF Symbols: `creditcard.and.123`, `lock.shield.fill`, `person.badge.shield.checkmark`.

4. **`BatchQueueView` (Hromadné Podpisovanie):**
   - Zoznam dávky súborov s kruhovým indikátorom stavu.
   - Použité SF Symbols: `doc.on.doc.fill`, `checkmark.circle.fill`, `clock.fill`.

---

## 3. Modul 2: Zaručená Konverzia (ZaKo / Advocate Studio)

Vizuálne aj funkčne oddelený modul špeciálne pre advokátov, notárov a orgány verejnej moci podľa **§ 35 až 39 Zákona č. 305/2013 Z. z. o e-Governmente**.

### Vizuálne Obrazovky & Workflow Stepper:

1. **`ZaKoModeHeaderView` (4-krokový Stepper):**
   - Krok 1: Vstupný dokument (`doc.badge.plus`)
   - Krok 2: Overenie originálu (`shield.checkerboard`)
   - Krok 3: Osvedčovacia doložka (`doc.text.fill`)
   - Krok 4: KEP Advokáta (`signature.badge.checkmark`)

2. **`OsvedcovaciaDoloskaFormView` (Generátor Doložky):**
   - Automatické predvyplnenie údajov advokátskej kancelárie (SAK ID, IČO, Miesto).
   - Zadávanie Evidenčného čísla z registra konverzií (`CEZZK`).
   - Automatický výpočet kryptografického otlačku **SHA-256**.
   - Použité SF Symbols: `building.columns.fill`, `doc.on.clipboard.fill`, `number.square.fill`.

---

## 4. Modul 3: AI Vision & Inteligentné Detegovanie (API Key & Subscription)

Modul pre automatickú analýzu papierových a elektronických dokumentov pomocou AI Vision. Odstraňuje manuálnu prácu advokáta.

### Funkčnosť AI Vision:
* **Strany ➔ Listy:** Automatické spočítanie strán PDF a výpočet listov pre obojstrannú tlač.
* **Detekcia pečiatok a podpisov:** Generuje Bounding Boxes na dokumente pre úradné pečiatky, vlastnoručné podpisy a reliéfne otlačky (slepotlač).
* Použité SF Symbols: `brain.head.profile`, `cpu.fill`, `eye.trianglebadge.exclamationmark`.

### Integrácia AI (Modely financovania & Nastavenia):

V nastaveniach aplikácie (`AISettingsView`) si používateľ môže zvoliť 2 režimy integrácie:

#### Režim A: Vlastné API Key (Custom API Key)
* Používateľ zadá vlastný API kľúč (napr. OpenAI GPT-4o Vision / Google Gemini 1.5 Pro / Anthropic Claude 3.5 Sonnet Vision API Key).
* Kľúč sa bezpečne uloží do natívnej macOS Kľúčenky (`KeychainAccess` / `SecItemAdd`).

#### Režim B: Predplatné Autogram AI Pro (In-App Subscription / Enclave API)
* Pre advokátske kancelárie, ktoré nechcú spravovať vlastné API kľúče.
* Integrácia cez macOS In-App Purchase / StoreKit 2 (`StoreKit.Product`).
* Požiadavky smerujú cez šifrovaný bezpečný Proxy server Autogram Enclave s garantovaným GDPR compliant spracovaním pre právne dokumenty.

---

## 5. Prehľad Použitých SF Symbols Ikoniek (SF Symbols 6)

| SF Symbol Názov | Použitie v Autograme |
| :--- | :--- |
| `signature` | Hlavné tlačidlo podpisovania / vizuálna pečiatka |
| `checkmark.seal.fill` | Platný eIDAS kvalifikovaný podpis |
| `shield.checkerboard` | Overenie bezpečnosti a integrity |
| `building.columns.fill` | Režim ZaKo (Advokátska doložka) |
| `creditcard.and.123` | eID smartkarta a BOK/PIN kód |
| `brain.head.profile` | AI Vision Asistent detekcie |
| `doc.on.doc.fill` | Hromadné podpisovanie (Batch Queue) |
| `key.fill` | Správa certifikátov / API Kľúč |
| `lock.shield.fill` | Zabezpečený PKCS#11 kanál |
| `square.and.arrow.up` | Export podpísaného PDF / ASiC-E |

---

## 6. Architektúra SwiftUI Kódu (Pre Programátora)

```swift
import SwiftUI
import PDFKit

@main
struct AutogramApp: App {
    @StateObject private var appState = AppStateManager()
    
    var body: some Scene {
        WindowGroup {
            MainContainerView()
                .environmentObject(appState)
                .preferredColorScheme(nil) // Automatický macOS Light/Dark Mode
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AutogramCommands()
        }
    }
}
```
