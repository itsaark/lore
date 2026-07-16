import SwiftUI

struct LocalAISetupView: View {
    @ObservedObject var modelManager: ModelManager

    var body: some View {
        Form {
            Section {
                ForEach(LocalModelTier.allCases) { tier in
                    LocalModelOptionRow(
                        tier: tier,
                        isSelected: modelManager.status.tier == tier,
                        isDisabled: modelManager.status.state == .downloading || modelManager.status.state == .loading,
                        onSelect: selectTier
                    )
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Choose the balance of writing quality, speed, and storage that fits this iPhone.")
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        statusIcon

                        Text(modelManager.status.statusText)
                    }
                    .foregroundStyle(.secondary)
                }

                if modelManager.status.state == .downloading {
                    ProgressView(value: modelManager.status.progress)
                        .accessibilityLabel("Model download progress")
                }

                actionButton
            } header: {
                Text("On-device model")
            } footer: {
                statusFooter
            }
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch modelManager.status.state {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .accessibilityHidden(true)
        case .downloading, .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .downloaded:
            Image(systemName: "externaldrive.fill")
                .accessibilityHidden(true)
        case .loaded:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let message = modelManager.status.message {
            Text(message)
        } else {
            Text("Lore runs this model locally to keep biography writing private.")
        }

        if modelManager.status.state == .downloading || modelManager.status.state == .loading {
            Text("Keep Lore open while this finishes.")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch modelManager.status.state {
        case .notDownloaded, .failed:
            Button(action: downloadSelectedModel) {
                Label("Download Model", systemImage: "arrow.down.circle")
            }
        case .downloaded:
            Button(action: loadSelectedModel) {
                Label("Load Model", systemImage: "bolt.circle")
            }
            removeModelButton
        case .loaded:
            removeModelButton
        case .downloading, .loading:
            EmptyView()
        }
    }

    private var removeModelButton: some View {
        Button(role: .destructive) {
            modelManager.forgetDownloadedModel()
        } label: {
            Label("Remove Download", systemImage: "trash")
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
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tier.displayName)
                        .foregroundStyle(.primary)
                    Text(tier.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(tier.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

#Preview {
    NavigationStack {
        LocalAISetupView(modelManager: ModelManager())
    }
}
