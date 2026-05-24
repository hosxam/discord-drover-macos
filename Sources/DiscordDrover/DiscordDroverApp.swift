import SwiftUI

@main
struct DiscordDroverApp: App {
    @StateObject private var controller = DroverController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(minWidth: 500, minHeight: 490)
        }
        .windowResizability(.contentSize)
    }
}

