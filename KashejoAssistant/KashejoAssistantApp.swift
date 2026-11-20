import SwiftUI

@main
struct KashejoAssistantApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(model)
        }
    }
}
