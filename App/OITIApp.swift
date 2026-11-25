import SwiftUI

@main
struct OITIApp: App {
    @StateObject private var camera = ThermalCamera()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .onAppear { camera.start() }
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
    }
}
