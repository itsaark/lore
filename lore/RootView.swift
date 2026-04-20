import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserProfile.createdAt, order: .forward) private var userProfiles: [UserProfile]
    @State private var didCheckLegacyData = false
    @State private var migrationError: String?

    var body: some View {
        Group {
            if !didCheckLegacyData {
                ProgressView("Loading Lore")
            } else if let migrationError {
                VStack(spacing: 12) {
                    Text("Lore could not load your local archive.")
                        .font(.headline)
                    Text(migrationError)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else if let userProfile = userProfiles.first {
                ContentView(userProfile: userProfile)
            } else {
                OnboardingView { profile in
                    modelContext.insert(profile)
                    try? modelContext.save()
                }
            }
        }
        .task {
            migrateLegacyDataIfNeeded()
        }
    }

    private func migrateLegacyDataIfNeeded() {
        guard !didCheckLegacyData else {
            return
        }

        do {
            try LegacyDataMigrator.migrateIfNeeded(modelContext: modelContext)
        } catch {
            migrationError = error.localizedDescription
        }

        didCheckLegacyData = true
    }
}

#Preview {
    RootView()
        .modelContainer(LoreModelContainer.preview)
}
