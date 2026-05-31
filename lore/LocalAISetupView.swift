import SwiftUI

struct LocalAISetupView: View {
    @ObservedObject var modelManager: ModelManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local AI")
                        .font(.largeTitle)
                        .fontWeight(.semibold)

                    Text("Prepare Lore's private biography engine on this device.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Model")
                        .font(.headline)

                    ForEach(LocalModelTier.allCases) { tier in
                        LocalModelOptionRow(
                            tier: tier,
                            isSelected: modelManager.status.tier == tier,
                            isDisabled: modelManager.status.state == .downloading || modelManager.status.state == .loading,
                            onSelect: selectTier
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(modelManager.status.statusText)
                                .font(.headline)
                            Text(modelManager.status.tier.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        statusIcon
                    }

                    if modelManager.status.state == .downloading {
                        ProgressView(value: modelManager.status.progress)
                    }

                    if let message = modelManager.status.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    actionButton
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                )
            }
            .padding(24)
        }
        .navigationTitle("Local AI")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch modelManager.status.state {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.secondary)
        case .downloading, .loading:
            ProgressView()
        case .downloaded:
            Image(systemName: "externaldrive.fill")
                .foregroundColor(.blue)
        case .loaded:
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch modelManager.status.state {
        case .notDownloaded, .failed:
            Button(action: downloadSelectedModel) {
                Text("Download Model")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LocalAIPrimaryButtonStyle())
        case .downloaded:
            Button(action: loadSelectedModel) {
                Text("Load Downloaded Model")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LocalAIPrimaryButtonStyle())
        case .downloading, .loading:
            Text("Keep Lore open while this finishes.")
                .font(.footnote)
                .foregroundColor(.secondary)
        case .loaded:
            EmptyView()
        }
    }

    private func selectTier(_ tier: LocalModelTier) {
        modelManager.select(tier)
    }

    private func downloadSelectedModel() {
        Task {
            await modelManager.downloadSelectedModel()
        }
    }

    private func loadSelectedModel() {
        Task {
            await modelManager.loadSelectedModel()
        }
    }
}

private struct LocalModelOptionRow: View {
    let tier: LocalModelTier
    let isSelected: Bool
    let isDisabled: Bool
    let onSelect: (LocalModelTier) -> Void

    var body: some View {
        Button {
            onSelect(tier)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .green : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(tier.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(tier.detail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct LocalAIPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding(.vertical, 14)
            .background(configuration.isPressed ? Color.black.opacity(0.8) : Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    NavigationView {
        LocalAISetupView(modelManager: ModelManager())
    }
}
