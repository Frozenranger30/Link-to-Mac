# Link to Mac

Eine eigene macOS-App plus Android-Begleit-App, mit der dein Android-Handy (z. B. Samsung Galaxy)
mit dem Mac zusammenarbeitet: **Benachrichtigungen, SMS, Anrufe, Fotos, Dateien, Zwischenablage,
Bildschirm-Spiegelung, Medien-Steuerung und „Handy finden“** – direkt über dein WLAN, ohne Cloud.

> Eigenes Projekt mit eigenem Namen, Design und Icons. Keine Verbindung zu Microsoft, Samsung oder Apple.

| | |
|---|---|
| **Installation & Einrichtung** | [docs/SETUP.md](docs/SETUP.md) |
| **Protokoll** | [docs/PROTOCOL.md](docs/PROTOCOL.md) |
| **Ursprüngliche Spezifikation** | [SPEC.md](SPEC.md) |

## Download

Die Apps werden von GitHub Actions gebaut: Reiter **Actions** → neuester grüner Lauf → **Artifacts**
(`LinkToMac-macOS` und `LinkToMac-android`). Details in [docs/SETUP.md](docs/SETUP.md).

## Funktionen

| # | Funktion | Mac | Android | Hinweis |
|---|---|---|---|---|
| F1 | Kopplung per QR-Code, automatische Wiederverbindung | ✅ | ✅ | Zertifikat-Pinning + Signatur-Challenge |
| F2 | Akku, Laden, WLAN, Mobilfunk, Nicht stören | ✅ | ✅ | Seitenleiste + Menüleiste |
| F3 | Benachrichtigungen, Wegwischen synchron, Direktantwort | ✅ | ✅ | + „Code kopieren“ bei 2FA-Codes |
| F4 | SMS lesen, senden, live empfangen | ✅ | ✅ | RCS ist für Dritt-Apps nicht zugänglich |
| F5 | Fotos (bis 2000), Vollbild, Drag & Drop | ✅ | ✅ | |
| F6 | Dateien in beide Richtungen mit Fortschritt | ✅ | ✅ | Teilen-Menü / Drag & Drop |
| F7 | Zwischenablage | ✅ | ✅ | Handy → Mac per Teilen/Kachel (Android-Einschränkung) |
| F8 | Anrufe anzeigen, annehmen, ablehnen, wählen, Anrufliste | ✅ | ✅ | Gesprochen wird am Handy |
| F9 | Bildschirm-Spiegelung mit Maus/Tastatur | ✅ | ✅ | H.264, Bedienungshilfe für Steuerung |
| F10 | Handy klingeln lassen (auch lautlos) | ✅ | ✅ | |
| F11 | Medien-Steuerung (Mini-Player) | ✅ | ✅ | |
| F12 | Kontaktnamen | ✅ | ✅ | |

## Ehrliche Einschränkungen

- **Anruf-Audio über den Mac** ist ohne Systemintegration nicht möglich: Android erlaubt normalen Apps
  keinen Zugriff auf das Gesprächsaudio, und macOS bietet kein Bluetooth-Freisprechprofil (HFP) für Apps.
  Anrufe werden am Mac angezeigt und gesteuert, gesprochen wird am Handy.
- **Zwischenablage Handy → Mac** braucht einen Tipp (Teilen, Kachel), weil Android 10+ Hintergrund-Apps
  das Lesen der Zwischenablage verbietet.
- **App-Streaming einzelner Apps, Webcam, Sofort-Hotspot und Datei-Explorer-Laufwerk** benötigen
  Hersteller-Systemrechte (Samsung/Microsoft) und sind für eine normale App nicht umsetzbar – siehe „Ideen“.
- **SMS-Berechtigungen** sind im Play Store nur für Standard-SMS-Apps erlaubt → Installation per APK.
- Die Mac-App ist **nicht von Apple signiert** (kein Entwicklerkonto) → beim ersten Start „Rechtsklick → Öffnen“.

## Aufbau

```
mac/        SwiftUI-App (macOS 13+), Projekt wird per XcodeGen aus project.yml erzeugt
android/    Kotlin/Jetpack-Compose-App (Android 10+)
shared/     Beispiel-JSON für jeden Nachrichtentyp (von den Tests beider Apps genutzt)
docs/       Protokoll und Einrichtungsanleitung
```

Das Handy ist TLS-Server (Ports 47800–47802, Bonjour `_linktomac._tcp`), der Mac verbindet sich als Client.
Warum das so ist, steht in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Selbst bauen

- **Mac:** `brew install xcodegen && cd mac && xcodegen generate && open LinkToMac.xcodeproj`
- **Android:** `cd android && ./gradlew assembleDebug`
- **Tests:** `./gradlew testDebugUnitTest` bzw. in Xcode ⌘U

## Ideen für später

- USB-/ADB-Profi-Spiegelung (wie scrcpy), MMS-Bilder in Nachrichten
- Mehrere Handys gleichzeitig, Verbindung außerhalb des Heimnetzes (Tailscale/Relay)
- Einzelne Handy-Apps in eigenen Mac-Fenstern (virtuelles Display pro App)
