# notey. — natywna aplikacja iPadOS (Swift)

Pełne przepisanie aplikacji webowej na natywny Swift/SwiftUI dla iPada:

- **PencilKit** — natywny silnik pisania: Apple Pencil z naciskiem i nachyleniem, niska latencja,
  natywne **lasso** (zaznaczanie i przesuwanie pisma), gumka wektorowa, pióro i zakreślacz.
- **SwiftData** — trwały zapis wszystkiego lokalnie (foldery, notatki, rysunki, zdjęcia, adnotacje).
- **Kalendarz = odręczna notatka**: miesiąc (kafelki z podglądem pisma → tap powiększa dzień do
  pełnoekranowego modala), tydzień (7 żywych canvasów — pisze się bezpośrednio w kolumnach),
  dzień (pełny edytor) i rok (przegląd; dni z pismem podświetlone).
- **Zdjęcia na canvasie** — z biblioteki (PhotosPicker) lub ze schowka; przesuwanie, skalowanie
  uchwytem; pismo naniesione na zdjęcie przesuwa się razem z nim.
- **Adnotacje** — kolorowe prostokąty pod pismem; przeciągnięcie zabiera naniesione pociągnięcia.
- **Foldery jak w Chrome** — drzewo podfolderów w pasku bocznym (kolory, zmiana nazwy, usuwanie,
  menu kontekstowe), kafelki jak w Google Drive, karty otwartych notatek z kolorowymi grupami
  folderów, pełny drag & drop (notatka→folder, folder→folder, zmiana kolejności kart).
- **Kolorystyka**: beż (#F6F1E7) + granat (#1F2A44) z pojedynczymi, delikatnymi różowymi
  akcentami (#D98BA3): aktywne narzędzie, dzisiejsza data, kropka w „notey." i w ikonie.
- **Zaawansowany eksport PDF** — pojedyncza notatka (wszystkie kartki), cały folder z
  podfolderami (menu kontekstowe folderu / przycisk „Eksportuj PDF" w siatce) albo wszystkie
  notatki naraz; każda kartka to strona PDF, udostępnianie przez systemowy share sheet.
- **Wielostronicowe notatki kalendarzowe** — przycisk „+ Kartka" w edytorze dnia dokłada
  kolejną kartkę pod spodem (przewijanie dwoma palcami).
- **Aparat** — „Zrób zdjęcie" w menu obrazka wstawia fotografię prosto na canvas.
- **Pasek boczny** — przycisk kalendarza jak góra flip-kalendarza (oczka, tłoczenie 3D,
  dzisiejsza data), głębokość folderów oznaczona glifami: ★ poziom 1, ○ poziom 2, ● poziom 3+,
  przyciski „rozwiń/zwiń wszystkie".
- **Adnotacje** — przeciąganie działa też narzędziem adnotacji (chwyt za istniejący prostokąt
  przesuwa go zamiast rysować nowy); przenosi się z nią wyłącznie pismo NOWSZE od adnotacji
  (starszy tekst pod spodem zostaje na miejscu — porównanie po `PKStrokePath.creationDate`).

## Struktura

```
ios/
  project.yml                 — definicja projektu (XcodeGen)
  Notey.xcodeproj             — wygenerowany projekt Xcode
  Notey/
    NoteyApp.swift            — @main, kontener SwiftData, NoteStore
    Models.swift              — @Model Folder/Note + elementy canvasa (Codable)
    Theme.swift               — paleta beż/granat/róż
    DateUtils.swift           — siatki miesiąca/tygodnia, polskie nazwy
    ContentView.swift         — NavigationSplitView, routing, karty
    Canvas/
      DrawingCanvasView.swift — PKCanvasView + warstwa obiektów (zdjęcia, adnotacje,
                                przenoszenie z pismem), gesty, undo, eksport PDF
      CanvasEditorView.swift  — edytor z paskami narzędzi, autosave
      NoteThumbnail.swift     — renderowanie miniatur (kafelki, karty)
    Calendar/CalendarScreen.swift — widoki dzień/tydzień/miesiąc/rok + modal dnia
    Browser/                  — SidebarView, TabsBarView, FolderGridView
    Assets.xcassets           — AppIcon (1024, bez kanału alfa), kolory
    Info.plist
  scripts/gen_icon.swift      — generator ikony (CoreGraphics)
```

## Budowanie

**Wymagania:** Xcode 16+ (zalecane 26.x) z iOS SDK. Instalacja: App Store → „Xcode"
(strona otwarta automatycznie) albo https://developer.apple.com/download/.

1. Otwórz `ios/Notey.xcodeproj` w Xcode.
2. W ustawieniach targetu **Notey → Signing & Capabilities** wybierz swój **Team**
   (bundle id: `com.adrian.notey` — zmień na własny, jeśli trzeba).
3. Wybierz cel **iPad** (symulator lub urządzenie) i ⌘R.

Weryfikacja z terminala (po instalacji Xcode):

```bash
cd ios
xcodebuild -project Notey.xcodeproj -scheme Notey \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Po zmianach w `project.yml` lub dodaniu plików: `xcodegen generate`.

## Publikacja w App Store — checklista

1. **Team + bundle id** ustawione (Signing & Capabilities, automatic signing).
2. Product → **Archive** (cel: Any iOS Device).
3. Organizer → **Distribute App** → App Store Connect → Upload.
4. W App Store Connect: nowa aplikacja, uzupełnij metadane, zrzuty ekranu iPada
   (12,9" i 11"), politykę prywatności (aplikacja nie zbiera danych — wszystko lokalnie
   w SwiftData), kategorię (Produktywność).
5. Ikona (1024, bez alfa) i `ITSAppUsesNonExemptEncryption=false` są już w projekcie.
6. Aplikacja jest iPad-only (`TARGETED_DEVICE_FAMILY = 2`) i wspiera wszystkie orientacje
   oraz multitasking.

## Uwagi projektowe

- Strona notatki to logiczna kartka 1000×1400 pkt dopasowywana do szerokości widoku;
  przewijanie dwoma palcami, rysowanie jednym palcem/Pencilem (przełącznik „tylko Pencil"
  w prawym górnym rogu edytora).
- W widoku miesiąca kafelki pokazują podgląd (wydajność: 42 żywe canvasy PencilKit to za
  dużo) — pisanie bezpośrednie jest w widoku tygodnia, dnia i w modalu dnia.
- Undo/redo łączy historię pisma (PencilKit) i operacji na obiektach (registerUndo).
# notey
