import SwiftUI

struct RootView: View {
    @State private var userProfile = UserProfileStore.load()

    var body: some View {
        Group {
            if let userProfile {
                ContentView(userProfile: userProfile)
            } else {
                OnboardingView { profile in
                    UserProfileStore.save(profile)
                    userProfile = profile
                }
            }
        }
    }
}

#Preview {
    RootView()
}
