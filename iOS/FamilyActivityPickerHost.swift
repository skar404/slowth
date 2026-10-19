import SwiftUI
#if canImport(FamilyControls)
import FamilyControls
#endif

#if canImport(FamilyControls)
struct FamilyActivityPickerWrapper: View {
    @State var selection: FamilyActivitySelection
    var onDone: ((FamilyActivitySelection) -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        NavigationStack {
            FamilyActivityPicker(selection: $selection)
                .safeAreaInset(edge: .top) {
                    Text(AppLocalization.string("Pick a single app, not a whole category or \"All Apps\" — that would block everything."))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                }
                .navigationTitle(String(localized: "Block apps"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { onCancel?() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { onDone?(selection) }
                    }
                }
        }
    }
}
#endif
