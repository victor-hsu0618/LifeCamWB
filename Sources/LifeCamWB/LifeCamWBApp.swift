import SwiftUI
import ServiceManagement

@main
struct LifeCamWBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("LifeCam White Balance") {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .lcSettingsRestored,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSettingsRestored()
        }
    }

    private func handleSettingsRestored() {
        guard UserDefaults.standard.bool(forKey: "lc_minimizeOnConnect") else { return }
        // Small delay so the window is visible briefly before minimizing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.windows.first { $0.isVisible }?.miniaturize(nil)
        }
    }

    deinit {
        if let obs = settingsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

// MARK: - Login Item helpers (macOS 13+)

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("LoginItem error: \(error.localizedDescription)")
        }
    }
}
