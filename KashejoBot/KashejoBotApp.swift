import SwiftUI

@main
struct KashejoBotApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            ComposeView()
                .tabItem { Label("投稿", systemImage: "paperplane.fill") }
            AutoPostView()
                .tabItem { Label("自動連投", systemImage: "clock.badge.checkmark") }
            HistoryView()
                .tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
        }
        .tint(.pink)
    }
}
