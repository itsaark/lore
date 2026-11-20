#if DEBUG
import SwiftData
import SwiftUI
import UIKit

/// Developer-only blind comparison of journal writers on the founder's own
/// notes. Lives inside the Model Lab so all evaluation stays in one place.
struct LabJournalHomeView: View {
    @StateObject private var model = LabJournalModel()
    @Query private var profiles: [UserProfile]
    @State private var sheet: AddSheet?
    @State private var exportURL: LabJournalExport?

    private enum AddSheet: String, Identifiable {
        case clip, journal, paste
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                intro
                if let reason = model.unavailableReason {
                    LabJournalNotice(text: reason)
                }
                writersSection
                addSection
                scoreboardSection
                notesSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .loreCanvas()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportURL = model.exportAll().map(LabJournalExport.init)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .foregroundStyle(LoreTheme.ink)
                .disabled(model.inputs.isEmpty)
                .accessibilityLabel("Export all journal results")
            }
        }
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                switch sheet {
                case .clip: LabJournalClipPicker(model: model)
                case .journal: LabJournalNotePicker(model: model)
                case .paste: LabJournalPasteView(model: model)
                }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $exportURL) { export in
            LabJournalShareSheet(items: [export.url])
        }
        .onAppear {
            model.load()
            if let profile = profiles.first {
                var subject = profile.journalSubject
                if subject.displayName.isEmpty { subject.displayName = model.subject.displayName }
                model.subject = subject
            }
        }
        .alert(
            "Journal Lab",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var intro: some View {
        Text("Run several writers on the same note. Results show as A, B, C until you've scored them all, then you can reveal which model wrote which. Each run sends the note's text to Lore's server and Fireworks, and nothing is kept there.")
            .font(LoreTheme.caption())
            .foregroundStyle(LoreTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var writersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("Writers")
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(LabJournalCandidate.all.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 { LoreHairline() }
                    Toggle(isOn: Binding(
                        get: { model.selectedCandidateIDs.contains(candidate.id) },
                        set: { isOn in
                            if isOn { model.selectedCandidateIDs.insert(candidate.id) }
                            else { model.selectedCandidateIDs.remove(candidate.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.displayName)
                                .font(.body)
                                .foregroundStyle(LoreTheme.ink)
                            Text("\(candidate.pricePerMillion) per million tokens in / out")
                                .font(.caption)
                                .foregroundStyle(LoreTheme.tertiaryInk)
                        }
                    }
                    .tint(LoreTheme.ink)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                }
            }
            .labJournalCard()
        }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("Add a note to test")
                .padding(.leading, 4)
            VStack(spacing: 0) {
                addRow("From a Transcription Lab clip", systemImage: "waveform", sheet: .clip)
                LoreHairline()
                addRow("From your journal", systemImage: "book.closed", sheet: .journal)
                LoreHairline()
                addRow("Paste text", systemImage: "doc.on.clipboard", sheet: .paste)
            }
            .labJournalCard()
        }
    }

    private func addRow(_ title: String, systemImage: String, sheet: AddSheet) -> some View {
        Button {
            self.sheet = sheet
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                Spacer()
                Image(systemName: "plus")
                    .foregroundStyle(LoreTheme.tertiaryInk)
            }
            .foregroundStyle(LoreTheme.ink)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var scoreboardSection: some View {
        let rows = model.leaderboard()
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                LoreSectionHeader("Scoreboard")
                    .padding(.leading, 4)
                Text("Average of your scores on revealed runs.")
                    .font(.caption)
                    .foregroundStyle(LoreTheme.tertiaryInk)
                    .padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.candidate.id) { index, row in
                        if index > 0 { LoreHairline() }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.candidate.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LoreTheme.ink)
                            Text("Faithfulness \(Self.format(row.faithfulness)) · Writing \(Self.format(row.narrative)) · Preferred \(row.preferred)× · \(row.scored) scored")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(LoreTheme.secondaryInk)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                    }
                }
                .labJournalCard()
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("Notes")
                .padding(.leading, 4)
            if model.inputs.isEmpty {
                Text("Add a note above to start comparing writers.")
                    .font(LoreTheme.caption())
                    .foregroundStyle(LoreTheme.tertiaryInk)
                    .padding(.leading, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.inputs.enumerated()), id: \.element.id) { index, input in
                        if index > 0 { LoreHairline() }
                        NavigationLink {
                            LabJournalInputView(model: model, inputID: input.id)
                        } label: {
                            LabJournalInputRow(input: input, isRunning: model.isRunning(input))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .labJournalCard()
            }
        }
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "–"
    }
}

private struct LabJournalInputRow: View {
    let input: LabJournalInput
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(input.label)
                    .font(.body)
                    .foregroundStyle(LoreTheme.ink)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(LoreTheme.tertiaryInk)
            }
            Spacer()
            if isRunning {
                ProgressView().tint(LoreTheme.ink)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LoreTheme.tertiaryInk)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private var summary: String {
        let words = input.text.split(whereSeparator: \.isWhitespace).count
        guard let run = input.latestRun else { return "\(words) words · not run yet" }
        let scored = run.outputs.filter(\.scores.isComplete).count
        return "\(words) words · \(input.runs.count) run\(input.runs.count == 1 ? "" : "s") · \(scored)/\(run.outputs.count) scored"
    }
}

// MARK: - One note

struct LabJournalInputView: View {
    @ObservedObject var model: LabJournalModel
    let inputID: UUID
    @State private var selectedRunID: UUID?
    @State private var showsSource = false
    @State private var confirmsDelete = false
    @Environment(\.dismiss) private var dismiss

    private var input: LabJournalInput? { model.inputs.first { $0.id == inputID } }

    var body: some View {
        ScrollView {
            if let input {
                VStack(alignment: .leading, spacing: 24) {
                    sourceSection(input)
                    runControls(input)
                    if let run = currentRun(input) {
                        runSection(input, run: run)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
        }
        .loreCanvas()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(input?.label ?? "Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .foregroundStyle(LoreTheme.ink)
                .accessibilityLabel("Delete this note from the Lab")
            }
        }
        .confirmationDialog("Delete this note and its results from the Lab?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let input { model.delete(input) }
                dismiss()
            }
        }
    }

    private func currentRun(_ input: LabJournalInput) -> LabJournalRun? {
        if let selectedRunID, let run = input.runs.first(where: { $0.id == selectedRunID }) { return run }
        return input.latestRun
    }

    private func sourceSection(_ input: LabJournalInput) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsSource.toggle() }
            } label: {
                HStack {
                    LoreSectionHeader("Source · \(input.segments.count) sentences")
                    Spacer()
                    Image(systemName: showsSource ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LoreTheme.tertiaryInk)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            if showsSource {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(input.segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(segment.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(LoreTheme.tertiaryInk)
                                .frame(width: 30, alignment: .leading)
                            Text(segment.text)
                                .font(LoreTheme.body)
                                .foregroundStyle(LoreTheme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .labJournalCard()
            }
        }
    }

    private func runControls(_ input: LabJournalInput) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.run(input.id)
                selectedRunID = nil
            } label: {
                HStack {
                    if model.isRunning(input) { ProgressView().tint(LoreTheme.canvas) }
                    Text(model.isRunning(input) ? "Writing…" : "Run \(model.selectedCandidateIDs.count) writers")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.lorePillAdaptive)
            .disabled(model.isRunning(input) || model.unavailableReason != nil || model.selectedCandidateIDs.isEmpty)

            if input.runs.count > 1 {
                Picker("Run", selection: Binding(
                    get: { currentRun(input)?.id ?? input.runs.last!.id },
                    set: { selectedRunID = $0 }
                )) {
                    ForEach(Array(input.runs.enumerated().reversed()), id: \.element.id) { index, run in
                        Text("Run \(index + 1) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .tag(run.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(LoreTheme.ink)
            }
        }
    }

    private func runSection(_ input: LabJournalInput, run: LabJournalRun) -> some View {
        let succeeded = run.outputs.filter { $0.status == .succeeded }
        let allScored = !succeeded.isEmpty && succeeded.allSatisfy(\.scores.isComplete)
        let ordered = run.outputs.sorted { $0.blindLabel < $1.blindLabel }
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(ordered) { output in
                LabJournalOutputCard(
                    model: model,
                    input: input,
                    runID: run.id,
                    output: output,
                    revealed: run.revealed
                )
            }
            if !run.revealed {
                Button {
                    model.reveal(inputID: input.id, runID: run.id)
                } label: {
                    Text(allScored ? "Reveal the writers" : "Score every result to reveal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.lorePillAdaptive)
                .disabled(!allScored)
            }
        }
    }
}

private struct LabJournalOutputCard: View {
    @ObservedObject var model: LabJournalModel
    let input: LabJournalInput
    let runID: UUID
    let output: LabJournalOutput
    let revealed: Bool
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch output.status {
            case .running:
                HStack(spacing: 10) {
                    ProgressView().tint(LoreTheme.ink)
                    Text("Writing…").foregroundStyle(LoreTheme.secondaryInk)
                }
            case .failed:
                Text(output.error ?? "Failed")
                    .font(.footnote)
                    .foregroundStyle(LoreTheme.attention)
            case .succeeded:
                entry
                checks
                LoreHairline()
                scoring
            }
        }
        .padding(18)
        .labJournalCard()
        .onAppear { note = output.scores.note }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(output.blindLabel)
                .font(LoreTheme.display(28))
                .foregroundStyle(LoreTheme.ink)
            if revealed, let candidate = output.candidate {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LoreTheme.ink)
                    if let modelID = output.modelID {
                        Text(modelID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(LoreTheme.tertiaryInk)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if output.scores.preferred {
                Image(systemName: "star.fill")
                    .foregroundStyle(LoreTheme.ink)
                    .accessibilityLabel("Preferred")
            }
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = output.title {
                Text(title)
                    .font(LoreTheme.title(.title3))
                    .foregroundStyle(LoreTheme.ink)
            }
            Text("Tap any sentence that's invented or not supported by what you said.")
                .font(.caption)
                .foregroundStyle(LoreTheme.tertiaryInk)
            ForEach(Array(output.sentences.enumerated()), id: \.offset) { index, sentence in
                let invented = output.scores.inventedSentences.contains(index)
                Button {
                    model.updateScores(inputID: input.id, runID: runID, outputID: output.id) { scores in
                        if invented { scores.inventedSentences.remove(index) }
                        else { scores.inventedSentences.insert(index) }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sentence.text)
                            .font(LoreTheme.body)
                            .foregroundStyle(invented ? LoreTheme.attention : LoreTheme.ink)
                            .strikethrough(invented, color: LoreTheme.attention)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(sentence.sourceReferences.joined(separator: ","))
                            .font(.caption2.monospaced())
                            .foregroundStyle(LoreTheme.tertiaryInk)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(invented ? "Marked invented. Tap to unmark." : "Tap to mark as invented.")
            }
        }
    }

    private var checks: some View {
        let names = output.unsupportedNames(source: input.text, subject: model.subject.displayName)
        var parts = ["\(output.wordCount) words"]
        if let latency = output.latencyMilliseconds { parts.append(String(format: "%.1f s", Double(latency) / 1_000)) }
        if let prompt = output.promptTokens, let completion = output.completionTokens {
            parts.append("\(prompt) in / \(completion) out tokens")
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(parts.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(LoreTheme.tertiaryInk)
            if !names.isEmpty {
                Text("Names not in the source: \(names.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(LoreTheme.attention)
            }
        }
    }

    private var scoring: some View {
        VStack(alignment: .leading, spacing: 14) {
            ratingRow("Faithfulness", value: output.scores.faithfulness) { value in
                model.updateScores(inputID: input.id, runID: runID, outputID: output.id) { $0.faithfulness = value }
            }
            ratingRow("Writing", value: output.scores.narrative) { value in
                model.updateScores(inputID: input.id, runID: runID, outputID: output.id) { $0.narrative = value }
            }
            Button {
                model.setPreferred(inputID: input.id, runID: runID, outputID: output.id)
            } label: {
                Label(output.scores.preferred ? "Your favourite" : "Mark as favourite",
                      systemImage: output.scores.preferred ? "star.fill" : "star")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LoreTheme.ink)
            }
            .buttonStyle(.plain)
            TextField("Note (optional)", text: $note, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(LoreTheme.ink)
                .lineLimit(1...4)
                .onSubmit(saveNote)
                .onChange(of: note) { _, _ in saveNote() }
        }
    }

    private func saveNote() {
        guard note != output.scores.note else { return }
        model.updateScores(inputID: input.id, runID: runID, outputID: output.id) { $0.note = note }
    }

    private func ratingRow(_ title: String, value: Int?, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(LoreTheme.secondaryInk)
                .frame(width: 96, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { score in
                    Button {
                        set(score)
                    } label: {
                        Text("\(score)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .frame(width: 36, height: 32)
                            .foregroundStyle(value == score ? LoreTheme.canvas : LoreTheme.ink)
                            .background(
                                Capsule().fill(value == score ? LoreTheme.ink : LoreTheme.raisedSurface)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(score) of 5")
                    .accessibilityAddTraits(value == score ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - Adding notes

private struct LabJournalClipPicker: View {
    @ObservedObject var model: LabJournalModel
    @Environment(\.dismiss) private var dismiss
    @State private var clips: [TranscriptionLabClipRecord] = []

    var body: some View {
        List {
            if clips.isEmpty {
                Text("No Transcription Lab clips have a corrected reference yet. Save a reference on a clip first.")
                    .foregroundStyle(LoreTheme.secondaryInk)
            }
            ForEach(clips) { clip in
                Button {
                    model.addInput(
                        label: clip.label,
                        text: clip.reference?.text ?? "",
                        source: .transcriptionLabClip,
                        reference: clip.id,
                        capturedDate: clip.createdAt
                    )
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(clip.label).foregroundStyle(LoreTheme.ink)
                        Text(clip.reference?.text ?? "")
                            .font(.caption)
                            .foregroundStyle(LoreTheme.tertiaryInk)
                            .lineLimit(2)
                    }
                }
                .loreListRow()
            }
        }
        .loreGroupedList()
        .navigationTitle("Lab clips")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear {
            clips = TranscriptionLabClipStore().loadAll().filter { $0.reference?.text.isEmpty == false }
        }
    }
}

private struct LabJournalNotePicker: View {
    @ObservedObject var model: LabJournalModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Story.date, order: .reverse) private var stories: [Story]

    var body: some View {
        List {
            let usable = stories.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if usable.isEmpty {
                Text("No journal notes with a transcript yet.")
                    .foregroundStyle(LoreTheme.secondaryInk)
            }
            ForEach(usable) { story in
                Button {
                    model.addInput(
                        label: story.title ?? story.date.formatted(date: .abbreviated, time: .omitted),
                        text: story.text,
                        source: .journalNote,
                        reference: story.id.uuidString,
                        capturedDate: story.date
                    )
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(story.title ?? "Untitled note").foregroundStyle(LoreTheme.ink)
                        Text(story.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(LoreTheme.tertiaryInk)
                        Text(story.text)
                            .font(.caption)
                            .foregroundStyle(LoreTheme.secondaryInk)
                            .lineLimit(2)
                    }
                }
                .loreListRow()
            }
        }
        .loreGroupedList()
        .navigationTitle("Your journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

private struct LabJournalPasteView: View {
    @ObservedObject var model: LabJournalModel
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var text = ""

    var body: some View {
        Form {
            Section("Label") {
                TextField("e.g. Childhood kitchen", text: $label)
            }
            .loreListRow()
            Section("What was said") {
                TextEditor(text: $text)
                    .frame(minHeight: 220)
            }
            .loreListRow()
        }
        .loreGroupedList()
        .navigationTitle("Paste text")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    model.addInput(label: label, text: text, source: .pasted, reference: nil, capturedDate: Date())
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

// MARK: - Small pieces

private struct LabJournalNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(LoreTheme.attention)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .labJournalCard()
    }
}

private struct LabJournalExport: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct LabJournalShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private extension View {
    func labJournalCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
                .fill(LoreTheme.surface)
        )
    }
}
#endif
