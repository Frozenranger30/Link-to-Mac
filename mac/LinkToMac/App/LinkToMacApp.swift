import SwiftUI

@main
struct LinkToMacApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Link to Mac", id: "main") {
            ContentView()
                .injectEnvironment(model)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("Dateien an Handy senden …") {
                    model.selection = .files
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }

        Window("Handy-Bildschirm", id: "mirror") {
            MirrorWindowView()
                .injectEnvironment(model)
                .frame(minWidth: 280, minHeight: 480)
        }
        .defaultSize(width: 400, height: 820)

        MenuBarExtra {
            MenuBarContent()
                .injectEnvironment(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model.connection)
                .environmentObject(model.phone)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .injectEnvironment(model)
                .frame(width: 520, height: 620)
        }
    }
}

extension View {
    func injectEnvironment(_ model: AppModel) -> some View {
        environmentObject(model)
            .environmentObject(model.settings)
            .environmentObject(model.connection)
            .environmentObject(model.pairing)
            .environmentObject(model.phone)
            .environmentObject(model.notifications)
            .environmentObject(model.messages)
            .environmentObject(model.files)
            .environmentObject(model.photos)
            .environmentObject(model.calls)
            .environmentObject(model.clipboard)
            .environmentObject(model.mirror)
    }
}
