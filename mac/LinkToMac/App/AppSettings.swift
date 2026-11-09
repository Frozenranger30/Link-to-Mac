import Foundation
import ServiceManagement

/// User preferences on the Mac side (stored in UserDefaults – nothing secret).
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var showNotifications: Bool { didSet { d.set(showNotifications, forKey: "showNotifications") } }
    @Published var clipboardSync: Bool { didSet { d.set(clipboardSync, forKey: "clipboardSync") } }
    @Published var autoAcceptFiles: Bool { didSet { d.set(autoAcceptFiles, forKey: "autoAcceptFiles") } }
    @Published var callPopup: Bool { didSet { d.set(callPopup, forKey: "callPopup") } }
    @Published var mutedApps: Set<String> { didSet { d.set(Array(mutedApps), forKey: "mutedApps") } }
    @Published var knownApps: [String: String] { didSet { d.set(knownApps, forKey: "knownApps") } }
    @Published var phoneFeatures: [String: Bool] { didSet { d.set(phoneFeatures, forKey: "phoneFeatures") } }

    static let featureKeys = ["notifications", "sms", "calls", "photos", "files", "clipboard", "mirror", "media"]

    init() {
        d.register(defaults: ["showNotifications": true, "clipboardSync": true, "autoAcceptFiles": true, "callPopup": true])
        showNotifications = d.bool(forKey: "showNotifications")
        clipboardSync = d.bool(forKey: "clipboardSync")
        autoAcceptFiles = d.bool(forKey: "autoAcceptFiles")
        callPopup = d.bool(forKey: "callPopup")
        mutedApps = Set(d.stringArray(forKey: "mutedApps") ?? [])
        knownApps = d.dictionary(forKey: "knownApps") as? [String: String] ?? [:]
        phoneFeatures = d.dictionary(forKey: "phoneFeatures") as? [String: Bool]
            ?? Dictionary(uniqueKeysWithValues: Self.featureKeys.map { ($0, true) })
    }

    func feature(_ key: String) -> Bool { phoneFeatures[key] ?? true }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
        }
    }
}
