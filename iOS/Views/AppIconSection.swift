import SwiftUI
import UIKit

private enum AppIconChoice: String, CaseIterable {
    case original = "AppIcon"
    case phone = "SlothPhone"
    case feed = "SlothFeed"
    case video = "SlothVideo"

    var alternateName: String? { self == .original ? nil : rawValue }

    var title: String {
        switch self {
        case .original: return String(localized: "Original", table: "Interface")
        case .phone: return String(localized: "Phone", table: "Interface")
        case .feed: return String(localized: "Feed", table: "Interface")
        case .video: return String(localized: "Video", table: "Interface")
        }
    }
}

struct AppIconSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedName = UIApplication.shared.alternateIconName
    @State private var changing = false
    @State private var errorMessage: String?

    var body: some View {
        if UIApplication.shared.supportsAlternateIcons {
            Section {
                HStack {
                    ForEach(AppIconChoice.allCases, id: \.self) { choice in
                        let selected = choice.alternateName == selectedName
                        Button {
                            changeIcon(to: choice)
                        } label: {
                            Image(choice.rawValue + "Preview")
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 13))
                                .overlay(alignment: .bottomTrailing) {
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18, weight: .bold))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, SlowthAppearance.sage)
                                            .background(.white, in: Circle())
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("appIcon." + choice.rawValue)
                    }
                }
                .disabled(changing)
            } header: {
                Text(String(localized: "App icon", table: "Interface"))
            }
            .onAppear { selectedName = UIApplication.shared.alternateIconName }
            .onChange(of: scenePhase) { phase in
                if phase == .active { selectedName = UIApplication.shared.alternateIconName }
            }
            .alert(String(localized: "App icon", table: "Interface"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(String(localized: "OK")) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func changeIcon(to choice: AppIconChoice) {
        let app = UIApplication.shared
        guard !changing, choice.alternateName != app.alternateIconName else { return }
        changing = true
        Task { @MainActor in
            do {
                try await app.setAlternateIconName(choice.alternateName)
            } catch {
                errorMessage = error.localizedDescription
            }
            selectedName = app.alternateIconName
            changing = false
        }
    }
}
