import SwiftUI

@main
struct eqYourMacbookApp: App {
    // The control channel is the app's only scripting surface (EQControlChannel.swift);
    // installed here, not in EQController's defaults, so tests never register one.
    @StateObject private var controller = EQController(controlChannel: EQControlChannel())

    var body: some Scene {
        MenuBarExtra("eqYourMacbook", systemImage: "slider.horizontal.3") {
            EQPanelView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}
