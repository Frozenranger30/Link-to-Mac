# Link to Mac – Protokoll (Version 1)

Dieses Dokument ist die verbindliche Beschreibung des Protokolls zwischen der
Mac-App und der Android-App. Beispiel-Nachrichten für jeden Typ liegen in
`shared/protocol-examples/` und werden von den Unit-Tests beider Apps gelesen.

## Abweichungen von SPEC.md (und warum)

| SPEC.md | Umsetzung | Grund |
|---|---|---|
| Mac erzeugt TLS-Zertifikat, Handy verbindet sich zum Mac | **Das Handy ist TLS-Server**, der Mac verbindet sich als Client zum Handy | macOS bietet keine öffentliche API, um ohne Entwickler-Konto ein selbstsigniertes TLS-Server-Zertifikat samt privatem Schlüssel als `SecIdentity` zu erzeugen. Android dagegen erzeugt im Android-Keystore automatisch ein selbstsigniertes Zertifikat. Das passt auch zu Abschnitt 1 der SPEC („Android = Server“). |
| Gegenseitiges TLS (mutual TLS) | TLS mit Zertifikat-Pinning auf dem Mac **plus** Signatur-Challenge vom Mac | Gleiche Sicherheit: Das Handy prüft den Mac über eine ECDSA-Signatur mit dem beim Koppeln gespeicherten öffentlichen Schlüssel. |
| Ed25519 | **ECDSA P-256 / SHA-256** | Ed25519 ist auf Android erst ab neueren Versionen verfügbar; P-256 läuft auf Android 10+ und in CryptoKit. |
| QR-Code-Port 47800 | QR enthält den **Kopplungsport des Mac (47805)** | Port 47800 gehört dem Handy (Steuerkanal). |
| „Sender öffnet Dateiverbindung“ | **Der Mac öffnet immer** die Daten-/Videoverbindung zum Handy; die Richtung steht im Header | Nur das Handy ist Server. |

## 1. Rollen und Ports

| Port | Wer lauscht | Zweck |
|---|---|---|
| 47800 | Handy (TLS) | Steuerkanal (JSON-Nachrichten) |
| 47801 | Handy (TLS) | Dateikanal (Fotos, Dateien) |
| 47802 | Handy (TLS) | Videokanal (Spiegelung) |
| 47805 | Mac (TCP, ohne TLS) | Nur Kopplung (`pair.request`), siehe 3 |

Das Handy meldet sich per Bonjour/mDNS als `_linktomac._tcp` (Port 47800) an.
TXT-Eintrag `fp` = die ersten 16 Hex-Zeichen seines Zertifikat-Fingerabdrucks.

**Fingerabdruck** = SHA-256 über die DER-Bytes (Zertifikat bzw. SubjectPublicKeyInfo), als
64 Zeichen kleingeschriebenes Hex.

## 2. Rahmenformat (Steuerkanal und Header)

Jede Nachricht: 4 Byte Länge (Big Endian, ohne die 4 Byte selbst) + UTF-8-JSON.
Maximale Länge: 16 MiB.

```json
{ "id": "uuid", "type": "notification.posted", "ts": 1731137870000, "replyTo": "uuid?", "body": { } }
```

`body` ist immer ein Objekt (bei Nachrichten ohne Inhalt `{}`). Unbekannte Typen und
unbekannte Felder werden ignoriert (Vorwärtskompatibilität).

## 3. Kopplung

1. Der Mac erzeugt einmalig ein ECDSA-P-256-Schlüsselpaar (Schlüsselbund).
2. Der Mac zeigt einen QR-Code (gültig 5 Minuten, Token nur einmal verwendbar):
   ```json
   { "v":1, "name":"Jonns MacBook", "host":"192.168.1.20", "hosts":["192.168.1.20"],
     "port":47805, "keyFingerprint":"<sha256 hex des Mac-Public-Keys>",
     "pairToken":"<32 Zufallsbytes, base64>" }
   ```
3. Das Handy verbindet sich per TCP mit `host:port` (bei Fehler die weiteren `hosts`) und sendet `pair.request`:
   `deviceName`, `model`, `port` (47800), `certFingerprint` (eigenes TLS-Zertifikat),
   `proof` = base64( HMAC-SHA256( key = pairToken-Bytes, msg = UTF8(certFingerprint + "|" + keyFingerprint) ) ).
   Die IP des Handys nimmt der Mac aus der TCP-Verbindung.
4. Der Mac prüft Token-Alter, Einmaligkeit und `proof`, fragt den Nutzer
   („Kopplung mit Galaxy S24 erlauben?“) und antwortet auf derselben Verbindung mit
   `pair.accept` (`macName`, `publicKey` = base64 DER SubjectPublicKeyInfo) oder `pair.reject` (`reason`).
5. Das Handy prüft `sha256(publicKey) == keyFingerprint` aus dem QR-Code und speichert den Schlüssel.
   Der Mac speichert Name, Fingerabdruck und letzte IP des Handys.
6. Danach baut der Mac die TLS-Verbindung zum Handy auf (Abschnitt 4).

Ein Angreifer im WLAN kann weder `proof` fälschen (er kennt den Token nicht) noch den
Mac-Schlüssel austauschen (Fingerabdruck steht im QR-Code).

## 4. Verbindungsaufbau und Anmeldung (Steuerkanal)

1. Mac → Handy: TLS 1.2/1.3 auf Port 47800. Der Mac akzeptiert **nur** das Zertifikat mit dem gespeicherten Fingerabdruck.
2. Handy → Mac: `hello` mit `challenge` (32 Zufallsbytes, base64).
3. Mac → Handy: `auth` mit `keyFingerprint` und
   `signature` = base64( ECDSA-P256-SHA256-DER( UTF8("linktomac-auth|" + challenge + "|" + certFingerprint) ) ),
   danach eigenes `hello`.
4. Handy → Mac: `auth.ok` mit `sessionToken` (32 Zufallsbytes, base64) oder `error` (`unauthorized`) und Verbindungsabbau.
5. Vor `auth.ok` verarbeitet das Handy nur `auth`, `hello`, `ping`.

**Heartbeat:** Der Mac sendet alle 10 s `ping`, das Handy antwortet `pong` (`replyTo`).
Kommt 30 s lang nichts an, bauen beide Seiten die Verbindung ab; der Mac verbindet sich
neu (zuerst letzte IP, parallel Bonjour), alle 3 s.

## 5. Dateikanal (Port 47801)

1. Ein Angebot läuft über den Steuerkanal: `file.offer` (Sender) → `file.accept` / `file.reject` (Empfänger).
2. Der Mac öffnet eine TLS-Verbindung (gleiches Pinning) und sendet einen Header-Rahmen
   (Länge + JSON): `{ "sessionToken": "...", "transferId": "...", "direction": "upload" | "download" }`.
   - `upload` = Mac → Handy: Danach schickt der Mac die Rohdaten (`size` Bytes).
   - `download` = Handy → Mac: Danach schickt das Handy die Rohdaten.
3. Der Empfänger prüft SHA-256 und sendet `file.done` (`transferId`, `ok`, `error?`) über den Steuerkanal.
   Während der Übertragung sendet der Empfänger gelegentlich `file.progress` (`transferId`, `bytes`, `size`).

Fotos: `photo.get` (`id`, `transferId`) → Handy antwortet mit `file.offer` (gleiche `transferId`, `purpose: "photo"`),
der Mac nimmt automatisch an.

## 6. Videokanal (Port 47802)

1. `mirror.start` (`maxSize`, `bitrate`, `fps`) über den Steuerkanal. Das Handy holt die Erlaubnis ein (Systemdialog).
2. Sobald der Encoder läuft: `mirror.config` (`width`, `height`, `sps`, `pps` base64 Annex-B).
3. Der Mac verbindet sich mit Port 47802 und sendet den Header `{ "sessionToken": "..." }`.
4. Pro Frame: 8 Byte Zeitstempel (µs, Big Endian) + 4 Byte Länge + H.264 Annex-B-NAL-Units.
   SPS/PPS kommen zusätzlich im Datenstrom (Codec-Config-Frame), z. B. nach einer Drehung.
5. `mirror.stop` beendet die Aufnahme; `mirror.stopped` (Handy → Mac) meldet ein Ende von Handy-Seite.

## 7. Nachrichtentypen

| Typ | Richtung | body |
|-----|----------|------|
| `hello` | beide | `deviceName`, `model?`, `appVersion`, `protocolVersion` (1), `capabilities[]`, `challenge?` (nur Handy) |
| `auth` | Mac→Handy | `keyFingerprint`, `signature` |
| `auth.ok` | Handy→Mac | `sessionToken` |
| `pair.request` | Handy→Mac | `deviceName`, `model`, `port`, `certFingerprint`, `proof` |
| `pair.accept` / `pair.reject` | Mac→Handy | `macName`, `publicKey` / `reason` |
| `unpair` | beide | – (Gegenseite löscht die Kopplung) |
| `ping` / `pong` | beide | – |
| `status.update` | Handy→Mac | `battery` (0–100), `charging`, `wifiSignal` (0–4), `network` (`wifi`/`mobile`/`none`), `cellSignal` (0–4, −1 = unbekannt), `dnd`, `carrier?` |
| `settings.update` | Mac→Handy | `features` (Objekt Funktion → bool): `notifications`, `sms`, `calls`, `photos`, `files`, `clipboard`, `mirror`, `media` |
| `notification.posted` | Handy→Mac | `key`, `app`, `appName`, `appIconPng?` (base64, nur beim ersten Mal pro App und Verbindung), `title`, `text`, `time`, `actions[]` (`title`, `isReply`), `canReply` |
| `notification.removed` | beide | `key` |
| `notification.action` | Mac→Handy | `key`, `actionIndex`, `replyText?` |
| `notification.clearAll` | Mac→Handy | – |
| `sms.threads.get` | Mac→Handy | `limit?` |
| `sms.threads` | Handy→Mac | `threads[]`: `threadId`, `address`, `contactName?`, `snippet`, `date`, `unread` |
| `sms.messages.get` | Mac→Handy | `threadId`, `before?` (ms), `limit?` |
| `sms.messages` | Handy→Mac | `threadId`, `messages[]`: `id`, `threadId`, `address`, `body`, `date`, `outgoing`, `read` |
| `sms.received` | Handy→Mac | `message` (wie oben), `contactName?` |
| `sms.send` | Mac→Handy | `address`, `text` |
| `sms.sent` | Handy→Mac | `ok`, `error?` (`replyTo` = id von `sms.send`) |
| `sms.markRead` | Mac→Handy | `threadId` |
| `call.state` | Handy→Mac | `state` (`ringing`, `offhook`, `idle`), `number?`, `contactName?` |
| `call.action` | Mac→Handy | `action` (`answer`, `reject`, `hangup`, `dial`), `number?` |
| `calllog.get` | Mac→Handy | `limit?` |
| `calllog` | Handy→Mac | `calls[]`: `id`, `number`, `contactName?`, `type` (`incoming`, `outgoing`, `missed`, `rejected`), `date`, `duration` |
| `contacts.get` / `contacts` | Mac→Handy / zurück | `contacts[]`: `name`, `numbers[]` |
| `photos.list` | Mac→Handy | `offset`, `limit` (max. 100) |
| `photos` | Handy→Mac | `offset`, `total`, `photos[]`: `id`, `date`, `width`, `height`, `name`, `mime`, `thumbJpeg` (base64, 256 px) |
| `photo.get` | Mac→Handy | `id`, `transferId` |
| `file.offer` | beide | `transferId`, `name`, `size`, `mime`, `sha256`, `purpose?` (`file`/`photo`) |
| `file.accept` / `file.reject` | beide | `transferId`, `reason?` |
| `file.progress` | beide | `transferId`, `bytes`, `size` |
| `file.done` | beide | `transferId`, `ok`, `error?` |
| `clipboard.set` | beide | `mime` (`text/plain` oder `image/png`), `text?`, `dataBase64?` |
| `mirror.start` | Mac→Handy | `maxSize`, `bitrate`, `fps` |
| `mirror.stop` | Mac→Handy | – |
| `mirror.config` | Handy→Mac | `width`, `height`, `sps`, `pps` |
| `mirror.stopped` | Handy→Mac | `reason?` |
| `input.touch` | Mac→Handy | `action` (`tap`, `longpress`, `swipe`), `x`, `y`, `x2?`, `y2?`, `durationMs?` (Koordinaten 0–1) |
| `input.key` | Mac→Handy | `key` (`back`, `home`, `recents`, `notifications`, `text`, `enter`, `backspace`), `text?` |
| `input.scroll` | Mac→Handy | `x`, `y`, `dx`, `dy` (normiert, positiv = nach unten/rechts) |
| `find.ring` / `find.stop` | Mac→Handy | – |
| `media.state` | Handy→Mac | `active`, `playing`, `title?`, `artist?`, `app?`, `appName?`, `artPng?` |
| `media.action` | Mac→Handy | `action` (`play`, `pause`, `toggle`, `next`, `previous`) |
| `error` | beide | `code`, `message` |

Fehlercodes: `unauthorized`, `permission_denied`, `not_found`, `feature_disabled`, `bad_request`, `internal`.
