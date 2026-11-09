# Link to Mac – Installation und Einrichtung

## 1. Dateien herunterladen

Beide Apps werden automatisch von GitHub Actions gebaut.

1. Öffne im Repository den Reiter **Actions**.
2. Wähle den neuesten grünen Lauf von **Build Mac App** bzw. **Build Android App**.
3. Unten unter **Artifacts**:
   - `LinkToMac-macOS` → enthält `LinkToMac.zip`
   - `LinkToMac-android` → enthält `app-debug.apk`

## 2. Mac-App installieren

1. `LinkToMac.zip` entpacken und **Link to Mac** in den Ordner *Programme* ziehen.
2. Die App ist nicht von Apple signiert. Beim ersten Start:
   **Rechtsklick → Öffnen → Öffnen**.
   Falls das nicht angeboten wird: *Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen“*.
3. Beim ersten Start fragt macOS:
   - **Mitteilungen erlauben** → *Erlauben* (sonst erscheinen keine Handy-Mitteilungen).
   - **Geräte im lokalen Netzwerk finden** → *Erlauben* (sonst findet der Mac das Handy nicht).
   - **Schlüsselbund-Zugriff** („LinkToMac möchte auf … zugreifen“) → *Immer erlauben*.
     Nach jedem Update der App kann diese Frage erneut kommen, weil die App nicht fest signiert ist.
4. Rechts oben in der Menüleiste erscheint das Symbol (Laptop + Handy).

## 3. Android-App installieren

1. `app-debug.apk` aufs Handy kopieren (oder auf dem Handy herunterladen) und öffnen.
2. Android fragt: *Installation aus unbekannten Quellen erlauben?* → für den Browser/Dateimanager erlauben.
3. Google Play Protect warnt eventuell („Unbekannte App“) → *Trotzdem installieren*.

## 4. Koppeln

1. Mac: **Einstellungen → Handy koppeln …** – ein QR-Code erscheint.
2. Handy: App öffnen → **Mit Mac koppeln** → QR-Code scannen.
3. Mac: Frage „Kopplung mit … erlauben?“ → **Erlauben**.
4. Handy: Liste **Berechtigungen** durchgehen (siehe unten).

Handy und Mac müssen im **selben WLAN** sein. Gäste-WLANs mit „Client-Isolation“ funktionieren nicht.

## 5. Berechtigungen auf dem Handy

| Berechtigung | Wofür |
|---|---|
| Mitteilungen anzeigen | Verbindungsstatus, empfangene Dateien, „Handy finden“ |
| Benachrichtigungszugriff | Handy-Mitteilungen am Mac, Antworten, Wegwischen, Medien-Steuerung |
| SMS | Nachrichten lesen und senden |
| Telefon und Anrufliste | Anrufe anzeigen, annehmen/ablehnen, wählen, Anrufliste |
| Kontakte | Namen statt Nummern |
| Fotos | Galerie am Mac |
| Bedienungshilfe „Link to Mac Steuerung“ | Nur für die Steuerung bei der Bildschirm-Spiegelung |
| Akku nicht optimieren | Damit Android die Verbindung nicht beendet |

### „Eingeschränkte Einstellung“ (Android 13 und neuer)

Bei Apps, die als APK installiert wurden, sperrt Android den **Benachrichtigungszugriff** und die
**Bedienungshilfe** zunächst (Meldung „Eingeschränkte Einstellung“). So hebst du das auf:

1. *Einstellungen → Apps → Link to Mac* öffnen.
2. Oben rechts auf **⋮** tippen → **Eingeschränkte Einstellungen zulassen**.
3. Danach den Benachrichtigungszugriff bzw. die Bedienungshilfe erneut aktivieren.

### Samsung

Samsung beendet Hintergrund-Apps besonders aggressiv:

- *Einstellungen → Apps → Link to Mac → Akku* → **Nicht eingeschränkt**.
- *Einstellungen → Akku → Hintergrundnutzungslimits → Apps, die nie in den Standby wechseln* → Link to Mac hinzufügen.

## 6. Benutzung

- **Zwischenablage:** Am Mac kopierter Text ist sofort am Handy verfügbar.
  Vom Handy zum Mac: Text **teilen → Link to Mac**, die **Schnelleinstellungs-Kachel**
  „Zwischenablage → Mac“ (Kachel über *Bearbeiten* in den Schnelleinstellungen hinzufügen) oder der Knopf in der App.
- **Dateien Handy → Mac:** in jeder App **Teilen → Link to Mac**. Dateien landen im Mac-Ordner *Downloads*.
- **Dateien Mac → Handy:** Dateien auf das Fenster, die Seitenleiste oder das Menüleisten-Feld ziehen.
  Sie landen auf dem Handy in *Download/LinkToMac*.
- **Fotos:** Doppelklick öffnet ein Foto, Ziehen in den Finder/in andere Apps kopiert es.
- **Bildschirm-Spiegelung:** Klick = Tippen, Ziehen = Wischen, langer Klick = langes Drücken,
  Rechtsklick = Zurück, Mausrad = Scrollen, Tastatur = Texteingabe ins aktive Feld.
  Android fragt bei jedem Start nach der Erlaubnis zur Bildschirmaufnahme.
- **2-Faktor-Codes:** Enthält eine Mitteilung einen Code, bietet die Mac-Mitteilung „Code … kopieren“ an.

## 7. Fehlerbehebung

| Problem | Lösung |
|---|---|
| Mac findet das Handy nicht | Gleiches WLAN? Handy-App geöffnet und „Warte auf den Mac…“ sichtbar? VPN aus? Am Mac „Lokales Netzwerk“ für Link to Mac erlauben (*Datenschutz & Sicherheit → Lokales Netzwerk*). |
| „Zertifikat des Handys hat sich geändert“ | Handy-App wurde neu installiert oder entkoppelt → am Mac *Entkoppeln* und neu koppeln. |
| Keine Mitteilungen am Mac | Benachrichtigungszugriff am Handy erteilt? macOS *Systemeinstellungen → Mitteilungen → Link to Mac* erlaubt? |
| Verbindung bricht nach einiger Zeit ab | Akku-Optimierung für Link to Mac ausschalten (siehe Samsung). |
| Spiegelung zeigt Bild, Klicks wirken nicht | Bedienungshilfe „Link to Mac Steuerung“ einschalten. |
