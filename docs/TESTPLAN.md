# Testplan – was du nach jedem Meilenstein ausprobieren solltest

Automatisch geprüft wird bei jedem Push (GitHub Actions):

- **Build Mac App:** Build + Unit-Tests + Ende-zu-Ende-Test (echte Mac-App ↔ `tools/fake_phone.py`:
  Kopplung, TLS-Pinning, Signatur-Anmeldung, Status, Mitteilung, SMS-Liste, SMS senden, Foto-Download, Heartbeat).
- **Build Android App:** Build + Unit-Tests (Protokoll-Beispiele, Rahmenformat, HMAC-Testvektor, H.264-Zerlegung).
- **Android End-to-End Test:** echte Android-App im Emulator ↔ `tools/fake_mac.py`:
  Kopplung, TLS mit Android-Keystore-Zertifikat, Anmeldung, Status, Anfragen, Datei-Upload mit SHA-256-Prüfung.

Was nur mit echtem Handy und echtem Mac geht, steht unten. Hake ab, was funktioniert, und notiere Fehler
(am besten mit Uhrzeit, damit man es im Log findet).

## M0 – Grundgerüst
- [ ] Mac-App aus `LinkToMac-macOS` startet (Rechtsklick → Öffnen), Dock-Symbol und Menüleisten-Symbol erscheinen.
- [ ] APK aus `LinkToMac-android` lässt sich installieren, Willkommen-Bildschirm erscheint.

## M1 – Verbindung + Kopplung
- [ ] Mac: Einstellungen → *Handy koppeln …* zeigt einen QR-Code mit Restzeit.
- [ ] Handy: QR scannen → am Mac erscheint „Kopplung mit … erlauben?“ → *Erlauben*.
- [ ] Mac zeigt „Verbunden“, Handyname und Akkustand (Seitenleiste + Menüleiste).
- [ ] Kopplung dauert unter 30 Sekunden.
- [ ] WLAN am Handy aus/an → Verbindung kommt von selbst zurück (unter 10 s).
- [ ] Mac neu starten bzw. aus dem Ruhezustand wecken → verbindet sich wieder.
- [ ] Handy neu starten → Dienst startet automatisch, Mac verbindet sich wieder.
- [ ] Abgelaufener QR-Code (über 5 min) wird abgelehnt.

## M2 – Benachrichtigungen
- [ ] Nachricht in WhatsApp/Telegram an dich schicken lassen → erscheint als macOS-Mitteilung mit App-Symbol.
- [ ] Mitteilung am Mac wegwischen → verschwindet auch am Handy.
- [ ] Mitteilung am Handy wegwischen → verschwindet auch am Mac.
- [ ] *Antworten* direkt in der Mac-Mitteilung → Antwort kommt beim Absender an.
- [ ] SMS mit Code („Dein Code lautet 123456“) → Mitteilung bietet „Code 123456 kopieren“.
- [ ] Einstellungen → Mitteilungen pro App: App ausschalten → keine macOS-Mitteilung mehr.

## M3 – SMS
- [ ] Nachrichten-Bereich zeigt Unterhaltungen mit Kontaktnamen.
- [ ] Unterhaltung öffnen, ältere Nachrichten nachladen.
- [ ] SMS vom Mac senden → kommt an, erscheint im Verlauf.
- [ ] Neue SMS erscheint live im Verlauf und als ungelesen in der Liste.

## M4 – Fotos + Dateien
- [ ] Fotos-Bereich zeigt die neuesten Bilder, beim Scrollen werden mehr geladen.
- [ ] Doppelklick öffnet ein Foto in voller Auflösung.
- [ ] Foto in den Finder / auf den Schreibtisch ziehen → Datei wird erstellt.
- [ ] Datei auf das Fenster/Menüleisten-Feld ziehen → landet am Handy in *Download/LinkToMac* (Fortschritt sichtbar).
- [ ] Am Handy *Teilen → Link to Mac* (Foto, PDF) → landet im Mac-Ordner *Downloads*.
- [ ] Große Datei (> 500 MB) – Fortschrittsbalken läuft, Prüfsumme stimmt.

## M5 – Zwischenablage
- [ ] Text am Mac kopieren → am Handy einfügen.
- [ ] Bild am Mac kopieren (z. B. Screenshot mit ⌃⇧⌘4) → am Handy einfügen.
- [ ] Text am Handy kopieren → Schnelleinstellungs-Kachel „Zwischenablage → Mac“ → am Mac einfügen.
- [ ] Text am Handy markieren → *Teilen → Link to Mac* → am Mac einfügen.

## M6 – Anrufe
- [ ] Eingehender Anruf → schwebendes Fenster oben rechts mit Name/Nummer.
- [ ] *Annehmen* und *Ablehnen* funktionieren; im Gespräch *Auflegen*.
- [ ] Anrufliste zeigt verpasste Anrufe rot.
- [ ] Nummer in der Wähltastatur eingeben → *Anrufen* → Handy wählt.

## M7 – Bildschirm-Spiegelung
- [ ] *Handy-Bildschirm → Spiegelung starten* → am Handy „Jetzt starten“ → Bild erscheint.
- [ ] Klicken = Tippen, Ziehen = Wischen, Mausrad scrollt, Rechtsklick = Zurück.
- [ ] Tastatur schreibt in ein Textfeld am Handy.
- [ ] Handy drehen → Bild dreht sich mit.
- [ ] Fenster schließen → Aufnahme am Handy endet.

## M8 – Feinschliff
- [ ] *Handy klingeln lassen* klingelt auch im Lautlos-Modus, *Stopp* beendet es.
- [ ] Musik am Handy → Mini-Player in der Seitenleiste, Pause/Weiter/Zurück funktionieren.
- [ ] Mac-Sprache auf Englisch → Mac-App ist englisch. Handy-Sprache Englisch → Android-App ist englisch.
- [ ] Einstellungen → *Beim Anmelden starten* → nach Neustart läuft die App.
- [ ] *Entkoppeln* am Mac oder Handy → beide Seiten sind entkoppelt, erneutes Koppeln klappt.
- [ ] Hell- und Dunkelmodus sehen in beiden Apps gut aus.
