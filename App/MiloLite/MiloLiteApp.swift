import SwiftUI

@main
struct MiloLiteApp: App {
    var body: some Scene {
        WindowGroup("Milo Lite") {
            MiloLiteContentView()
        }
        .defaultSize(width: 620, height: 520)
    }
}
