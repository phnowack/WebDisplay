import SwiftUI

@main
struct PaneApp: App {
    var body: some Scene {
        WindowGroup {
            StageHost()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
        }
    }
}

struct StageHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> StageController { StageController() }
    func updateUIViewController(_ controller: StageController, context: Context) {}
}
