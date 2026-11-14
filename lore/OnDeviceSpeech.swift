import Foundation

/// Which spoken languages Lore can transcribe on device. Everything else is
/// routed to the remote transcriber.
enum SpokenLanguageSupport {
    /// Fluid Speech Mini is English-only.
    static let onDeviceLanguageCodes: Set<String> = ["en"]

    /// "en-US", "en_GB", "EN" → "en".
    static func normalizedCode(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let code = Locale(identifier: trimmed).language.languageCode?.identifier {
            return code.lowercased()
        }
        return trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
    }

    /// The languages to route by: the person's answer, or the device's
    /// preferred languages when they haven't answered yet.
    static func effectiveLanguageCodes(
        profileCodes: [String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        let source = profileCodes.isEmpty ? preferredLanguages : profileCodes
        var seen = Set<String>()
        return source.map(normalizedCode).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// On-device transcription is used only when every language the person
    /// speaks is supported, so a bilingual note is never forced through an
    /// English-only model.
    static func allowsOnDeviceTranscription(for languageCodes: [String]) -> Bool {
        !languageCodes.isEmpty && languageCodes.allSatisfy(onDeviceLanguageCodes.contains)
    }
}

/// Lifecycle of the on-device speech model download.
enum OnDeviceSpeechModelState: Equatable, Sendable {
    case notDownloaded
    case waitingForWiFi
    case downloading(progress: Double)
    case verifying
    case ready
    case failed(message: String)

    var isReady: Bool { self == .ready }
}
