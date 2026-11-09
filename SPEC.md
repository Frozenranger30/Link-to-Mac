# Link to Mac – Kompletter Bauplan (Spezifikation)

> **Arbeitstitel:** Link to Mac
> **Ziel:** Eine eigene macOS-App plus eine Android-Begleit-App, mit denen ein Samsung-/Android-Handy so mit dem Mac zusammenarbeitet wie bei „Smartphone-Link“ unter Windows: Benachrichtigungen, SMS, Anrufe, Fotos, Dateien, Zwischenablage und Bildschirm-Spiegelung.
> **Wichtig:** Eigenes Design, eigener Name, eigene Icons. Keine Logos, Texte oder Grafiken von Microsoft oder Samsung verwenden.

---

## 0. Anleitung für die KI, die diesen Plan umsetzt

Du bist ein erfahrener Entwickler für macOS (Swift/SwiftUI) und Android (Kotlin/Jetpack Compose). Setze dieses Projekt **Meilenstein für Meilenstein** um (siehe Abschnitt 11). Regeln:

1. Gib für jeden Meilenstein **vollständige, lauffähige Dateien** aus, mit Dateipfad als Überschrift. Keine Platzhalter wie „// rest of code here“.
2. Halte dich an die Ordnerstruktur aus Abschnitt 10.
3. Das Protokoll (Abschnitt 5) ist für beide Seiten verbindlich. Ändere es nur, wenn du die Änderung in `docs/PROTOCOL.md` dokumentierst.
4. Der Entwickler hat **keinen Mac**. Alles muss über **GitHub Actions** gebaut werden (macOS-Runner für die Mac-App, Ubuntu-Runner für die Android-APK). Liefere die Workflow-Dateien mit (Abschnitt 12).
5. Code-Kommentare auf Englisch, Erklärungen für den Entwickler auf Deutsch.
6. Nach jedem Meilenstein: kurze Liste, was getestet werden soll.

---

## 1. Überblick

Das System besteht aus zwei Apps, die sich über das **lokale WLAN** direkt verbinden (kein eigener Cloud-Server nötig):

```
┌──────────────────────┐        WLAN (TLS, Port 47800)        ┌──────────────────────┐
│   Mac-App (Swift)    │  ◄────────────────────────────────►  │ Android-App (Kotlin) │
│  Menüleiste + Fenster│   JSON-Nachrichten + Binär-Streams    │  Hintergrund-Dienst  │
└──────────────────────┘                                       └──────────────────────┘
         ▲  Bonjour/mDNS: "_linktomac._tcp"  ▲
         └──────────── Geräte finden sich automatisch ─────────┘
```

- **Android-App** = „Server“: läuft als Foreground-Service, liest Benachrichtigungen, SMS, Anrufstatus, Fotos usw. und schickt sie an den Mac.
- **Mac-App** = „Client“ und Oberfläche: zeigt alles an, schickt Befehle (SMS senden, Anruf annehmen, Datei schicken, Zwischenablage) zurück.

---

## 2. Funktionen (Feature-Liste)

| # | Funktion | Priorität | Beschreibung |
|---|----------|-----------|--------------|
| F1 | Kopplung (Pairing) | MUSS | QR-Code auf dem Mac, mit dem Handy scannen. Danach automatische Wiederverbindung. |
| F2 | Verbindungsstatus | MUSS | Akkustand, Ladezustand, WLAN-Stärke, Handyname in der Mac-Menüleiste. |
| F3 | Benachrichtigungen | MUSS | Alle Handy-Benachrichtigungen erscheinen als macOS-Mitteilungen. Wegwischen am Mac entfernt sie auch am Handy. Antworten direkt aus der Mitteilung (z. B. WhatsApp), wenn die App „Direktantwort“ anbietet. |
| F4 | SMS | MUSS | Unterhaltungen anzeigen, neue SMS empfangen, SMS vom Mac senden. |
| F5 | Fotos | MUSS | Die letzten 500 Fotos/Screenshots als Galerie am Mac, Vollbild öffnen, per Drag & Drop auf den Mac ziehen. |
| F6 | Dateiübertragung | MUSS | Dateien in beide Richtungen schicken (Drag & Drop auf das Menüleisten-Symbol bzw. „Teilen“-Menü auf Android). |
| F7 | Zwischenablage | SOLL | Kopierter Text (und Bilder) wird zwischen Mac und Handy synchronisiert. |
| F8 | Anrufe | SOLL | Eingehende Anrufe am Mac anzeigen, annehmen/ablehnen, Anrufliste, Nummer wählen. Audio siehe Abschnitt 7.4. |
| F9 | Bildschirm-Spiegelung | SOLL | Handy-Bildschirm live in einem Mac-Fenster, mit Maus/Tastatur steuern. |
| F10 | Handy finden | KANN | Handy klingeln lassen, auch im Lautlos-Modus. |
| F11 | Medien-Steuerung | KANN | Laufende Musik am Handy vom Mac aus pausieren/weiter. |
| F12 | Kontakte | KANN | Kontaktnamen und Bilder für SMS und Anrufe. |

---

## 3. Technologie-Stack

### Mac-App
- **Sprache:** Swift 5.10+
- **UI:** SwiftUI, Mindestversion **macOS 13 Ventura**
- **Netzwerk:** `Network.framework` (`NWConnection`, `NWBrowser` für Bonjour), TLS über `NWProtocolTLS`
- **Mitteilungen:** `UserNotifications` (mit Antwort-Aktionen)
- **Video (Spiegelung):** `VideoToolbox` (H.264-Decoder) + `AVSampleBufferDisplayLayer`
- **Speicher:** `Keychain` für Schlüssel, `SwiftData` oder JSON-Dateien für Cache
- **Projektformat:** Swift Package + `project.yml` für **XcodeGen** (damit kein Xcode-Projekt von Hand angelegt werden muss; GitHub Actions erzeugt es)

### Android-App
- **Sprache:** Kotlin 2.x, **UI:** Jetpack Compose (Material 3)
- **Mindestversion:** Android 10 (API 29), Ziel: aktuelles API-Level
- **Netzwerk:** Ktor oder reines `javax.net.ssl.SSLSocket`, Bonjour über `NsdManager`
- **Hintergrund:** Foreground-Service (`connectedDevice`-Typ)
- **Benachrichtigungen:** `NotificationListenerService`
- **SMS:** `Telephony`-ContentProvider + `SmsManager`
- **Anrufe:** `TelephonyCallback`, `TelecomManager`, `InCallService` (optional)
- **Fotos:** `MediaStore`
- **Spiegelung:** `MediaProjection` + `MediaCodec` (H.264), Steuerung über `AccessibilityService` (Gesten)
- **QR-Scanner:** CameraX + ML Kit Barcode
- **Build:** Gradle (Kotlin DSL)

---

## 4. Kopplung und Sicherheit

1. Mac erzeugt beim ersten Start ein **Ed25519-Schlüsselpaar** und ein selbstsigniertes TLS-Zertifikat (in der Keychain gespeichert).
2. Mac zeigt einen **QR-Code** mit:
   ```json
   { "v":1, "name":"Jonns MacBook", "host":"192.168.1.20", "port":47800,
     "certFingerprint":"SHA256:…", "pairToken":"<32 Zufallsbytes, base64>" }
   ```
3. Handy scannt, baut eine TLS-Verbindung auf und prüft, dass der Zertifikat-Fingerabdruck stimmt (**Certificate Pinning**).
4. Handy sendet `pair.request` mit `pairToken` + eigenem Zertifikat-Fingerabdruck. Mac zeigt „Kopplung mit Galaxy S24 erlauben?“ → Nutzer bestätigt.
5. Beide speichern den Fingerabdruck des anderen. Ab jetzt werden **nur noch gepinnte Geräte** akzeptiert (gegenseitiges TLS).
6. `pairToken` ist 5 Minuten gültig und nur einmal verwendbar.

**Weitere Regeln:**
- Alles läuft nur im lokalen Netz, keine Daten verlassen das Heimnetz.
- Gerät kann in beiden Apps „entkoppelt“ werden (löscht Schlüssel).
- Keine Passwörter oder Tokens im Klartext auf der Festplatte.

---

## 5. Protokoll

### 5.1 Transport
- TCP + TLS 1.3, Port **47800** (Steuerkanal).
- Jede Nachricht: **4 Byte Länge (Big Endian)** + **UTF-8-JSON**.
- Große Daten (Dateien, Fotos, Video) über **separate TLS-Verbindungen** auf Port 47801 (Dateien) und 47802 (Video), damit der Steuerkanal nicht blockiert.
- Heartbeat: `ping`/`pong` alle 10 s. Nach 30 s ohne Antwort → Verbindung neu aufbauen.

### 5.2 Nachrichtenformat
```json
{ "id": "uuid", "type": "notification.posted", "ts": 1731137870000, "body": { ... } }
```
Antworten nutzen `"replyTo": "<id>"`.

### 5.3 Nachrichtentypen

| Typ | Richtung | Inhalt (body) |
|-----|----------|---------------|
| `hello` | beide | `deviceName`, `appVersion`, `protocolVersion`, `capabilities[]` |
| `pair.request` / `pair.accept` / `pair.reject` | Handy→Mac / Mac→Handy | Token, Fingerabdruck |
| `ping` / `pong` | beide | – |
| `status.update` | Handy→Mac | `battery`, `charging`, `wifiSignal`, `network`, `dnd` |
| `notification.posted` | Handy→Mac | `key`, `app`, `appName`, `appIconPng`(base64, gecacht), `title`, `text`, `time`, `actions[]`, `canReply` |
| `notification.removed` | beide | `key` |
| `notification.action` | Mac→Handy | `key`, `actionIndex`, `replyText?` |
| `sms.threads.get` / `sms.threads` | Mac→Handy / zurück | Liste: `threadId`, `address`, `contactName`, `snippet`, `date`, `unread` |
| `sms.messages.get` / `sms.messages` | Mac→Handy / zurück | `threadId`, `before`, `limit` / Nachrichtenliste |
| `sms.received` | Handy→Mac | einzelne neue SMS |
| `sms.send` / `sms.sent` | Mac→Handy / zurück | `address`, `text` / Erfolg |
| `call.state` | Handy→Mac | `state` (ringing, offhook, idle), `number`, `contactName` |
| `call.action` | Mac→Handy | `answer`, `reject`, `hangup`, `dial`+`number` |
| `calllog.get` / `calllog` | Mac→Handy / zurück | Anrufliste |
| `photos.list` / `photos` | Mac→Handy / zurück | `id`, `date`, `width`, `height`, `thumbJpeg`(base64, 256px) |
| `photo.get` | Mac→Handy | `id` → Übertragung über Dateikanal |
| `file.offer` / `file.accept` / `file.reject` | beide | `transferId`, `name`, `size`, `mime`, `sha256` |
| `file.progress` / `file.done` | beide | Fortschritt |
| `clipboard.set` | beide | `mime`, `text` oder `dataBase64` |
| `mirror.start` / `mirror.stop` | Mac→Handy | `maxSize`, `bitrate`, `fps` |
| `mirror.config` | Handy→Mac | `width`, `height`, SPS/PPS (base64) |
| `input.touch` / `input.key` / `input.scroll` | Mac→Handy | Koordinaten (0–1 normiert), Tasten |
| `find.ring` | Mac→Handy | – |
| `media.state` / `media.action` | beide | Titel, Interpret, play/pause/next |
| `error` | beide | `code`, `message` |

### 5.4 Dateikanal (Port 47801)
1. Empfänger bestätigt `file.accept`.
2. Sender öffnet Verbindung, schickt Header `{transferId}` (wie oben, Länge + JSON), danach Rohdaten in 64-KB-Blöcken.
3. Empfänger prüft SHA-256 und sendet `file.done` über den Steuerkanal.

### 5.5 Videokanal (Port 47802)
- Pro Frame: 8 Byte Zeitstempel (µs) + 4 Byte Länge + H.264-NAL-Units (Annex-B).
- Standard: max. 1280 px lange Seite, 30 fps, 6 Mbit/s.

---

## 6. Mac-App im Detail

### 6.1 Aufbau der Oberfläche
- **Menüleisten-Symbol** (eigenes Icon: stilisiertes Handy + Laptop): zeigt Akkustand, schnelle Aktionen (Datei senden, Handy finden, Spiegelung starten).
- **Hauptfenster** mit Seitenleiste (`NavigationSplitView`):
  1. **Übersicht** – Handybild (generisch gezeichnet), Akku, letzte Benachrichtigungen
  2. **Nachrichten** – SMS-Unterhaltungen links, Chat rechts, Eingabefeld unten
  3. **Fotos** – Raster-Galerie, Doppelklick = Vollbild, Drag & Drop in den Finder
  4. **Anrufe** – Anrufliste, Wähltastatur
  5. **Benachrichtigungen** – Liste mit „Alle löschen“
  6. **Handy-Bildschirm** – Spiegelungsfenster
  7. **Einstellungen** – Gerät koppeln/entkoppeln, welche Apps Mitteilungen senden dürfen, Autostart

### 6.2 Wichtige Klassen
```
App/LinkToMacApp.swift           @main, MenuBarExtra + WindowGroup
Core/ConnectionManager.swift     NWBrowser, NWConnection, Reconnect, Heartbeat
Core/MessageCodec.swift          Länge+JSON kodieren/dekodieren
Core/Protocol.swift              Codable-Structs für alle Nachrichtentypen
Core/PairingService.swift        Schlüssel, Zertifikat, QR-Code (CoreImage CIQRCodeGenerator)
Core/TrustStore.swift            Keychain-Zugriff
Features/Notifications/…         NotificationBridge (UNUserNotificationCenter)
Features/Messages/…              MessagesStore, ThreadListView, ChatView
Features/Photos/…                PhotosStore, PhotoGridView
Features/Calls/…                 CallsStore, IncomingCallPanel (schwebendes NSPanel)
Features/Files/…                 FileTransferService (Upload/Download, Fortschritt)
Features/Clipboard/…             ClipboardSync (NSPasteboard changeCount alle 0,5 s prüfen)
Features/Mirror/…                H264Decoder (VideoToolbox), MirrorView (NSViewRepresentable), InputForwarder
```

### 6.3 Berechtigungen / Einstellungen
- `Info.plist`: `NSLocalNetworkUsageDescription`, `NSBonjourServices = ["_linktomac._tcp"]`
- App Sandbox mit `com.apple.security.network.client` und `.server`, Dateizugriff „User Selected“ + Downloads-Ordner
- Autostart über `SMAppService.mainApp`

---

## 7. Android-App im Detail

### 7.1 Bildschirme
1. **Willkommen** – Erklärung, „Mit Mac koppeln“ → QR-Scanner
2. **Berechtigungen** – Checkliste mit Schaltern, jede Berechtigung einzeln erklären
3. **Verbunden** – Status, Mac-Name, Schalter pro Funktion, „Trennen“

### 7.2 Komponenten
```
LinkService.kt              Foreground-Service, hält Verbindung, Bonjour-Anmeldung (NsdManager)
net/Connection.kt           TLS-Socket, Länge+JSON, Heartbeat
net/Protocol.kt             kotlinx.serialization Datenklassen
pairing/PairingManager.kt   Schlüssel im Android Keystore, Zertifikats-Pinning
features/NotifListener.kt   NotificationListenerService, RemoteInput für Antworten
features/SmsBridge.kt       ContentObserver auf content://sms, SmsManager zum Senden
features/CallBridge.kt      TelephonyCallback, TelecomManager.acceptRingingCall/endCall
features/PhotosBridge.kt    MediaStore-Abfrage, Thumbnails per loadThumbnail()
features/FileBridge.kt      Share-Intent-Empfänger, Speichern in Downloads/LinkToMac
features/ClipboardBridge.kt siehe 7.3
features/MirrorService.kt   MediaProjection → VirtualDisplay → MediaCodec H.264
features/InputService.kt    AccessibilityService.dispatchGesture() für Klicks/Wischen
```

### 7.3 Berechtigungen (AndroidManifest)
`INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION`, `POST_NOTIFICATIONS`, `READ_SMS`, `RECEIVE_SMS`, `SEND_SMS`, `READ_CONTACTS`, `READ_PHONE_STATE`, `READ_CALL_LOG`, `CALL_PHONE`, `ANSWER_PHONE_CALLS`, `READ_MEDIA_IMAGES` (bzw. `READ_EXTERNAL_STORAGE` bis API 32), `CAMERA` (QR), `RECEIVE_BOOT_COMPLETED`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
Plus Sonderzugriffe über Einstellungen: Benachrichtigungszugriff, Bedienungshilfe (für Steuerung bei Spiegelung).

### 7.4 Bekannte Einschränkungen (ehrlich dokumentieren)
- **SMS-Berechtigungen:** Im Play Store nur für Standard-SMS-Apps erlaubt. Für die private Nutzung per **APK-Installation (Sideload)** kein Problem.
- **Zwischenablage:** Android 10+ erlaubt Hintergrund-Apps kein Lesen der Zwischenablage. Lösung: Mac→Handy funktioniert automatisch; Handy→Mac über „Teilen → Link to Mac“, eine Schnelleinstellungs-Kachel oder eine schwebende Schaltfläche.
- **Anruf-Audio:** Gesprächsaudio über WLAN ist für normale Apps nicht möglich. Lösung: Mac als **Bluetooth-Headset** nutzen ist unter macOS ebenfalls nicht vorgesehen. Daher Version 1: Anrufe am Mac **anzeigen, annehmen, ablehnen, wählen**; gesprochen wird am Handy oder über Lautsprecher. (In Abschnitt 13 als spätere Forschungsaufgabe.)
- **Samsung-Akkuoptimierung:** Samsung beendet Hintergrund-Apps aggressiv. Die App muss den Nutzer anleiten: Einstellungen → Akku → „Nicht optimiert“ / „Nie im Standby“.
- **Bildschirm-Spiegelung:** Android fragt bei jedem Start der Aufnahme nach Erlaubnis (Systemdialog).

### 7.5 Alternative Spiegelung über USB (Bonus)
Wie das Open-Source-Projekt **scrcpy**: Mac-App startet über ADB (USB-Debugging) einen kleinen Server auf dem Handy. Vorteil: sehr flüssig, Steuerung ohne Bedienungshilfe. Nachteil: Kabel bzw. Wireless-ADB und Entwickleroptionen nötig. Optional als „Profi-Modus“ einbauen, `adb` wird mit der Mac-App ausgeliefert (Lizenz beachten: Apache 2.0).

---

## 8. Datenschutz
- Keine Analyse-/Tracking-Bibliotheken.
- Fotos und Nachrichten werden am Mac nur im App-Cache gespeichert und können in den Einstellungen gelöscht werden.
- Nutzer wählt pro Funktion, was synchronisiert wird.

---

## 9. Design-Richtlinien
- Eigener Name und eigenes Icon (Vorschlag: abgerundetes Quadrat, Farbverlauf Blau→Türkis, darin Handy-Umriss, der mit einem Laptop-Umriss überlappt).
- Mac-App folgt den macOS-Gestaltungsrichtlinien: Seitenleiste, SF Symbols, Hell- und Dunkelmodus.
- Android-App: Material 3, dynamische Farben.
- Sprache der Oberfläche: Deutsch, mit Englisch als zweite Sprache (`Localizable.xcstrings` bzw. `strings.xml`).

---

## 10. Ordnerstruktur des Repositorys

```
link-to-mac/
├── README.md
├── SPEC.md                    (dieses Dokument)
├── docs/
│   ├── PROTOCOL.md
│   └── SETUP.md               (Installation für Endnutzer)
├── mac/
│   ├── project.yml            (XcodeGen)
│   ├── LinkToMac/
│   │   ├── App/  Core/  Features/  Resources/
│   │   ├── Info.plist
│   │   └── LinkToMac.entitlements
│   └── LinkToMacTests/
├── android/
│   ├── settings.gradle.kts
│   ├── build.gradle.kts
│   └── app/
│       ├── build.gradle.kts
│       └── src/main/{AndroidManifest.xml, java/…, res/…}
├── shared/
│   └── protocol-examples/     (Beispiel-JSON für jeden Nachrichtentyp, für Tests beider Seiten)
└── .github/workflows/
    ├── mac.yml
    └── android.yml
```

---

## 11. Meilensteine

| # | Meilenstein | Ergebnis / Test |
|---|-------------|-----------------|
| M0 | Grundgerüst + GitHub Actions | Beide Apps bauen in der Cloud, Mac-App als `.zip`, Android als `.apk` herunterladbar. Leere Fenster. |
| M1 | Verbindung + Kopplung | QR scannen, TLS-Verbindung steht, Mac zeigt „Verbunden mit Galaxy …“ und Akkustand. Automatische Wiederverbindung. |
| M2 | Benachrichtigungen | Handy-Mitteilungen erscheinen am Mac, Wegwischen synchron, Direktantwort funktioniert. |
| M3 | SMS | Unterhaltungen lesen, senden, neue SMS live. |
| M4 | Fotos + Dateien | Galerie, Download, Drag & Drop, Dateien in beide Richtungen mit Fortschrittsbalken. |
| M5 | Zwischenablage | Text Mac→Handy automatisch, Handy→Mac per Teilen/Kachel. |
| M6 | Anrufe | Eingehender Anruf als Fenster am Mac, annehmen/ablehnen, Anrufliste, wählen. |
| M7 | Bildschirm-Spiegelung | Live-Bild + Maus-Steuerung über WLAN. |
| M8 | Feinschliff | Handy finden, Medien-Steuerung, Einstellungen, Icons, Deutsch/Englisch, Fehlertexte. |
| M9 | Bonus | USB-/ADB-Profi-Spiegelung, Kontakte, Bilder in SMS (MMS). |

---

## 12. Bauen ohne eigenen Mac (GitHub Actions)

### `.github/workflows/mac.yml` (Vorgabe)
```yaml
name: Build Mac App
on: [push, workflow_dispatch]
jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Generate project
        working-directory: mac
        run: xcodegen generate
      - name: Build
        working-directory: mac
        run: |
          xcodebuild -project LinkToMac.xcodeproj -scheme LinkToMac \
            -configuration Release -derivedDataPath build \
            CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
      - name: Zip app
        run: cd mac/build/Build/Products/Release && zip -r LinkToMac.zip LinkToMac.app
      - uses: actions/upload-artifact@v4
        with:
          name: LinkToMac-macOS
          path: mac/build/Build/Products/Release/LinkToMac.zip
```

### `.github/workflows/android.yml` (Vorgabe)
```yaml
name: Build Android App
on: [push, workflow_dispatch]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '17' }
      - uses: gradle/actions/setup-gradle@v4
      - name: Build APK
        working-directory: android
        run: gradle assembleDebug
      - uses: actions/upload-artifact@v4
        with:
          name: LinkToMac-android
          path: android/app/build/outputs/apk/debug/*.apk
```

**Hinweis zur Installation auf dem Mac:** Die App ist nicht von Apple signiert. Beim ersten Öffnen: Rechtsklick → „Öffnen“, oder Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen“. Für eine richtige Signierung braucht man später ein Apple-Developer-Konto (99 $/Jahr).

---

## 13. Spätere Ideen / Forschung
- Anruf-Audio über den Mac (z. B. Bluetooth-HFP-Experimente oder VoIP-Weiterleitung)
- Mehrere Handys gleichzeitig
- Verbindung außerhalb des Heimnetzes (über ein selbst gehostetes Relay oder Tailscale)
- Apps vom Handy einzeln in eigenen Mac-Fenstern öffnen (virtuelles Display pro App)
- Hotspot mit einem Klick aktivieren

---

## 14. Fertig-Kriterien (Definition of Done)
- Beide Apps bauen ohne Fehler in GitHub Actions.
- Kopplung funktioniert in unter 30 Sekunden.
- Nach Neustart von Mac oder Handy verbinden sich beide automatisch wieder (unter 10 s im selben WLAN).
- Keine Abstürze bei Verbindungsabbruch (WLAN aus/an testen).
- Alle Berechtigungen werden in der App verständlich auf Deutsch erklärt.
