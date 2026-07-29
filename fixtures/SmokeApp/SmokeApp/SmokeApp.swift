import SwiftUI

@main
struct SmokeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Tart UI test ready")
                .accessibilityIdentifier("ready")
        }
    }
}
