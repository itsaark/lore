enum WritingOrbVisibility {
    static func onRecordButton(
        isRecording: Bool,
        isTranscribing: Bool,
        todayKey: String,
        writingKey: String?
    ) -> Bool {
        !isRecording && (isTranscribing || writingKey == todayKey)
    }

    static func inDialPicture(
        hasPicture: Bool,
        selectionContainsWritingStory: Bool
    ) -> Bool {
        !hasPicture && selectionContainsWritingStory
    }
}
