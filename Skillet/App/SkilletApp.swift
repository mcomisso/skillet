import SwiftUI

@main
struct SkilletApp: App {
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
                .environment(\.dependencies, dependencies)
                .frame(minWidth: 960, minHeight: 600)
        }

        Settings {
            SettingsView()
        }
    }
}
