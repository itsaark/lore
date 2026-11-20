import SwiftUI

struct MemoryWhenMenu: View {
    let story: Story
    let speechRecognizer: SpeechRecognitionViewModel

    @State private var yearSelection: YearSelection?

    private struct YearSelection: Identifiable {
        let years: ClosedRange<Int>
        let selectedYear: Int
        var id: Int { selectedYear }
    }

    var body: some View {
        let options = speechRecognizer.memoryTimeOptions(for: story)
        Menu {
            Button("Today") { speechRecognizer.correctRememberedTime(of: story, to: .today) }
            ForEach(options.periods, id: \.startYear) { period in
                Button(period.title) { speechRecognizer.correctRememberedTime(of: story, to: .period(period)) }
            }
            Button("Year…") {
                let current = story.rememberedTime.flatMap { MemoryAnchorResolver.year(of: $0.startDate) }
                let selected = current.flatMap { options.years.contains($0) ? $0 : nil } ?? options.years.upperBound
                yearSelection = YearSelection(years: options.years, selectedYear: selected)
            }
        } label: {
            Label("When", systemImage: "chevron.down")
                .font(LoreTheme.label)
                .foregroundStyle(LoreTheme.secondaryInk)
        }
        .accessibilityIdentifier("memoryWhenMenu")
        .sheet(item: $yearSelection) { selection in
            MemoryYearPicker(years: selection.years, selectedYear: selection.selectedYear) { year in
                speechRecognizer.correctRememberedTime(of: story, to: .year(year))
            }
        }
    }
}

private struct MemoryYearPicker: View {
    let years: ClosedRange<Int>
    let save: (Int) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedYear: Int

    init(years: ClosedRange<Int>, selectedYear: Int, save: @escaping (Int) -> Bool) {
        self.years = years
        self.save = save
        _selectedYear = State(initialValue: selectedYear)
    }

    var body: some View {
        NavigationStack {
            Picker("Year", selection: $selectedYear) {
                ForEach(years.reversed(), id: \.self) { year in
                    Text(year, format: .number.grouping(.never)).tag(year)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .loreCanvas()
            .navigationTitle("Year")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { if save(selectedYear) { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
