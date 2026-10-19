import SwiftUI

struct SafariHelpSheet: View {
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "safari.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.21, green: 0.65, blue: 0.97),
                                             Color(red: 0.14, green: 0.45, blue: 0.84)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        VStack(alignment: .leading) {
                            Text(String(localized: "Enable Slowth in Safari"))
                                .font(.title3.weight(.semibold))
                            Text(String(localized: "Apple doesn't allow apps to deep-link directly into the Safari extensions list. Follow the steps below."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        StepRow(number: 1, title: String(localized: "Open Settings"),
                                detail: String(localized: "Tap the button below — it opens iOS Settings."))
                        StepRow(number: 2, title: String(localized: "Go to Apps → Safari → Extensions"),
                                detail: String(localized: "Scroll the apps list, tap Safari, then Extensions."))
                        StepRow(number: 3, title: String(localized: "Turn on Slowth"),
                                detail: String(localized: "Toggle Slowth on. iOS may ask for permissions."))
                        StepRow(number: 4, title: String(localized: "Allow on every website"),
                                detail: String(localized: "Tap Slowth → Permissions → All Websites → Allow. Without this, the extension can't hide Shorts."))
                    }

                    Button {
                        openSettings()
                    } label: {
                        Text(String(localized: "Open Settings"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(20)
            }
            .navigationTitle(String(localized: "Enable in Safari"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
#Preview("Safari help") {
    SafariHelpSheet(openSettings: {})
}
#Preview("Safari help · dark") {
    SafariHelpSheet(openSettings: {}).preferredColorScheme(.dark)
}
#endif
