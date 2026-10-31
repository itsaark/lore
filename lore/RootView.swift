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
                VStack(spacing: 18) {
                    Text("Lore")
                        .font(LoreTheme.display(44))
                        .foregroundStyle(LoreTheme.ink)
                    ProgressView()
                        .tint(LoreTheme.secondaryInk)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading Lore")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .loreCanvas()
            } else if let migrationError {
                VStack(spacing: 14) {
                    Text("Lore could not load your local archive.")
                        .font(LoreTheme.title())
                        .foregroundStyle(LoreTheme.ink)
                        .multilineTextAlignment(.center)
                    Text(migrationError)
                        .font(LoreTheme.caption(.footnote))
                        .foregroundStyle(LoreTheme.attention)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .loreCanvas()
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
        VStack(spacing: 24) {
            Image(systemName: recoverySymbol)
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(LoreTheme.secondaryInk)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(recoveryTitle)
                    .font(LoreTheme.title(.title))
                    .foregroundStyle(LoreTheme.ink)
                    .multilineTextAlignment(.center)
                Text(recoveryDetail)
                    .font(LoreTheme.caption(.callout))
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .multilineTextAlignment(.center)
            }

            if cloudArchiveStatus.status.accountState == .checking
                || cloudArchiveStatus.status.activeOperation != nil {
                ProgressView()
                    .tint(LoreTheme.secondaryInk)
                    .frame(height: 46)
            } else {
                Button("Retry") {
                    Task {
                        await cloudArchiveStatus.refreshAccountStatus()
                    }
                }
                .buttonStyle(.lorePill)
            }

            Button("This is my first Lore setup") {
                showsFreshArchiveConfirmation = true
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(LoreTheme.secondaryInk)
        }
        .padding(28)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loreCanvas()
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
