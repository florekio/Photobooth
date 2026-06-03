import SwiftUI

@main
struct PhotoboothApp: App {
    @State private var controller = CameraController()

    var body: some Scene {
        WindowGroup {
            BoothView(controller: controller)
                .frame(minWidth: 960, minHeight: 600)
                .background(.black)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
