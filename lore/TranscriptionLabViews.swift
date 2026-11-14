#if DEBUG
import SwiftUI
import UIKit

/// Developer-only head-to-head of on-device speech-to-text engines.
struct TranscriptionLabView: View {
    @StateObject private var lab = TranscriptionLabModel()
    @State private var export: TranscriptionLabExport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TranscriptionLabRecordSection(lab: lab, recorder: lab.recorder)
                modelsSection
                enginesSection
                clipsSection
                appAttestSection
                attribution
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .loreCanvas()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Transcription Lab")
        .navigationBarTitleDisplayMode(.inline)
        .labInlineTitle("Transcription Lab")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    export = lab.exportArchive().map(TranscriptionLabExport.init)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .foregroundStyle(LoreTheme.ink)
                .disabled(lab.clips.isEmpty || lab.isBusy)
                .accessibilityLabel("Export all clips")
            }
        }
        .sheet(item: $export) { export in
            TranscriptionLabShareSheet(items: [export.url])
        }
        .task { await lab.onAppear() }
        .onDisappear { lab.onDisappear() }
        .alert(
            "Transcription Lab",
            isPresented: Binding(get: { lab.errorMessage != nil }, set: { if !$0 { lab.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lab.errorMessage ?? "")
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("Models")
                .padding(.leading, 4)
            TranscriptionLabCardList(lab.assets, id: \.id) { asset in
                TranscriptionLabAssetRow(
                    asset: asset,
                    state: lab.assetStates[asset.id] ?? .init(),
                    isBusy: lab.isBusy,
                    download: { lab.download(asset) },
                    cancel: { lab.cancelDownload(asset) }
                )
            }
            TranscriptionLabFootnote("Download before benchmarking so download and first compile never count as load or inference time.")
        }
    }

    private var appAttestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("Remote access")
                .padding(.leading, 4)
            TranscriptionLabCardList(["reset"], id: \.self) { _ in
                Button {
                    Task { await lab.resetAppAttestBackoff() }
                } label: {
                    Text("Reset App Attest backoff")
                        .font(.body)
                        .foregroundStyle(LoreTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(lab.isBusy)
            }
            TranscriptionLabFootnote(
                lab.appAttestResetStatus
                    ?? "After the server refuses this phone's App Attest key, Lore waits 24 hours before enrolling again. Reset after a backend fix. Keeps the key and every clip."
            )
        }
    }

    private var enginesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("Include in Run all")
                .padding(.leading, 4)
            TranscriptionLabCardList(lab.engines, id: \.id) { engine in
                Toggle(isOn: Binding(
                    get: { lab.enabledEngineIDs.contains(engine.id) },
                    set: { isOn in
                        if isOn { lab.enabledEngineIDs.insert(engine.id) } else { lab.enabledEngineIDs.remove(engine.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(engine.displayName)
                            .font(.body)
                            .foregroundStyle(LoreTheme.ink)
                        if let reason = lab.unavailableReasons[engine.id] {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(LoreTheme.tertiaryInk)
                        } else if engine.uploadsAudio {
                            Text("Off each time you open the Lab. Sends the clip's audio to Lore's backend and Groq.")
                                .font(.caption)
                                .foregroundStyle(LoreTheme.tertiaryInk)
                        } else if engine.supportsVocabulary {
                            Text("Runs with and without the clip's names as vocabulary")
                                .font(.caption)
                                .foregroundStyle(LoreTheme.tertiaryInk)
                        }
                    }
                }
                .tint(LoreTheme.secondaryInk)
                .disabled(lab.isBusy)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            TranscriptionLabFootnote("Groq Whisper uploads the clip through Lore's production backend.")
        }
    }

    private var clipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("Clips")
                .padding(.leading, 4)
            if lab.clips.isEmpty {
                Text("Record a clip to start comparing engines.")
                    .font(LoreTheme.caption(.body))
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .padding(.leading, 4)
            } else {
                TranscriptionLabCardList(lab.clips, id: \.id) { clip in
                    NavigationLink {
                        TranscriptionLabClipView(lab: lab, clipID: clip.id)
                    } label: {
                        TranscriptionLabClipRow(clip: clip, isRunning: lab.runningClipID == clip.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var attribution: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Powered by Desert Ant Labs")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LoreTheme.secondaryInk)
            Text("Fluid Speech Mini by FluidVoice (CC BY 4.0). Parakeet models by NVIDIA and Moondream (CC BY 4.0), run with FluidAudio (Apache 2.0).")
                .font(.caption)
                .foregroundStyle(LoreTheme.tertiaryInk)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recording

private struct TranscriptionLabRecordSection: View {
    @ObservedObject var lab: TranscriptionLabModel
    @ObservedObject var recorder: TranscriptionLabRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("New clip")
                .padding(.leading, 4)

            TextField("Label, e.g. noisy café", text: $lab.draftLabel)
                .autocorrectionDisabled()
                .foregroundStyle(LoreTheme.ink)
                .loreField()
                .disabled(recorder.isRecording)

            TextField("Names said in this clip, comma-separated", text: $lab.draftNames, axis: .vertical)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .foregroundStyle(LoreTheme.ink)
                .lineLimit(1...3)
                .padding(.vertical, 14)
                .loreField()
                .disabled(recorder.isRecording)

            LoreCard {
                HStack(spacing: 16) {
                    Button {
                        Task { await lab.toggleRecording() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(LoreTheme.ink)
                                .frame(width: 64, height: 64)
                            if recorder.isRecording {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.black)
                                    .frame(width: 22, height: 22)
                            } else {
                                Circle()
                                    .fill(Color.black)
                                    .frame(width: 24, height: 24)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(lab.runningClipID != nil)
                    .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")

                    VStack(alignment: .leading, spacing: 10) {
                        Text(TranscriptionLabFormat.clock(recorder.elapsed))
                            .font(.system(.title2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(recorder.isRecording ? LoreTheme.ink : LoreTheme.tertiaryInk)
                        TranscriptionLabLevelMeter(level: recorder.level)
                        Text(recorder.isRecording ? "Recording 16 kHz mono" : "Tap to record")
                            .font(.caption)
                            .foregroundStyle(LoreTheme.secondaryInk)
                    }
                }
            }
        }
    }
}

private struct TranscriptionLabLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(LoreTheme.raisedSurface)
                Capsule()
                    .fill(LoreTheme.ink)
                    .frame(width: proxy.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Models

private struct TranscriptionLabAssetRow: View {
    let asset: any TranscriptionLabModelAsset
    let state: TranscriptionLabModel.AssetState
    let isBusy: Bool
    let download: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.title)
                        .font(.body)
                        .foregroundStyle(LoreTheme.ink)
                    Text(asset.detail)
                        .font(.caption)
                        .foregroundStyle(LoreTheme.tertiaryInk)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                trailing
            }
            if let progress = state.downloadProgress {
                ProgressView(value: progress)
                    .tint(LoreTheme.ink)
            }
            if let error = state.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(LoreTheme.attention)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var trailing: some View {
        if let progress = state.downloadProgress {
            Button("Cancel", action: cancel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LoreTheme.secondaryInk)
                .overlay(alignment: .bottom) {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(LoreTheme.tertiaryInk)
                        .offset(y: 16)
                }
        } else if state.isInstalled {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Downloaded")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LoreTheme.secondaryInk)
                Text(state.installedBytes.map { TranscriptionLabProbes.formatBytes($0) } ?? "System")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LoreTheme.tertiaryInk)
            }
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                Button("Download", action: download)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(LoreTheme.ink))
                    .disabled(isBusy)
                Text(asset.expectedBytes.map { "~" + TranscriptionLabProbes.formatBytes($0) } ?? "Size varies")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LoreTheme.tertiaryInk)
            }
        }
    }
}

// MARK: - Clip list

private struct TranscriptionLabClipRow: View {
    let clip: TranscriptionLabClipRecord
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.label.isEmpty ? "Untitled clip" : clip.label)
                    .font(.body)
                    .foregroundStyle(LoreTheme.ink)
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LoreTheme.tertiaryInk)
            }
            Spacer(minLength: 8)
            if isRunning {
                ProgressView().tint(LoreTheme.ink)
            } else if clip.reference != nil {
                Text("REF")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay { Capsule().strokeBorder(LoreTheme.hairline) }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LoreTheme.tertiaryInk)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [
            clip.createdAt.formatted(date: .abbreviated, time: .shortened),
            TranscriptionLabFormat.clock(clip.audioDurationSeconds),
        ]
        if let run = clip.latestRun {
            parts.append("\(run.results.filter { $0.status == .succeeded }.count)/\(run.results.count) ok")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Clip detail

private struct TranscriptionLabClipView: View {
    @ObservedObject var lab: TranscriptionLabModel
    let clipID: String
    @State private var editing: TranscriptionLabReferenceDraft?
    @State private var namesField = ""
    @State private var labelField = ""
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            if let clip = lab.clip(clipID) {
                VStack(alignment: .leading, spacing: 24) {
                    details(clip)
                    runControls(clip)
                    referenceSection(clip)
                    resultsSection(clip)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
                .onAppear {
                    namesField = clip.names.joined(separator: ", ")
                    labelField = clip.label
                }
            }
        }
        .loreCanvas()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Clip")
        .navigationBarTitleDisplayMode(.inline)
        .labInlineTitle(lab.clip(clipID)?.label.isEmpty == false ? lab.clip(clipID)!.label : "Clip")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .foregroundStyle(LoreTheme.ink)
                .disabled(lab.runningClipID == clipID)
                .accessibilityLabel("Delete clip")
            }
        }
        .confirmationDialog("Delete this clip and its results?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                lab.delete(clipID)
                dismiss()
            }
        }
        .sheet(item: $editing) { draft in
            TranscriptionLabReferenceEditor(draft: draft) { text in
                lab.saveReference(text, derivedFrom: draft.sourceEngineID, for: clipID)
            }
        }
    }

    private func details(_ clip: TranscriptionLabClipRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("\(TranscriptionLabFormat.clock(clip.audioDurationSeconds)) · \(clip.device.modelIdentifier) · \(clip.device.systemName) \(clip.device.systemVersion)")
                .padding(.leading, 4)
            TextField("Label", text: $labelField)
                .autocorrectionDisabled()
                .foregroundStyle(LoreTheme.ink)
                .loreField()
                .onSubmit { lab.updateLabel(labelField, for: clipID) }
            TextField("Names said in this clip, comma-separated", text: $namesField, axis: .vertical)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .foregroundStyle(LoreTheme.ink)
                .lineLimit(1...3)
                .padding(.vertical, 14)
                .loreField()
                .onSubmit { lab.updateNames(namesField, for: clipID) }
                .onChange(of: namesField) { _, newValue in
                    if newValue.hasSuffix("\n") {
                        namesField = String(newValue.dropLast())
                        lab.updateNames(namesField, for: clipID)
                    }
                }
            if TranscriptionLabMetrics.parseNames(namesField) != clip.names || labelField != clip.label {
                Button("Save details") {
                    lab.updateLabel(labelField, for: clipID)
                    lab.updateNames(namesField, for: clipID)
                }
                .buttonStyle(.lorePillSecondary)
            }
            TranscriptionLabFootnote(clip.id + "/")
        }
    }

    private func runControls(_ clip: TranscriptionLabClipRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if lab.runningClipID == clipID {
                HStack(spacing: 12) {
                    ProgressView().tint(LoreTheme.ink)
                    Text(lab.runStatus ?? "Running…")
                        .font(.subheadline)
                        .foregroundStyle(LoreTheme.secondaryInk)
                    Spacer()
                    Button("Stop", action: lab.cancelRun)
                        .buttonStyle(.lorePillSecondary)
                }
            } else {
                Button {
                    lab.runAll(clipID)
                } label: {
                    Text(clip.runs.isEmpty ? "Run all" : "Run all again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.lorePillAdaptive)
                .disabled(lab.isBusy)
                TranscriptionLabFootnote("Engines run one at a time. Each model is released before the next loads. Keep the app open until it finishes.")
            }
        }
    }

    private func referenceSection(_ clip: TranscriptionLabClipRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("Reference")
                .padding(.leading, 4)
            LoreCard {
                VStack(alignment: .leading, spacing: 10) {
                    if let reference = clip.reference {
                        Text(reference.text)
                            .font(LoreTheme.body)
                            .foregroundStyle(LoreTheme.ink)
                            .textSelection(.enabled)
                    } else {
                        Text("No reference yet. Tap any transcript below, correct it, and save it as the ground truth.")
                            .font(LoreTheme.caption(.body))
                            .foregroundStyle(LoreTheme.secondaryInk)
                    }
                    Button(clip.reference == nil ? "Write reference" : "Edit reference") {
                        editing = TranscriptionLabReferenceDraft(text: clip.reference?.text ?? "", sourceEngineID: clip.reference?.derivedFromEngineID)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LoreTheme.ink)
                }
            }
        }
    }

    @ViewBuilder
    private func resultsSection(_ clip: TranscriptionLabClipRecord) -> some View {
        if let run = clip.latestRun {
            VStack(alignment: .leading, spacing: 12) {
                LoreSectionHeader("Results · \(run.startedAt.formatted(date: .omitted, time: .shortened))")
                    .padding(.leading, 4)
                ForEach(run.results) { result in
                    TranscriptionLabResultCard(result: result, hasReference: clip.reference != nil, hasNames: !clip.names.isEmpty) {
                        editing = TranscriptionLabReferenceDraft(text: result.transcript ?? "", sourceEngineID: result.id)
                    }
                }
            }
        }
    }
}

private struct TranscriptionLabResultCard: View {
    let result: TranscriptionLabEngineResult
    let hasReference: Bool
    let hasNames: Bool
    let editTranscript: () -> Void

    var body: some View {
        LoreCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.displayName)
                        .font(LoreTheme.title(.headline))
                        .foregroundStyle(LoreTheme.ink)
                    Spacer(minLength: 8)
                    Text(result.status.rawValue.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(result.status == .succeeded ? LoreTheme.secondaryInk : LoreTheme.attention)
                }

                if let transcript = result.transcript, !transcript.isEmpty {
                    Button(action: editTranscript) {
                        Text(transcript)
                            .font(LoreTheme.body)
                            .foregroundStyle(LoreTheme.ink)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit and save as the clip's reference")
                }

                if let error = result.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(LoreTheme.attention)
                }

                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                    if hasReference {
                        metric("WER", result.wordErrorRate.map { TranscriptionLabFormat.percent($0.rate) + " (\($0.errors)/\($0.referenceWordCount))" })
                    }
                    if hasNames {
                        metric("Names", result.nameRecall.map { "\($0.found.count)/\($0.total)" })
                    }
                    metric("Transcribe", result.transcriptionSeconds.map(TranscriptionLabFormat.seconds))
                    metric("RTF", result.realTimeFactor.map { String(format: "%.3f", $0) })
                    metric("Cold load", result.coldLoadSeconds.map(TranscriptionLabFormat.seconds))
                    metric("Warm load", result.warmLoadSeconds.map(TranscriptionLabFormat.seconds))
                    metric("Peak memory", result.peakFootprintBytes.map { TranscriptionLabProbes.formatBytes($0) })
                    metric("After release", result.footprintAfterReleaseBytes.map { TranscriptionLabProbes.formatBytes($0) })
                    metric("Thermal", "\(result.thermalStateBefore) → \(result.thermalStateAfter ?? "-")")
                }

                if let missed = result.nameRecall?.missed, !missed.isEmpty {
                    Text("Missed: " + missed.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(LoreTheme.secondaryInk)
                }
                if !result.notes.isEmpty {
                    Text(result.notes.joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(LoreTheme.tertiaryInk)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(LoreTheme.tertiaryInk)
            Text(value ?? "-")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(LoreTheme.ink)
        }
    }
}

// MARK: - Reference editor

private struct TranscriptionLabReferenceDraft: Identifiable {
    let id = UUID()
    let text: String
    let sourceEngineID: String?
}

private struct TranscriptionLabReferenceEditor: View {
    let draft: TranscriptionLabReferenceDraft
    let save: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(draft: TranscriptionLabReferenceDraft, save: @escaping (String) -> Void) {
        self.draft = draft
        self.save = save
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TranscriptionLabFootnote("Correct every word to what was actually said. WER and name recall for all engines are scored against this text.")
                TextEditor(text: $text)
                    .font(LoreTheme.body)
                    .foregroundStyle(LoreTheme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(LoreTheme.surface, in: RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius, style: .continuous)
                            .strokeBorder(LoreTheme.hairline, lineWidth: 0.5)
                    }
            }
            .padding(20)
            .loreCanvas()
            .labInlineTitle("Reference")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(LoreTheme.secondaryInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save as reference") {
                        save(text)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(LoreTheme.ink)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Shared pieces

private struct TranscriptionLabCardList<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    let row: (Item) -> Row

    init(_ items: [Item], id: KeyPath<Item, ID>, @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.id = id
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                row(item)
                if index < items.count - 1 {
                    LoreHairline().padding(.leading, 18)
                }
            }
        }
        .background(LoreTheme.surface, in: RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(LoreTheme.hairline, lineWidth: 0.5)
        }
    }
}

private struct TranscriptionLabFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(LoreTheme.tertiaryInk)
            .padding(.horizontal, 4)
    }
}

private struct TranscriptionLabShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum TranscriptionLabFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let remainder = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, remainder)
    }

    static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.2f s", value) : String(format: "%.1f s", value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

private struct TranscriptionLabExport: Identifiable {
    let url: URL
    var id: URL { url }
}

private extension View {
    func labInlineTitle(_ title: String) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(LoreTheme.title(.headline))
                    .foregroundStyle(LoreTheme.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .loreNavigationBar()
    }
}
#endif
