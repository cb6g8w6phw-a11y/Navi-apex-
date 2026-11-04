# Vela – Ustawienia w stylu Liquid Glass

Nowy, nowoczesny ekran ustawień zaprojektowany w stylu **Liquid Glass** (Apple, iOS 26).

## Co dostajesz

- Prawdziwy efekt `glassEffect` (Liquid Glass) na iOS 26 – z interaktywnością i reakcją na dotyk
- Na starszych iOS (17/18/25): elegancki fallback – rozmyty materiał, świetlista obwódka i miękki cień
- Wyszukiwarka ustawień na górze (szkło)
- Sekcje: Moje miejsca, Nawigacja, Raporty i alerty, Kamery i prędkość, Ruch i paliwo, Prywatność, O aplikacji
- Ikony w gradientowych kafelkach, przełączniki w kolorze sekcji, menu dla trybu domyślnego i pojemności baku
- Pełne wsparcie trybu ciemnego

## Instalacja

1. Przeciągnij `GlassSettingsView.swift` do projektu w Xcode (grupa, w której trzymasz widoki).
2. W pliku, w którym pokazywany jest stary arkusz ustawień (tam, gdzie używany jest `model.showSettings`), podmień zawartość na:

```swift
.sheet(isPresented: $model.showSettings) {
    GlassSettingsView(model: model)
}
```

3. Zbuduj i uruchom. Nic więcej nie trzeba zmieniać – widok korzysta z `AppModel`, `AppSettings` i istniejącego flow wybierania Home/Work (`model.picking`).

## Uwagi techniczne

- Widok używa wyłącznie ustawień już istniejących w `AppSettings` (wazeOn, speedCameras, fuelKey, avoidHighways itd.) – żadnych nowych pól nie trzeba dodawać.
- `TravelMode` musi mieć przypadki `.drive`, `.walk`, `.ride` (tak jak w komentarzach w `Navigator.swift`). Jeśli nazwa „ride” różni się u Ciebie w kodzie, popraw trzy miejsca: listę w `modeMenu` oraz funkcje `modeName`/`modeIcon`.
- `AppSettings` musi być `ObservableObject` z właściwościami `@Published` (tak wynika z reszty kodu aplikacji).
- Wybór Home/Work z ustawień zamyka arkusz i otwiera istniejący flow `picking`, więc wszystko działa jak dotąd.
