import SwiftUI

struct OnboardingView: View {
    let onComplete: (UserProfile) -> Void

    @State private var name = ""
    @State private var hometown = ""
    @State private var birthYear = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Begin your life story")
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        Text("Lore uses these details to place your stories in context.")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }

                    VStack(spacing: 16) {
                        ProfileField(
                            title: "Name",
                            placeholder: "Aark",
                            text: $name,
                            keyboardType: .default,
                            textContentType: .name
                        )

                        ProfileField(
                            title: "Hometown",
                            placeholder: "Hyderabad",
                            text: $hometown,
                            keyboardType: .default,
                            textContentType: .addressCity
                        )

                        ProfileField(
                            title: "Birth year",
                            placeholder: "1994",
                            text: $birthYear,
                            keyboardType: .numberPad,
                            textContentType: nil
                        )
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Button(action: completeOnboarding) {
                        HStack(spacing: 10) {
                            Text("Start telling stories")
                            Image(systemName: "arrow.right.circle.fill")
                                .imageScale(.large)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!canComplete)
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .accessibilityHint("Completes onboarding and opens Lore")
                }
                .padding(.horizontal, 24)
                .padding(.top, 72)
                .padding(.bottom, 32)
            }
            .background(Color(.systemBackground))
            .navigationBarHidden(true)
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedHometown: String {
        hometown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedBirthYear: Int? {
        Int(birthYear.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var isBirthYearValid: Bool {
        guard let parsedBirthYear else {
            return false
        }

        return (1900...currentYear).contains(parsedBirthYear)
    }

    private var canComplete: Bool {
        !trimmedName.isEmpty && !trimmedHometown.isEmpty && isBirthYearValid
    }

    private var validationMessage: String? {
        guard !birthYear.isEmpty, !isBirthYearValid else {
            return nil
        }

        return "Enter a birth year between 1900 and \(currentYear)."
    }

    private func completeOnboarding() {
        guard canComplete, let parsedBirthYear else {
            return
        }

        onComplete(
            UserProfile(
                name: trimmedName,
                hometown: trimmedHometown,
                birthYear: parsedBirthYear
            )
        )
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(isEnabled ? 0.18 : 0), lineWidth: 1)
            )
            .shadow(
                color: isEnabled ? Color.black.opacity(configuration.isPressed ? 0.12 : 0.22) : .clear,
                radius: configuration.isPressed ? 4 : 10,
                x: 0,
                y: configuration.isPressed ? 2 : 6
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else {
            return Color(.systemGray3)
        }

        return isPressed ? Color.black.opacity(0.82) : Color.black
    }
}

private struct ProfileField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboardType: UIKeyboardType
    let textContentType: UITextContentType?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                )
        }
    }
}

#Preview {
    OnboardingView { _ in }
}
