#if DEBUG
import SwiftUI

struct DebugSavedLeavesControl: View {
    @State private var editing = false
    @State private var value = ""
    @State private var error: String?

    private var count: Int? {
        guard let count = Int(value), (0...1_000_000).contains(count) else { return nil }
        return count
    }

    var body: some View {
        Button {
            do {
                value = String(try IOSPauseCoordinator.presentationSnapshot().savedLeaves)
                editing = true
            } catch {
                self.error = String(localized: "Could not update saved leaves", table: "Interface")
            }
        } label: {
            Label(String(localized: "Edit saved leaves", table: "Interface"), systemImage: "leaf")
        }
        .alert(String(localized: "Saved leaves", table: "Interface"), isPresented: $editing) {
            TextField("0–1000000", text: $value).keyboardType(.numberPad)
            Button(String(localized: "Cancel"), role: .cancel) { }
            Button(String(localized: "Save")) {
                guard let count else { return }
                do { try IOSPauseCoordinator.setSavedLeavesForDebug(count) }
                catch { self.error = String(localized: "Could not update saved leaves", table: "Interface") }
            }
            .disabled(count == nil)
        }
        .alert(String(localized: "Heads up"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}


#Preview("Saved leaves control") {
    Form { DebugSavedLeavesControl() }.allowsHitTesting(false)
}

#endif
