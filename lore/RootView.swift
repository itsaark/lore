import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var cloudArchiveStatus: CloudArchiveStatusMonitor
    @Query(sort: \UserProfile.createdAt, order: .forward) private var userProfiles: [UserProfile]
    @State private var didCheckLegacyData = false
    @State private var migrationError: String?
    @State private var didChooseFreshArchive = false
    @State private var showsFreshArchiveConfirmation = false

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
                if userProfile.hasRemoteProcessingConsent {
                    ContentView(userProfile: userProfile)
                } else {
                    RemoteProcessingPermissionView {
                        userProfile.grantRemoteProcessingConsent()
                        try? modelContext.save()
                    }
                }
            } else if didChooseFreshArchive || cloudArchiveStatus.status.lastSuccessfulImport != nil {
                OnboardingView { profile in
                    modelContext.insert(profile)
                    try? modelContext.save()
                }
            } else {
                cloudArchiveRecoveryGate
            }
        }
        .task {
            migrateLegacyDataIfNeeded()
        }
        .onChange(of: cloudArchiveStatus.status.lastSuccessfulImport) { _, importedAt in
            guard importedAt != nil else { return }
            do {
                try CloudArchiveReconciler.reconcile(in: modelContext)
            } catch {
                migrationError = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Start with an empty journal?",
            isPresented: $showsFreshArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue Without Restoring", role: .destructive) {
                didChooseFreshArchive = true
            }
            Button("Keep Checking iCloud", role: .cancel) {}
        } message: {
            Text("Only continue if this is your first Lore setup. If you used Lore before, sign in to the same iCloud account and retry so your journal can be restored.")
        }
    }

    @ViewBuilder
    private var cloudArchiveRecoveryGate: some View {
        VStack(spacing: 18) {
            Image(systemName: recoverySymbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text(recoveryTitle)
                    .font(.headline)
                Text(recoveryDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if cloudArchiveStatus.status.accountState == .checking
                || cloudArchiveStatus.status.activeOperation != nil {
                ProgressView()
            } else {
                Button("Retry") {
                    Task {
                        await cloudArchiveStatus.refreshAccountStatus()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Button("This is my first Lore setup") {
                showsFreshArchiveConfirmation = true
            }
            .font(.footnote)
        }
        .padding(28)
        .frame(maxWidth: 440)
    }

    private var recoverySymbol: String {
        switch cloudArchiveStatus.status.accountState {
        case .noAccount, .restricted:
            "icloud.slash"
        default:
            "icloud.and.arrow.down"
        }
    }

    private var recoveryTitle: String {
        switch cloudArchiveStatus.status.accountState {
        case .noAccount:
            "Sign in to iCloud to restore Lore"
        case .restricted:
            "iCloud access is restricted"
        case .temporarilyUnavailable, .couldNotDetermine:
            "Lore couldn’t check iCloud"
        case .checking, .available:
            "Checking iCloud for your journal…"
        }
    }

    private var recoveryDetail: String {
        switch cloudArchiveStatus.status.accountState {
        case .noAccount:
            "Use the same Apple Account as your previous phone, then return and retry."
        case .restricted:
            "Allow iCloud access before starting a new journal so an existing archive is not overlooked."
        case .temporarilyUnavailable, .couldNotDetermine:
            "Your journal may still be safe in iCloud. Check your connection and retry before starting over."
        case .checking, .available:
            "Lore is waiting for your private archive before deciding whether to begin onboarding."
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
        .environmentObject(CloudArchiveStatusMonitor(startsImmediately: false))
}
