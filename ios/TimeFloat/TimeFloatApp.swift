import SwiftUI

@main
struct TimeFloatApp: App {
    @StateObject private var hub = ClockHub.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hub)
                .preferredColorScheme(.dark)
        }
    }
}
