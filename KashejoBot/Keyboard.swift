import SwiftUI
import UIKit

extension UIApplication {
    static func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

struct KeyboardDismissModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.hideKeyboard()
                    } label: {
                        Label("閉じる", systemImage: "keyboard.chevron.compact.down")
                    }
                }
            }
    }
}

extension View {
    func dismissibleKeyboard() -> some View {
        modifier(KeyboardDismissModifier())
    }
}
