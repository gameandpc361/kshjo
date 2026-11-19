import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                        Text("履歴はまだありません").foregroundStyle(.secondary)
                    }
                } else {
                    List(history.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(entry.success ? Color.green : Color.red)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: entry.hasImage ? "photo" : "text.quote")
                                        .font(.caption2)
                                    Text(entry.account).font(.caption).bold()
                                }
                                Text(entry.text).lineLimit(3)
                                HStack {
                                    Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(entry.message).font(.caption2)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("履歴")
            .toolbar {
                if !history.entries.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("全消去", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("履歴を全消去しますか?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("全消去", role: .destructive) { history.clear() }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }
}
