import SwiftUI
import UIKit
#if canImport(FamilyControls)
import FamilyControls
#endif

#if canImport(FamilyControls)
final class FamilyActivityPickerHost: UIHostingController<FamilyActivityPickerWrapper> {
    private let onResult: (FamilyActivitySelection?) -> Void

    init(initialSelection: FamilyActivitySelection,
         onResult: @escaping (FamilyActivitySelection?) -> Void) {
        self.onResult = onResult
        super.init(rootView: FamilyActivityPickerWrapper(selection: initialSelection))

        rootView.onDone = { [weak self] selection in
            self?.dismiss(animated: true) {
                self?.onResult(selection)
            }
        }
        rootView.onCancel = { [weak self] in
            self?.dismiss(animated: true) {
                self?.onResult(nil)
            }
        }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct FamilyActivityPickerWrapper: View {
    @State var selection: FamilyActivitySelection
    var onDone: ((FamilyActivitySelection) -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        NavigationStack {
            FamilyActivityPicker(selection: $selection)
                .navigationTitle("Block apps")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel?() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDone?(selection) }
                    }
                }
        }
    }
}
#endif
