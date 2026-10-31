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
    private let reflectionBackend: any LoreReflectionBackendClient
    private let opensSettings: Bool

    init(userProfile: UserProfile) {
        self.userProfile = userProfile
        let remoteServices = LoreRemoteServices.configuredForCurrentBuild()
        _speechRecognizer = StateObject(
            wrappedValue: SpeechRecognitionViewModel(
                remoteDailyEntryGenerator: remoteServices.dailyEntryGenerator,
                remoteTranscriber: remoteServices.speechTranscriber
            )
        )
        reflectionBackend = remoteServices.reflectionBackend
        opensSettings = ProcessInfo.processInfo.arguments.contains("-LoreOpenSettings")
    }

    var body: some View {
        JournalHomeView(
            userProfile: userProfile,
            speechRecognizer: speechRecognizer,
            reflectionBackend: reflectionBackend,
            opensSettings: opensSettings
        )
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
