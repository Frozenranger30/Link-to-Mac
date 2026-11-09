import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var pairing: PairingService
    @State private var confirmUnpair = false
    @State private var showPairing = false

    private let featureNames: [(String, LocalizedStringKey)] = [
        ("notifications", "Benachrichtigungen"),
        ("sms", "SMS"),
        ("calls", "Anrufe"),
        ("photos", "Fotos"),
        ("files", "Dateien empfangen (Handy)"),
        ("clipboard", "Zwischenablage"),
        ("mirror", "Bildschirm-Spiegelung"),
        ("media", "Medien-Steuerung"),
    ]

    var body: some View {
        Form {
            Section("Gerät") {
                if let device = TrustStore.shared.pairedDevice {
                    LabeledContent("Gekoppelt mit") { Text(device.name) }
                    LabeledContent("Modell") { Text(device.model) }
                    LabeledContent("Status") { ConnectionBadge() }
                    if let host = device.lastHost {
                        LabeledContent("Letzte Adresse") { Text(host).textSelection(.enabled) }
                    }
                    LabeledContent("Zertifikat") {
                        Text(String(device.certFingerprint.prefix(23)) + "…").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Button("Neu verbinden") { connection.pairedDeviceChanged() }
                        Button("Neu koppeln …") { showPairing = true }
                        Spacer()
                        Button("Entkoppeln", role: .destructive) { confirmUnpair = true }
                    }
                } else {
                    Text("Noch kein Handy gekoppelt.")
                    Button("Handy koppeln …") { showPairing = true }.buttonStyle(.borderedProminent)
                }
            }

            Section {
                ForEach(featureNames, id: \.0) { item in
                    Toggle(item.1, isOn: Binding(
                        get: { settings.feature(item.0) },
                        set: { settings.phoneFeatures[item.0] = $0; model.pushFeatures() }
                    ))
                }
            } header: {
                Text("Funktionen")
            } footer: {
                Text("Ausgeschaltete Funktionen werden auch auf dem Handy deaktiviert.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Mac") {
                Toggle("Beim Anmelden starten", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                Toggle("Handy-Mitteilungen als macOS-Mitteilungen zeigen", isOn: $settings.showNotifications)
                Toggle("Fenster bei eingehenden Anrufen", isOn: $settings.callPopup)
                Toggle("Zwischenablage automatisch abgleichen", isOn: $settings.clipboardSync)
                Toggle("Dateien vom Handy automatisch annehmen", isOn: $settings.autoAcceptFiles)
            }

            Section {
                if settings.knownApps.isEmpty {
                    Text("Apps erscheinen hier, sobald sie eine Mitteilung gesendet haben.").foregroundStyle(.secondary)
                }
                ForEach(settings.knownApps.sorted(by: { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }), id: \.key) { entry in
                    let app = entry.key
                    Toggle(isOn: Binding(
                        get: { !settings.mutedApps.contains(app) },
                        set: { on in if on { settings.mutedApps.remove(app) } else { settings.mutedApps.insert(app) } }
                    )) {
                        HStack {
                            if let icon = model.notifications.icon(for: app) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            }
                            Text(entry.value)
                        }
                    }
                }
            } header: {
                Text("Mitteilungen pro App")
            }

            Section("Datenschutz") {
                Text("Alle Daten bleiben in deinem lokalen Netzwerk. Fotos, Nachrichten und Symbole werden nur im App-Cache gespeichert.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cache löschen") { model.clearCaches() }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairing) { PairingView() }
        .confirmationDialog(String(localized: "Handy entkoppeln?"), isPresented: $confirmUnpair) {
            Button("Entkoppeln", role: .destructive) { model.unpair() }
        } message: {
            Text("Die Verbindung wird gelöscht. Zum erneuten Verbinden musst du den QR-Code neu scannen.")
        }
    }
}

struct PairingView: View {
    @EnvironmentObject var pairing: PairingService
    @EnvironmentObject var connection: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Handy koppeln").font(.title.bold())
            Text("1. Installiere „Link to Mac“ auf deinem Android-Handy.\n2. Tippe dort auf „Mit Mac koppeln“.\n3. Scanne diesen QR-Code.")
                .frame(maxWidth: .infinity, alignment: .leading)
            if let qr = pairing.qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView().frame(width: 260, height: 260)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(pairing.expiresAt.timeIntervalSince(ctx.date)))
                let time = String(format: "%d:%02d", left / 60, left % 60)
                let hosts = pairing.hosts.joined(separator: ", ")
                Text("Gültig für \(time) min · \(hosts)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let err = pairing.errorMessage {
                Text(err).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }
            Text("Handy und Mac müssen im selben WLAN sein.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Neuer Code") { pairing.regenerate() }
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { pairing.start() }
        .onDisappear { pairing.stop() }
        .onChange(of: connection.state) { state in
            if state == .connected { dismiss() }
        }
        .alert(item: $pairing.pending) { p in
            Alert(
                title: Text("Kopplung mit \(p.request.deviceName) erlauben?"),
                message: Text("Modell: \(p.request.model)\nAdresse: \(p.host)\n\nNur erlauben, wenn du gerade selbst den QR-Code gescannt hast."),
                primaryButton: .default(Text("Erlauben")) { pairing.reply(p, accept: true) },
                secondaryButton: .cancel(Text("Ablehnen")) { pairing.reply(p, accept: false) }
            )
        }
    }
}
