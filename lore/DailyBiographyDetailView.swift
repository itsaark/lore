import SwiftUI

struct DailyBiographyDetailView: View {
    let entry: DailyBiographyEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        entry.formattedCalendarDate,
                        systemImage: "calendar"
                    )
                    Label(
                        "\(entry.noteCount) voice \(entry.noteCount == 1 ? "note" : "notes")",
                        systemImage: "quote.bubble"
                    )
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.title)
                        .font(.title2.weight(.semibold))
                    Text(entry.prose)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Full Transcript")
                        .font(.headline)
                    Text(entry.combinedTranscript)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Daily Biography")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("dailyBiographyDetail")
    }
}
