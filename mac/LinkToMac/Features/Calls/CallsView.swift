import SwiftUI

struct CallsView: View {
    @EnvironmentObject var calls: CallsStore
    @EnvironmentObject var connection: ConnectionManager
    @State private var number = ""
    @State private var search = ""

    private var matches: [Contact] {
        guard !number.isEmpty else { return [] }
        let digits = number.filter(\.isNumber)
        return calls.contacts.filter { c in
            c.name.localizedCaseInsensitiveContains(number)
                || (!digits.isEmpty && c.numbers.contains { $0.filter(\.isNumber).contains(digits) })
        }.prefix(6).map { $0 }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List {
                    ForEach(calls.log) { entry in
                        CallRow(entry: entry) { calls.dial(entry.number) }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if calls.log.isEmpty {
                        EmptyState(symbol: "phone", text: connection.isConnected
                            ? String(localized: "Keine Anrufe – ist die Berechtigung „Telefon und Anrufliste“ erteilt?")
                            : String(localized: "Verbinde dein Handy, um Anrufe zu sehen"))
                    }
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity)

            VStack(spacing: 14) {
                TextField("Nummer oder Name", text: $number)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .onSubmit { calls.dial(number) }
                if !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(matches, id: \.self) { c in
                            ForEach(c.numbers, id: \.self) { n in
                                Button { number = n } label: {
                                    HStack { Text(c.name); Spacer(); Text(n).foregroundStyle(.secondary) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .font(.callout)
                }
                DialPad { key in number.append(key) }
                HStack(spacing: 20) {
                    Button { if !number.isEmpty { number.removeLast() } } label: {
                        Image(systemName: "delete.left").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.delete, modifiers: [])
                    Button { calls.dial(number) } label: {
                        Image(systemName: "phone.fill").font(.title).foregroundStyle(.white)
                            .frame(width: 64, height: 64).background(Circle().fill(Color.green))
                    }
                    .buttonStyle(.plain)
                    .disabled(number.isEmpty || !connection.isConnected)
                }
                Text("Das Gespräch selbst läuft über das Handy (Lautsprecher oder Headset).")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(20)
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        }
        .toolbar {
            Button { Task { await calls.refresh() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                .disabled(!connection.isConnected)
        }
    }
}

private struct DialPad: View {
    let press: (String) -> Void
    private let keys = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 12) {
            ForEach(keys, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { k in
                        Button { press(k) } label: {
                            Text(k).font(.title2.weight(.medium)).frame(width: 56, height: 56)
                                .background(Circle().fill(Color.secondary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct CallRow: View {
    let entry: CallEntry
    let call: () -> Void

    private var icon: (String, Color) {
        switch entry.type {
        case "outgoing": return ("phone.arrow.up.right", .secondary)
        case "missed": return ("phone.arrow.down.left", .red)
        case "rejected": return ("phone.down", .orange)
        default: return ("phone.arrow.down.left", .secondary)
        }
    }

    var body: some View {
        HStack {
            Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 20)
            VStack(alignment: .leading) {
                Text(entry.contactName ?? entry.number).foregroundStyle(entry.type == "missed" ? Color.red : Color.primary)
                if entry.contactName != nil { Text(entry.number).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(Date(milliseconds: entry.date).shortRelative).font(.caption)
                if entry.duration > 0 {
                    Text(Duration.seconds(entry.duration).formatted(.time(pattern: .minuteSecond))).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button(action: call) { Image(systemName: "phone.fill") }
                .buttonStyle(.borderless)
                .help(String(localized: "Zurückrufen"))
        }
        .padding(.vertical, 2)
    }
}
