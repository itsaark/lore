//
//  ContentView.swift
//  lore
//
//  Created by Aark Koduru on 7/18/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    let userProfile: UserProfile
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speechRecognizer: SpeechRecognitionViewModel
    @State private var selectedTab: LaunchTab

    init(userProfile: UserProfile) {
        self.userProfile = userProfile
        let remoteServices = LoreRemoteServices.configuredForCurrentBuild()
        _speechRecognizer = StateObject(
            wrappedValue: SpeechRecognitionViewModel(
                remoteDailyEntryGenerator: remoteServices.dailyEntryGenerator,
                remoteTranscriber: remoteServices.speechTranscriber
            )
        )
        let opensSettings = ProcessInfo.processInfo.arguments.contains("-LoreOpenSettings")
        _selectedTab = State(initialValue: opensSettings ? .settings : .notes)
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            NotesHomeView(speechRecognizer: speechRecognizer)
            .tabItem {
                Label("Notes", systemImage: "waveform")
            }
            .tag(LaunchTab.notes)
            .accessibilityIdentifier("notesTab")

            BiographyHomeView(speechRecognizer: speechRecognizer)
                .tabItem {
                    Label("Biography", systemImage: "book.closed")
                }
                .tag(LaunchTab.biography)
                .accessibilityIdentifier("biographyTab")

            SettingsHomeView(userProfile: userProfile)
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(LaunchTab.settings)
            .accessibilityIdentifier("settingsTab")
        }
        .onAppear {
            speechRecognizer.configure(
                modelContext: modelContext,
                userProfile: userProfile
            )
        }
        .onChange(of: userProfile.updatedAt) { _, _ in
            speechRecognizer.refreshRemoteProcessingPolicy()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            speechRecognizer.resumeBackgroundProcessing()
        }
    }
}

private enum LaunchTab: Hashable {
    case notes
    case biography
    case settings
}

#Preview {
    ContentView(
        userProfile: UserProfile(
            name: "Aark",
            hometown: "Hyderabad",
            birthYear: 1994
        )
    )
    .modelContainer(LoreModelContainer.preview)
    .environmentObject(CloudArchiveStatusMonitor(startsImmediately: false))
}
