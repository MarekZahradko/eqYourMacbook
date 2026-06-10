import SwiftUI

@main
struct eqYourMacbookApp: App {
    @StateObject private var controller = EQController()

    var body: some Scene {
        MenuBarExtra("eqYourMacbook", systemImage: "slider.horizontal.3") {
            EQPanelView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}
