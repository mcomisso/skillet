import SwiftUI
import Sparkle

@main
struct SkilletApp: App {
    private let dependencies = AppDependencies()
    /// Sparkle auto-updater; checks the appcast on GitHub for new releases.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
                .environment(\.dependencies, dependencies)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
